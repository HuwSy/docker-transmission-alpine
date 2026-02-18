#!/bin/sh

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
    transmission-remote localhost:${WEBUI} \
      --auth "${WEBUSER}:${WEBPASS}" \
      --add "$MAGNET" \
      --torrent-label "$LABEL"
  done

  echo "$XML" | grep -o 'http[^"<]*\.torrent' | while read -r TORRENT; do
    [ -z "$TORRENT" ] && continue
    transmission-remote localhost:${WEBUI} \
      --auth "${WEBUSER}:${WEBPASS}" \
      --add "$TORRENT" \
      --torrent-label "$LABEL"
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
      LABEL="${ITEM%%:*}"
      FEED="${ITEM#*:}"
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
