#!/bin/sh

# simple log file
LOG_FILE="/config/rss-triggered.log"
touch "$LOG_FILE"

trim() {
  echo "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

add_from_feed() {
  FEED="$1"
  LABEL="$2"

  [ -z "$FEED" ] && return 0

  if ! XML=$(curl -fs "$FEED"); then
    return 0
  fi

  echo "$XML" | grep -o 'magnet:[^"<]*' | while read -r MAGNET; do
    [ -z "$MAGNET" ] && continue

    # skip if already triggered
    if grep -Fxq "$MAGNET" "$LOG_FILE"; then
      echo "[RSS] Skipping already downloaded: $MAGNET"
      continue
    fi

    transmission-remote localhost:${WEBUI} \
      --auth "${WEBUSER}:${WEBPASS}" \
      --add "$MAGNET" \
      --L "$LABEL"

    # ADDED: log it
    echo "$MAGNET" >> "$LOG_FILE"
  done

  echo "$XML" | grep -o 'http[^"<]*\.torrent' | while read -r TORRENT; do
    [ -z "$TORRENT" ] && continue

    # skip if already triggered
    if grep -Fxq "$TORRENT" "$LOG_FILE"; then
      echo "[RSS] Skipping already downloaded: $TORRENT"
      continue
    fi

    transmission-remote localhost:${WEBUI} \
      --auth "${WEBUSER}:${WEBPASS}" \
      --add "$TORRENT" \
      --L "$LABEL"

    # ADDED: log it
    echo "$TORRENT" >> "$LOG_FILE"
  done
}

[ -z "$RSSFEEDS" ] && exit 0

OLDIFS="$IFS"
IFS=','
for ITEM in $RSSFEEDS; do
  ITEM=$(trim "$ITEM")
  [ -z "$ITEM" ] && continue

  case "$ITEM" in
    *:*)
      LABEL=$(trim "${ITEM%%:*}")
      FEED=$(trim "${ITEM#*:}")
      ;;
    *)
      continue
      ;;
  esac

  [ -z "$LABEL" ] && continue
  [ -z "$FEED" ] && continue

  add_from_feed "$FEED" "$LABEL"
done
IFS="$OLDIFS"
