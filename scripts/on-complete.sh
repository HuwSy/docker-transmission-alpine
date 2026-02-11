#!/bin/sh

TORRENT_ID="$TR_TORRENT_ID"
LABEL=$(echo "$TR_TORRENT_LABELS" | cut -d',' -f1)
[ -z "$LABEL" ] && exit 0

FIRST=$(printf "%s" "$LABEL" | cut -c1 | tr '[:lower:]' '[:upper:]')
REST=$(printf "%s" "$LABEL" | cut -c2-)
CAP_LABEL="${FIRST}${REST}"

if [ "$CAP_LABEL" = "Film" ] || [ "$CAP_LABEL" = "Movie" ] || [ "$CAP_LABEL" = "Movies" ]; then
  FIRST_CHAR=$(printf "%s" "$TR_TORRENT_NAME" | cut -c1 | tr '[:lower:]' '[:upper:]')
  if ! printf "%s" "$FIRST_CHAR" | grep -q '[A-Z]'; then
    FIRST_CHAR="0-9"
  fi
  CAP_LABEL="Films/$FIRST_CHAR"
elif [ "$CAP_LABEL" = "Tv" ] || [ "$CAP_LABEL" = "Television" ] || [ "$CAP_LABEL" = "Shows" ]; then
  SHOW_NAME=$(printf "%s" "$TR_TORRENT_NAME" | sed -E 's/([Ss][0-9]+|[Yy][0-9]{4}|[Ss]eason.*|[Ee]pisode.*|[Pp]art.*|[Vv]olume.*|[Dd]isc.*).*//')
  SHOW_NAME=$(printf "%s" "$SHOW_NAME" | sed -E 's/[^A-Za-z]+/ /g' | sed -E 's/(^| )([a-z])/\U\2/g')
  CAP_LABEL="TV/$SHOW_NAME"
elif [ "$CAP_LABEL" = "Songs" ] || [ "$CAP_LABEL" = "Albums" ] || [ "$CAP_LABEL" = "Singles" ]; then
  MUSIC_NAME=$(printf "%s" "$TR_TORRENT_NAME" | sed -E 's/\.[^.]+$//')
  CAP_LABEL="Music/$MUSIC_NAME"
fi

SRC="${TR_TORRENT_DIR}/${TR_TORRENT_NAME}"
DEST="/downloads/completed/${CAP_LABEL}"

# loop up to 60 minutes
i=60
while [ $i -gt 0 ]; do
  ratio=$(transmission-remote localhost:${WEBUI} \
    --auth "${WEBUSER}:${WEBPASS}" \
    --torrent "$TORRENT_ID" \
    -i 2>/dev/null | \
    awk -F': ' '/Ratio/ {gsub(/x/,"",$2); print $2; exit}'
  )
  awk -v r="$ratio" -v t="2.0" 'BEGIN{if (r+0 >= t+0) exit 0; exit 1}'
  if [ $? -eq 0 ]; then
    i=0
  else
    sleep 60
  fi
  i=$((i-1))
done

mkdir -p "$DEST"
transmission-remote localhost:${WEBUI} \
    --auth "${WEBUSER}:${WEBPASS}" \
    --torrent "$TORRENT_ID" \
    --stop

rm "$SRC"/*.{txt,nfo,inf,sub,sample} 2>/dev/null || true
rm "$SRC"/*{S,s}ample*.* 2>/dev/null || true

mv "$SRC"/*.* "$DEST/" || mv "$SRC" "$DEST/"

rmdir "$SRC" 2>/dev/null || true
