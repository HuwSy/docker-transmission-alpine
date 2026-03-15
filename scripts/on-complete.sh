#!/bin/sh

TID="${TR_TORRENT_ID:-}"
NAME="${TR_TORRENT_NAME:-}"
DIR="${TR_TORRENT_DIR:-}"
LABEL="${TR_TORRENT_LABELS:-}"
case "$LABEL" in
  *','*) LABEL="${LABEL%%,*}" ;;
esac

LOG_FILE="/config/torrent-complete.log"

timestamp() {
  date -u +"%Y-%m-%d %H:%M:%S UTC"
}

# defaults: 60 minutes wait for labeled, 1440 for unlabeled
MAX_MIN=60
RATIO_THRESHOLD="2.0"
[ -z "$LABEL" ] && MAX_MIN=1440 && RATIO_THRESHOLD="5.0"

printf '%s: %s (%s) Completed awaiting ratio %s or %s min\n' "$(timestamp)" "$NAME" "$LABEL" "$RATIO_THRESHOLD" "$MAX_MIN" >> "$LOG_FILE"

ratio=""
c=0
while [ "$c" -lt "$MAX_MIN" ]; do
  info=$(transmission-remote "localhost:${WEBUI}" --auth "${WEBUSER}:${WEBPASS}" --torrent "$TID" -i 2>/dev/null || true)
  # extract Ratio: value (strip trailing x)
  ratio=$(printf '%s\n' "$info" | awk -F': ' '/^[[:space:]]*Ratio/ {gsub(/x/,"",$2); print $2; exit}')
  ratio="${ratio:-0}"
  # ensure numeric and compare as float using awk
  if printf '%s\n' "$ratio" | grep -Eq '^[0-9]+([.][0-9]+)?$'; then
    if awk -v r="$ratio" -v t="$RATIO_THRESHOLD" 'BEGIN{ if (r+0 >= t+0) exit 0; exit 1 }'; then
      break
    fi
  fi
  sleep 60
  c=$((c + 1))
done

printf '%s: %s (%s) Completed ratio %s in %s min\n' "$(timestamp)" "$NAME" "$LABEL" "$ratio" "$c" >> "$LOG_FILE"

# re-fetch label if blank (labels may be added after completion)
if [ -z "$LABEL" ]; then
  label_info=$(transmission-remote "localhost:${WEBUI}" --auth "${WEBUSER}:${WEBPASS}" -t "$TID" 2>/dev/null || true)
  LABEL=$(printf '%s\n' "$label_info" | awk 'BEGIN{found=0} /^[[:space:]]*Labels:/ {found=1; next} found && NF{ gsub(/^ *| *$/,""); split($0,a,","); print a[1]; exit }')
  LABEL="${LABEL:-}"
  if [ -n "$LABEL" ]; then
    printf '%s: %s Completed and relabeled %s\n' "$(timestamp)" "$NAME" "$LABEL" >> "$LOG_FILE"
  fi
fi

[ -z "$LABEL" ] && exit 0

# Capitalize first ASCII letter of label
FIRST_CHAR=$(printf '%s' "$LABEL" | cut -c1 | tr '[:lower:]' '[:upper:]' || true)
REST=$(printf '%s' "$LABEL" | cut -c2- || true)
CAP_LABEL="${FIRST_CHAR}${REST}"

# Category handling (simple, robust transformations)
case "$CAP_LABEL" in
  Film|Films|Movie|Movies)
    # first character of torrent name for folder grouping
    FN=$(printf '%s' "$NAME" | cut -c1 | tr '[:lower:]' '[:upper:]' || true)
    case "$FN" in
      [A-Z]) FIRST_CHAR="$FN" ;;
      *) FIRST_CHAR="0-9" ;;
    esac
    CAP_LABEL="Films/$FIRST_CHAR"
    ;;
  Tv|TV|Television|Shows)
    # remove common season/episode markers and non-letters; keep words separated by spaces
    SHOW_NAME=$(printf '%s' "$NAME" | sed -E 's/([Ss][0-9]+|[Yy][0-9]{4}|[Ss]eason[^ ]*|[Ee]pisode[^ ]*|[Pp]art[^ ]*|[Vv]olume[^ ]*|[Dd]isc[^ ]*|[Cc]omplete).*//')
    SHOW_NAME=$(printf '%s' "$SHOW_NAME" | sed -E 's/[^A-Za-z]+/ /g' | sed -E 's/^ +| +$//g' | sed -E 's/ +/ /g')
    [ -z "$SHOW_NAME" ] && SHOW_NAME="Unknown"
    CAP_LABEL="TV/$SHOW_NAME"
    ;;
  Music|Songs|Albums|Singles)
    MUSIC_NAME=$(printf '%s' "$NAME" | sed -E 's/\.[^.]+$//')
    CAP_LABEL="Music/$MUSIC_NAME"
    ;;
  *)
    CAP_LABEL="$CAP_LABEL"
    ;;
esac

SRC="${DIR%/}/${NAME}"
DEST="/downloads/completed/${CAP_LABEL}"

printf '%s: %s (%s) Completed moving to %s\n' "$(timestamp)" "$NAME" "$LABEL" "$DEST" >> "$LOG_FILE"
mkdir -p "$DEST"

# stop torrent first
transmission-remote "localhost:${WEBUI}" --auth "${WEBUSER}:${WEBPASS}" --torrent "$TID" --stop >/dev/null 2>&1 || true

# move contents of SRC into DEST (works for single-file and multi-file torrents)
if [ -d "$SRC" ]; then
  # remove common sidecar files before move (case-insensitive)
  find "$SRC" -type f \( -iname '*.txt' -o -iname '*.nfo' -o -iname '*.inf' -o -iname '*.sample' \) -exec rm -f {} \; 2>/dev/null || true
  # move each entry inside SRC to DEST; ignore errors if nothing to move
  find "$SRC" -mindepth 1 -maxdepth 2 -exec mv -f {} "$DEST"/ \; 2>/dev/null || true
  # attempt to remove empty source dir
  rmdir "$SRC" 2>/dev/null || true
else
  # if SRC is a file path, move it
  if [ -e "$SRC" ]; then
    mv -f "$SRC" "$DEST"/ 2>/dev/null || true
  fi
fi

# remove torrent from client (does not delete data)
transmission-remote "localhost:${WEBUI}" --auth "${WEBUSER}:${WEBPASS}" --torrent "$TID" --remove >/dev/null 2>&1 || true

printf '%s: %s (%s) Completed moved and cleaned\n' "$(timestamp)" "$NAME" "$LABEL" >> "$LOG_FILE"
