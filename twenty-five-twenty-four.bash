#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

cleanup() {
    if [[ -v TMP_DIR && -d "$TMP_DIR" ]]; then
        rm -rf "$TMP_DIR"
    fi
}

check_command() {
    if ! which "$1" >/dev/null 2>&1; then
        echo "Error: Required command '$1' not found"
        exit 1
    fi
}

check_command "dvdbackup"
check_command "lsdvd"
check_command "ffprobe"
check_command "ffmpeg"
check_command "isoquery"
check_command "mencoder"
check_command "jq"

if [ $# -lt 2 ]; then
    echo "Usage: $0 /path/to/dvd output/path"
    exit 1
fi

DVD_PATH="$1"
OUTPUT_PATH="$2"

TMP_DIR=$(mktemp -d)

# Set trap to call cleanup function on exit
trap cleanup EXIT

readarray -t TITLE_NUMS < <(dvdbackup -i "$DVD_PATH" -I 2>/dev/null | grep -oP "^\s+Title \K\d+(?=:$)")

for TITLE_NUM in "${TITLE_NUMS[@]}"; do
  echo "Processing Title ${TITLE_NUM}/${#TITLE_NUMS[@]}"
  
  dvdbackup -i "$DVD_PATH" -t "$TITLE_NUM" -n "$TITLE_NUM" -o "$TMP_DIR/vobs" &>/dev/null

  readarray -t AUDIO_META < <(lsdvd -a -t "$TITLE_NUM" "$DVD_PATH" 2>/dev/null | awk '
    BEGIN {
      audio_track_num = 0
    }

    /^[[:blank:]]+Audio: / {
      split($0, fields, ",")
      for (i in fields) {
        split(fields[i], field, ":")
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", field[1])
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", field[2])
        key = field[1]
        value = field[2]

        if (key == "Language") {
          split(value, parts, " ")
          pairs["language"] = parts[1]
        } else if (key == "Format") {
          pairs["format"] = value
        } else if (key == "Channels") {
          pairs["channels"] = value
        } else if (key == "Content") {
          pairs["content"] = value
        } else if (key == "Stream id") {
          pairs["id"] = value
        }
      }

      print audio_track_num "," pairs["language"] "," pairs["format"] "," pairs["channels"] "," pairs["content"] "," pairs["id"]

      audio_track_num++
      delete pairs
    }
  ')

  readarray -t SUBTITLE_META < <(lsdvd -s -t "$TITLE_NUM" "$DVD_PATH" 2>/dev/null | awk '
    BEGIN {
      subtitle_track_num = 0
    }

    /^[[:blank:]]+Subtitle: / {
      split($0, fields, ",")
      for (i in fields) {
        split(fields[i], field, ":")
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", field[1])
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", field[2])
        key = field[1]
        value = field[2]

        if (key == "Language") {
          split(value, parts, " ")
          pairs["language"] = parts[1]
        } else if (key == "Content") {
          pairs["content"] = value
        } else if (key == "Stream id") {
          pairs["id"] = value
        }
      }

      print subtitle_track_num "," pairs["language"] "," pairs["content"] "," pairs["id"]

      subtitle_track_num++
      delete pairs
    }
  ')

  VOB_NUM=0
  for VOB in "$TMP_DIR/vobs/$TITLE_NUM/VIDEO_TS/"*; do
    declare -A AUDIO_ID_TO_SOURCE_TRACK_NUM
    AUDIO_ID_TO_SOURCE_TRACK_NUM=()

    while read LINE; do
      if [ -n "$LINE" ]; then
        AUDIO_ID_TO_SOURCE_TRACK_NUM["$(jq -r '.id' <<< "$LINE")"]="$(jq -r '.index' <<< "$LINE")"
      fi
    done < <(ffprobe -analyzeduration 7200G \
      -probesize 10G \
      -v quiet \
      -show_entries stream=id,index \
      -select_streams a \
      -of json \
      "$VOB" | jq -c '.streams[]'
    )
    
    declare -A SUBTITLE_ID_TO_SOURCE_TRACK_NUM
    SUBTITLE_ID_TO_SOURCE_TRACK_NUM=()

    while read LINE; do
      if [ -n "$LINE" ]; then
        SUBTITLE_ID_TO_SOURCE_TRACK_NUM["$(jq -r '.id' <<< "$LINE")"]="$(jq -r '.index' <<< "$LINE")"
      fi
    done < <(ffprobe -analyzeduration 7200G \
      -probesize 10G \
      -v quiet \
      -show_entries stream=id,index \
      -select_streams s \
      -of json \
      "$VOB" | jq -c '.streams[]'
    )
    
    declare -a INPUTS
    INPUTS=("$VOB")

    declare -a MAP_ARGS
    MAP_ARGS=()

    MAP_ARGS+=("-map")
    MAP_ARGS+=("0:v:0")

    declare -a AUDIO_ARGS
    AUDIO_ARGS=()

    for LINE in "${AUDIO_META[@]}"; do
      if [ -n "$LINE" ]; then
        IFS="," read -ra TRACK_META <<< "$LINE"
        OUT_TRACK_NUM="${TRACK_META[0]}"
        LANGUAGE="${TRACK_META[1]}"
        FORMAT="${TRACK_META[2]}"
        CHANNELS="${TRACK_META[3]}"
        CONTENT="${TRACK_META[4]}"
        ID="${TRACK_META[5]}"

        SOURCE_TRACK_NUM="${AUDIO_ID_TO_SOURCE_TRACK_NUM[$ID]}"

        MAP_ARGS+=("-map")
        MAP_ARGS+=("0:$SOURCE_TRACK_NUM")

        AUDIO_ARGS+=("-filter:a:$OUT_TRACK_NUM")
        AUDIO_ARGS+=("atempo=0.96")

        AUDIO_ARGS+=("-c:a:$OUT_TRACK_NUM")
        AUDIO_ARGS+=("ac3")

        AUDIO_ARGS+=("-b:a:$OUT_TRACK_NUM")
        if [ "$FORMAT" = "ac3" ]; then
          AUDIO_ARGS+=("$(ffprobe -analyzeduration 7200G \
            -probesize 10G \
            -v quiet \
            -select_streams "a:$OUT_TRACK_NUM" \
            -show_entries stream=bit_rate \
            -of json \
            "$VOB" | jq -r '.streams[0].bit_rate'
          )")
        elif [ $CHANNELS -gt 2 ]; then
          AUDIO_ARGS+=("448k")
        else
          AUDIO_ARGS+=("192k")
        fi

        if [ -n "$LANGUAGE" ]; then
          AUDIO_ARGS+=("-metadata:s:a:$OUT_TRACK_NUM")
          AUDIO_ARGS+=("language=$(isoquery --iso=639-2 $LANGUAGE | cut -f1)")
        fi

        if [ "$CONTENT" = "Comments1" ] || [ "$CONTENT" = "DirectorsComments" ]; then
          AUDIO_ARGS+=("-metadata:s:a:$OUT_TRACK_NUM")
          AUDIO_ARGS+=("title=Director's Commentary")
        elif [ "$CONTENT" = "Comments2" ]; then
          AUDIO_ARGS+=("-metadata:s:a:$OUT_TRACK_NUM")
          AUDIO_ARGS+=("title=Additional Commentary")
        elif [ "$CONTENT" = "VisuallyImpaired" ]; then
          AUDIO_ARGS+=("-metadata:s:a:$OUT_TRACK_NUM")
          AUDIO_ARGS+=("title=Audio Description")
        elif [ "$CONTENT" = "AlternateGroup" ]; then
          AUDIO_ARGS+=("-metadata:s:a:$OUT_TRACK_NUM")
          AUDIO_ARGS+=("title=Alternative Audio")
        elif [ "$CONTENT" = "Music" ]; then
          AUDIO_ARGS+=("-metadata:s:a:$OUT_TRACK_NUM")
          AUDIO_ARGS+=("title=Music")
        elif [ "$CONTENT" = "Effects" ]; then
          AUDIO_ARGS+=("-metadata:s:a:$OUT_TRACK_NUM")
          AUDIO_ARGS+=("title=Sound Effects")
        fi
      fi
    done

    declare -a SUBTITLE_ARGS
    SUBTITLE_ARGS=()

    for LINE in "${SUBTITLE_META[@]}"; do
      if [ -n "$LINE" ]; then
        IFS="," read -ra TRACK_META <<< "$LINE"
        SUBTITLE_TRACK_NUM="${TRACK_META[0]}"
        LANGUAGE="${TRACK_META[1]}"
        CONTENT="${TRACK_META[2]}"
        ID="${TRACK_META[3]}"

        echo "Processing subtitle track $((${SUBTITLE_TRACK_NUM}+1))/${#SUBTITLE_META[@]}"

        if [[ ! -v SUBTITLE_ID_TO_SOURCE_TRACK_NUM["$ID"] ]]; then
          continue
        fi

        SOURCE_TRACK_NUM="${SUBTITLE_ID_TO_SOURCE_TRACK_NUM["$ID"]}"

        RESOLUTION="$(ffprobe -analyzeduration 7200G \
          -probesize 10G \
          -v error \
          -select_streams v:0 \
          -show_entries stream=width,height \
          -of json \
          "$VOB" | jq -r '.streams[0] | "\(.width)x\(.height)"')"

        DURATION="$(ffprobe -analyzeduration 7200G \
          -probesize 10G \
          -v error \
          -show_entries format=duration \
          -of json \
          "$VOB" | jq -r '.format.duration')"
        
        FIRST_TIMESTAMP_SECONDS="$(ffprobe -analyzeduration 7200G \
          -probesize 10G \
          -v error \
          -select_streams ${SOURCE_TRACK_NUM} \
          -show_entries packet=pts_time \
          -read_intervals "%+#1" \
          -of json \
          "$VOB" | jq -r '.packets[0].pts_time')"

        mkdir -p "${TMP_DIR}/subs"

        ffmpeg -f lavfi \
          -i "nullsrc=s=${RESOLUTION}:r=1:d=${DURATION}" \
          -analyzeduration 7200G \
          -probesize 10G \
          -i "$VOB" \
          -threads 16 \
          -map 0:v:0 \
          -c:v libx264 \
          -preset ultrafast \
          -map "1:${SOURCE_TRACK_NUM}" \
          -c:s copy \
          "${TMP_DIR}/subs/${SUBTITLE_TRACK_NUM}.mp4" &> /dev/null

        mencoder "${TMP_DIR}/subs/${SUBTITLE_TRACK_NUM}.mp4" \
          -nosound \
          -ovc copy \
          -o /dev/null \
          -vobsubout \
          "${TMP_DIR}/subs/${SUBTITLE_TRACK_NUM}" &> /dev/null

        awk -v delay="$FIRST_TIMESTAMP_SECONDS" '
          BEGIN { FS=": ";  OFS=": " }

          /^timestamp:/ {
            split($2, t, "[,:]")
            total_ms = ((t[1] * 3600 + t[2] * 60 + t[3] + delay) * 1000 + t[4]) / 0.96
            h = int(total_ms / (3600 * 1000))
            m = int((total_ms % (3600 * 1000)) / (60 * 1000))
            s = int((total_ms % (60 * 1000)) / 1000)
            ms = int(total_ms % 1000)
            $2 = sprintf("%02d:%02d:%02d:%03d,%s", h, m, s, ms, t[5])
          }

          { print }
        ' "${TMP_DIR}/subs/${SUBTITLE_TRACK_NUM}.idx" > "${TMP_DIR}/subs/${SUBTITLE_TRACK_NUM}.stretch.idx"

        mv "${TMP_DIR}/subs/${SUBTITLE_TRACK_NUM}.stretch.idx" "${TMP_DIR}/subs/${SUBTITLE_TRACK_NUM}.idx"

        INPUTS+=("${TMP_DIR}/subs/${SUBTITLE_TRACK_NUM}.idx")

        MAP_ARGS+=("-map")
        MAP_ARGS+=("$((${#INPUTS[@]}-1)):s:0")

        SUBTITLE_ARGS+=("-c:s:$SUBTITLE_TRACK_NUM")
        SUBTITLE_ARGS+=("copy")

        if [ -n "$LANGUAGE" ]; then
          SUBTITLE_ARGS+=("-metadata:s:s:$SUBTITLE_TRACK_NUM")
          SUBTITLE_ARGS+=("language=$(isoquery --iso=639-2 $LANGUAGE | cut -f1)")
        fi

        if [ "$CONTENT" = "Normal" ]; then
          SUBTITLE_ARGS+=("-disposition:s:$SUBTITLE_TRACK_NUM")
          SUBTITLE_ARGS+=("default")
        elif [ "$CONTENT" = "Forced" ]; then
          SUBTITLE_ARGS+=("-disposition:s:$SUBTITLE_TRACK_NUM")
          SUBTITLE_ARGS+=("forced")
          SUBTITLE_ARGS+=("-metadata:s:s:$SUBTITLE_TRACK_NUM")
          SUBTITLE_ARGS+=("title=Foreign Language Only")
        elif [ "$CONTENT" = "Closed Caption" ]; then
          SUBTITLE_ARGS+=("-disposition:s:$SUBTITLE_TRACK_NUM")
          SUBTITLE_ARGS+=("captions")
          SUBTITLE_ARGS+=("-metadata:s:s:$SUBTITLE_TRACK_NUM")
          SUBTITLE_ARGS+=("title=SDH")
        else
          SUBTITLE_ARGS+=("-disposition:s:$SUBTITLE_TRACK_NUM")
          SUBTITLE_ARGS+=("0")
        fi
      fi
    done

    lsdvd -c -t "$TITLE_NUM" "$DVD_PATH" 2>/dev/null | awk '
      BEGIN {
        print ";FFMETADATA1"
        cumulative_length_ms = 0
        speed_ratio = 25.0/24.0
      }
      /^[[:space:]]+Chapter: / {
        split($0, fields, ",")

        chapter_num=""
        chapter_length_ms=""

        for (i in fields) {
          pos = index(fields[i], ":")
          if (pos > 0) {
            key = substr(fields[i], 1, pos-1)
            value = substr(fields[i], pos+1)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
          }

          if (key == "Chapter") {
            chapter_num = value
          } else if (key == "Length") {
            split(value, time, ":")
            if (length(time) == 3) {
              chapter_length_ms=(time[1] * 3600 + time[2] * 60 + time[3]) * 1000
            }
          }
        }

        if (chapter_num != "" && chapter_length_ms != "") {
          print ""
          print "[CHAPTER]"
          print "TIMEBASE=1/1000"
          printf "START=%d\n", (cumulative_length_ms * speed_ratio)
          cumulative_length_ms += chapter_length_ms
          printf "END=%d\n", (cumulative_length_ms * speed_ratio)
          printf "title=Chapter %d\n", chapter_num
        }
      }
    ' > "$TMP_DIR/chapters.txt"

    INPUTS+=("$TMP_DIR/chapters.txt")
    MAP_ARGS+=("-map_metadata")
    MAP_ARGS+=("$((${#INPUTS[@]}-1))")

    declare -a INPUT_ARGS
    INPUT_ARGS=()

    for INPUT in "${INPUTS[@]}"; do
      INPUT_ARGS+=("-i" "$INPUT")
    done
    
    echo "Encoding Title ${TITLE_NUM}/${#TITLE_NUMS[@]}"

    mkdir -p "$TMP_DIR/encoded"

    ffmpeg \
      "${INPUT_ARGS[@]}" \
      -threads 16 \
      "${MAP_ARGS[@]}" \
      -filter:v "nnedi=weights=nnedi3_weights.bin:nsize=s8x4:nns=n128:qual=1:etype=s:pscrn=new,fps=round=zero,setpts=25/24*PTS,fps=24" \
      -c:v libx265 \
      -crf 20 \
      -preset medium \
      -tune animation \
      -profile:v main \
      -level:v 51 \
      "${AUDIO_ARGS[@]}" \
      "${SUBTITLE_ARGS[@]}" \
      "$TMP_DIR/encoded/$TITLE_NUM.$VOB_NUM.mp4"

    mkdir -p "$OUTPUT_PATH"

    mv "$TMP_DIR/encoded/$TITLE_NUM.$VOB_NUM.mp4" "$OUTPUT_PATH/$TITLE_NUM.$VOB_NUM.mp4"

    VOB_NUM=$((VOB_NUM + 1))

    rm "$VOB"
    rm -rf "${TMP_DIR}/subs"
  done

  rm -rf "$TMP_DIR/$TITLE_NUM"
  
  echo ""
  echo ""
done