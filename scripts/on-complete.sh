#!/bin/sh

TID="${TR_TORRENT_ID:-}"
NAME="${TR_TORRENT_NAME:-}"
LABEL="${TR_TORRENT_LABELS:-}"

cd "${TR_TORRENT_DIR:-/downloads}"

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

# re-fetch label and name (labels may be added after completion or names cleaned)
Tinfo=$(transmission-remote "localhost:${WEBUI}" --auth "${WEBUSER}:${WEBPASS}" -t "$TID" 2>/dev/null || true)

NLABEL=$(printf '%s\n' "$Tinfo" | awk 'BEGIN{found=0} /^[[:space:]]*Labels:/ {found=1; next} found && NF{ gsub(/^ *| *$/,""); split($0,a,","); print a[1]; exit }')
if [ -n "$NLABEL" ]; then
  case "$NLABEL" in
    Film|Films|Movie|Movies|TV|Tv|Television|Shows|Music|Songs|Albums|Singles)
      LABEL="$NLABEL"
      ;;
  esac
fi

NNAME=$(printf '%s\n' "$Tinfo" | awk -F': ' '/^[[:space:]]*Name:/ {print $2; exit}')
if [ -n "$NNAME" ] && [ -e "$NNAME" ]; then
  NAME="$NNAME"
fi

[ -z "$LABEL" ] && exit 0
[ -z "$NAME" ] && exit 0

DEST="completed/"

# Category handling (simple, robust transformations)
case "$LABEL" in
  Film|Films|Movie|Movies)
    # first character of torrent name for folder grouping
    FN=$(printf '%s' "$NAME" | cut -c1 | tr '[:lower:]' '[:upper:]' || true)
    case "$FN" in
      [A-Z]) FIRST_CHAR="$FN" ;;
      *) FIRST_CHAR="0-9" ;;
    esac
    DEST="completed/Films/$FIRST_CHAR/"
    ;;
  TV|Tv|Television|Shows)
    # remove common season/episode markers and non-letters; keep words separated by spaces
    SHOW_NAME=$(printf '%s' "$NAME" \
      | sed -E 's/^[Ww]{3}\.[A-Za-z0-9]+(\.[A-Za-z]+)+[[:space:]_-]*//' \
      | sed -E 's/([Ss][0-9]+|[Yy][0-9]{4}|[Ss]eason[^ ]*|[Ee]pisode[^ ]*|[Pp]art[^ ]*|[Vv]olume[^ ]*|[Dd]isc[^ ]*|[Cc]omplete).*//' \
      | sed -E 's/[^A-Za-z0-9]+/ /g' \
      | sed -E 's/^ +| +$//g' \
      | sed -E 's/ +/ /g' \
      | tr '[:upper:]' '[:lower:]' \
      | awk '{
        for(i=1;i<=NF;i++){
          $i = toupper(substr($i,1,1)) (length($i)>1 ? substr($i,2) : "")
        }
        print
      }')
    DEST="completed/TV/$SHOW_NAME/"
    ;;
  Music|Songs|Albums|Singles)
    MUSIC_NAME=$(printf '%s' "$NAME" | sed -E 's/\.[^.]+$//')
    DEST="completed/Music/$MUSIC_NAME/"
    ;;
esac

printf '%s: %s (%s) Completed moving to %s\n' "$(timestamp)" "$NAME" "$LABEL" "$DEST" >> "$LOG_FILE"
mkdir -p -- "$DEST"

# stop torrent first
transmission-remote "localhost:${WEBUI}" --auth "${WEBUSER}:${WEBPASS}" --torrent "$TID" --stop >/dev/null 2>&1 || true

# move contents of NAME into DEST (works for single-file and multi-file torrents)
if [ -f "$NAME" ] || [ -d "$NAME" ]; then
  # remove common sidecar files before move (case-insensitive)
  find "$NAME" -type f \( -iname '*.txt' -o -iname '*.nfo' -o -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' \) -exec rm -f -- "{}" \; 2>/dev/null || true
  # move each entry inside NAME upto depth of 3 to DEST
  find "$NAME" -maxdepth 3 -type f -exec mv -- "{}" "$DEST" \; 2>>"$LOG_FILE" || exit 1
  # attempt to remove empty source dir
  find "$NAME" -depth -type d -empty -delete 2>/dev/null || true
else
  printf '%s: %s (%s) Error is not a dir or file\n' "$(timestamp)" "$NAME" "$LABEL" >> "$LOG_FILE"
  exit 1
fi

# remove torrent from client (does not delete data)
transmission-remote "localhost:${WEBUI}" --auth "${WEBUSER}:${WEBPASS}" --torrent "$TID" --remove >/dev/null 2>&1 || true

printf '%s: %s (%s) Completed moved and cleaned\n' "$(timestamp)" "$NAME" "$LABEL" >> "$LOG_FILE"
