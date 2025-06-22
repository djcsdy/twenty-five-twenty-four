#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

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

if [ $# -lt 2 ]; then
    echo "Usage: $0 /path/to/dvd output/path"
    exit 1
fi

DVD_PATH="$1"
OUTPUT_PATH="$2"

TMP_DIR=$(mktemp -d)

for TITLE_NUM in $(dvdbackup -i "$DVD_PATH" -I 2>/dev/null | grep -oP "^\s+Title \K\d+(?=:$)"); do
  dvdbackup -i "$DVD_PATH" -t "$TITLE_NUM" -n "$TITLE_NUM" -o "$TMP_DIR/vobs"

  AUDIO_META=$(lsdvd -a -t "$TITLE_NUM" "$DVD_PATH" | awk '
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

  SUBTITLE_META=$(lsdvd -s -t "$TITLE_NUM" "$DVD_PATH" | awk '
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
        IFS="," read -r NUM ID <<< "$LINE"
        AUDIO_ID_TO_SOURCE_TRACK_NUM[$ID]="$NUM"
      fi
    done < <(ffprobe -analyzeduration 120M \
      -probesize 1440M \
      -v quiet \
      -show_entries stream=id,index \
      -select_streams a \
      -of csv=p=0 \
      "$VOB"
    )
    
    declare -A SUBTITLE_ID_TO_SOURCE_TRACK_NUM
    SUBTITLE_ID_TO_SOURCE_TRACK_NUM=()

    while read LINE; do
      if [ -n "$LINE" ]; then
        IFS="," read -r VALUE KEY <<< "$LINE"
        SUBTITLE_ID_TO_SOURCE_TRACK_NUM[$KEY]=$VALUE
      fi
    done < <(ffprobe -analyzeduration 120M \
      -probesize 1440M \
      -v quiet \
      -show_entries stream=id,index \
      -select_streams s \
      -of csv=p=0 \
      "$VOB"
    )

    declare -a MAP_ARGS
    MAP_ARGS=()

    MAP_ARGS+=("-map")
    MAP_ARGS+=("0:v:0")

    declare -a AUDIO_ARGS
    AUDIO_ARGS=()

    while read LINE; do
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
          AUDIO_ARGS+=("$(ffprobe -v quiet -select_streams "a:$OUT_TRACK_NUM" \
            -show_entries stream=bit_rate -of csv=p=0 "$VOB"
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
    done <<< "$AUDIO_META"

    declare -a SUBTITLE_ARGS
    SUBTITLE_ARGS=()

    while read LINE; do
      if [ -n "$LINE" ]; then
        IFS="," read -ra TRACK_META <<< "$LINE"
        SUBTITLE_TRACK_NUM="${TRACK_META[0]}"
        LANGUAGE="${TRACK_META[1]}"
        CONTENT="${TRACK_META[2]}"
        ID="${TRACK_META[3]}"

        SOURCE_TRACK_NUM="${SUBTITLE_ID_TO_SOURCE_TRACK_NUM[$ID]}"

        MAP_ARGS+=("-map")
        MAP_ARGS+=("0:$SOURCE_TRACK_NUM")

        SUBTITLE_ARGS+=("-filter:s:$SUBTITLE_TRACK_NUM")
        SUBTITLE_ARGS+=("setpts=24/25*PTS")

        SUBTITLE_ARGS+=("-c:s:$SUBTITLE_TRACK_NUM")
        SUBTITLE_ARGS+=("dvdsub")

        if [ -n "$LANGUAGE" ]; then
          SUBTITLE_ARGS+=("-metadata:s:s:$SUBTITLE_TRACK_NUM")
          SUBTITLE_ARGS+=("language=$(isoquery --iso=639-2 $LANGUAGE | cut -f1)")
        fi

        if [ "$CONTENT" = "Normal" ]; then
          SUBTITLE_ARGS+=("-disposition:s:$SUBTITLE_TRACK_NUM")
          SUBTITLE_ARGS+=("0")
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
        fi
      fi
    done <<< "$SUBTITLE_META"

    MAP_ARGS+=("-map")
    MAP_ARGS+=("0:t:0?")

    mkdir -p "$TMP_DIR/encoded"

    ffmpeg \
      -analyzeduration 120M \
      -probesize 1440M \
      -i "$VOB" \
      -threads 16 \
      "${MAP_ARGS[@]}" \
      -r 24 \
      -filter:v "setpts=25/24*PTS" \
      -c:v libx265 \
      -crf 20 \
      -preset medium \
      -tune animation \
      -profile:v main \
      -level:v 51 \
      "${AUDIO_ARGS[@]}" \
      "${SUBTITLE_ARGS[@]}" \
      -filter:t "setpts=25/24*PTS" \
      -c:t copy \
      "$TMP_DIR/encoded/$TITLE_NUM.$VOB_NUM.mp4"

    mkdir -p "$OUTPUT_PATH"

    mv "$TMP_DIR/encoded/$TITLE_NUM.$VOB_NUM.mp4" "$OUTPUT_PATH/$TITLE_NUM.$VOB_NUM.mp4"

    VOB_NUM=$[VOB_NUM + 1]

    rm "$VOB"
  done

  rm -rf "$TMP_DIR/$TITLE_NUM"
done

rm -rf "$TMP_DIR"
