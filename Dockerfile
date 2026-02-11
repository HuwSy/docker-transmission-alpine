# -----------------------------
# Stage 1
# -----------------------------
FROM alpine:edge

ENV WEBUI=8080 \
  INCOMING=17000 \
  UPNP=false \
  WEBUSER=admin \
  WEBPASS="" \
  RSSFEEDS="" \
  SCHEDULE="*/30 * * * *"

RUN apk add --no-cache \
  transmission-daemon \
  transmission-cli \
  tini ca-certificates curl grep sed jq

RUN mkdir -p /config /downloads /opt/default-scripts && \
  chmod 0755 /config /downloads && \
  chmod 0755 /opt/default-scripts

# -----------------------------
# Default scripts (baked in)
# -----------------------------
# Post-download mover
RUN cat > /opt/default-scripts/on-complete.sh <<'EOF'
#!/bin/sh

LABEL=$(echo "$TR_TORRENT_LABELS" | cut -d',' -f1)
[ -z "$LABEL" ] && exit 0

# process label names
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
else
  # any other semingly logical rules here... above are possible examples fed by copilot so probably need sanity check but the script will be in a usable folder to edit post run
fi

SRC="${TR_TORRENT_DIR}/${TR_TORRENT_NAME}"
DEST="/downloads/completed/${CAP_LABEL}"

mkdir -p "$DEST"

rm "$SRC"/*.{txt,nfo,inf,sub,sample} 2>/dev/null || true
rm "$SRC"/*{S,s}ample*.* 2>/dev/null || true

# to allow for some torrents being single file some being folders, try to move files from the folders first, if that fails move the whole folder
mv "$SRC"/*.* "$DEST/" || mv "$SRC" "$DEST/"

# remove the empty directory if it still exists
rmdir "$SRC" 2>/dev/null || true
EOF

# On-added retracker injector
RUN cat > /opt/default-scripts/on-added.sh <<'EOF'
#!/bin/sh

TORRENT_ID="$TR_TORRENT_ID"
IS_PRIVATE="$TR_TORRENT_IS_PRIVATE"
RETRACKER_FILE="/config/retracker.txt"
RETRACKER_URL="https://raw.githubusercontent.com/ngosang/trackerslist/master/trackers_best.txt"

# Skip private torrents
[ "$IS_PRIVATE" = "1" ] && exit 0

# if retracker list is over 2 days old download from RETRACKER_URL
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
EOF

# RSS fetcher
RUN cat > /opt/default-scripts/rss-fetch.sh <<'EOF'
#!/bin/sh

trim() {
  # Trim leading/trailing whitespace
  echo "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

add_from_feed() {
  FEED="$1"
  LABEL="$2"

  [ -z "$FEED" ] && return 0

  if ! XML=$(curl -fs "$FEED"); then
    return 0
  fi

  # Magnets
  echo "$XML" | grep -o 'magnet:[^"<]*' | while read -r MAGNET; do
    [ -z "$MAGNET" ] && continue
    transmission-remote localhost:${WEBUI} \
      --auth "${WEBUSER}:${WEBPASS}" \
      --add "$MAGNET" \
      --torrent-label "$LABEL"
  done

  # Torrent files
  echo "$XML" | grep -o 'http[^"<]*\.torrent' | while read -r TORRENT; do
    [ -z "$TORRENT" ] && continue
    transmission-remote localhost:${WEBUI} \
      --auth "${WEBUSER}:${WEBPASS}" \
      --add "$TORRENT" \
      --torrent-label "$LABEL"
  done
}

# Preferred format:
#   RSSFEEDS="Label:https://example/rss.xml,Other:https://example2/rss.xml"

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
      # Require LABEL:URL
      continue
      ;;
  esac

  [ -z "$LABEL" ] && continue
  [ -z "$FEED" ] && continue

  add_from_feed "$FEED" "$LABEL"
done
IFS="$OLDIFS"
EOF

RUN chmod -R 755 /opt/default-scripts

# -----------------------------
# Transmission startup wrapper
# -----------------------------
RUN cat > /opt/start-transmission.sh <<'EOF'
#!/bin/sh

CONFIG_DIR="/config"
SETTINGS="$CONFIG_DIR/settings.json"

is_mountpoint() {
  # Works without privileges; checks /proc mount table.
  # Returns 0 when PATH is a distinct mount point.
  MP="$1"
  awk -v mp="$MP" '$5==mp {found=1} END{exit !found}' /proc/self/mountinfo
}

require_mount() {
  MP="$1"
  if ! is_mountpoint "$MP"; then
    echo "ERROR: $MP is not mounted. Provide a volume/bind mount for $MP." >&2
    exit 1
  fi
  if [ ! -w "$MP" ]; then
    echo "ERROR: $MP is mounted but not writable by uid=$(id -u) gid=$(id -g)." >&2
    exit 1
  fi
}

require_mount "/config"
require_mount "/downloads"

parse_schedule_minutes() {
  # Supports:
  #   */N * * * *
  #   * * * * *
  case "$SCHEDULE" in
    "* * * * *")
      echo 1
      return 0
      ;;
    "*/"*" * * * *")
      N="${SCHEDULE#*/}"
      N="${N%% *}"
      case "$N" in
        ""|*[!0-9]*) return 1 ;;
        0) return 1 ;;
      esac
      echo "$N"
      return 0
      ;;
  esac
  return 1
}

start_rss_scheduler() {
  [ -z "$RSSFEEDS" ] && return 0
  [ ! -x "/opt/default-scripts/rss-fetch.sh" ] && return 0

  MINUTES=$(parse_schedule_minutes 2>/dev/null) || MINUTES=30

  # Run once at startup, then align to minute boundaries.
  /opt/default-scripts/rss-fetch.sh 2>/dev/null || true

  while true; do
    M=$(date +%M 2>/dev/null || echo 0)
    S=$(date +%S 2>/dev/null || echo 0)
    M=$((10#$M))
    S=$((10#$S))

    MOD=$((M % MINUTES))
    WAIT_MIN=$(((MINUTES - MOD) % MINUTES))
    WAIT_SEC=$((WAIT_MIN * 60 - S))
    if [ "$WAIT_SEC" -le 0 ]; then
      WAIT_SEC=$((WAIT_SEC + MINUTES * 60))
    fi

    sleep "$WAIT_SEC" || true
    /opt/default-scripts/rss-fetch.sh 2>/dev/null || true
  done
}

# Create default settings if missing
if [ ! -f "$SETTINGS" ] && [ -w "$CONFIG_DIR" ]; then
  cat > "$SETTINGS" <<SET
{
  "download-dir": "/downloads",
  "rpc-enabled": true,
  "rpc-port": ${WEBUI},
  "rpc-bind-address": "0.0.0.0",
  "rpc-whitelist-enabled": false,
  "rpc-authentication-required": false,
  "peer-port": ${INCOMING},
  "port-forwarding-enabled": ${UPNP},
  "script-torrent-done-enabled": true,
  "script-torrent-done-filename": "/opt/default-scripts/on-complete.sh",
  "script-torrent-added-enabled": true,
  "script-torrent-added-filename": "/opt/default-scripts/on-added.sh",
  "dht-enabled": true,
  "dht-listen-port": ${INCOMING},
  "lpd-enabled": true,
  "pex-enabled": true,
  "webseeds-enabled": true
}
SET
fi

# Apply runtime overrides
if [ -f "$SETTINGS" ] && [ -w "$CONFIG_DIR" ]; then
  jq --argjson port ${INCOMING} \
     --argjson upnp ${UPNP} \
     --argjson rpcport ${WEBUI} \
     '. ["peer-port"]=$port |
      .["port-forwarding-enabled"]=$upnp |
      .["rpc-port"]=$rpcport' \
     "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
fi

# Password logic
if [ -f "$SETTINGS" ] && [ -w "$CONFIG_DIR" ]; then
  if [ -n "${WEBPASS}" ]; then
    jq --arg user "${WEBUSER}" \
       --arg pass "${WEBPASS}" \
       '. ["rpc-authentication-required"]=true |
        .["rpc-username"]=$user |
        .["rpc-password"]=$pass' \
       "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
  else
    jq '. ["rpc-authentication-required"]=false' \
       "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
  fi
fi

start_rss_scheduler &

exec transmission-daemon -f -g "$CONFIG_DIR"
EOF

RUN chmod 755 /opt/start-transmission.sh

USER 1002:1002

ENTRYPOINT ["/sbin/tini", "--"]
CMD ["/opt/start-transmission.sh"]

EXPOSE 8080 17000/tcp 17000/udp
