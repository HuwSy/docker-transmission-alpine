#!/bin/sh

TORRENT_ID="$TR_TORRENT_ID"
IS_PRIVATE="$TR_TORRENT_IS_PRIVATE"
RETRACKER_FILE="/config/retracker.txt"
RETRACKER_URL="https://raw.githubusercontent.com/ngosang/trackerslist/master/trackers_best.txt"

[ "$IS_PRIVATE" = "1" ] && exit 0

if [ -f "$RETRACKER_FILE" ]; then
  AGE=$(( $(date +%s) - $(stat -c %Y "$RETRACKER_FILE") ))
  if [ "$AGE" -gt 172800 ]; then
    curl -fsSL "$RETRACKER_URL" -o "$RETRACKER_FILE"
  fi
else
  curl -fsSL "$RETRACKER_URL" -o "$RETRACKER_FILE"
fi

[ ! -f "$RETRACKER_FILE" ] && exit 0

while IFS= read -r TRACKER; do
  [ -z "$TRACKER" ] && continue

  transmission-remote localhost:${WEBUI} \
    --auth "${WEBUSER}:${WEBPASS}" \
    --torrent "$TORRENT_ID" \
    --tracker-add "$TRACKER"

done < "$RETRACKER_FILE"
