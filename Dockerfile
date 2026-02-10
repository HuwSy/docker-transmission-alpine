FROM alpine:edge

ENV TRANSMISSION_PORT=9091 \
    TRANSMISSION_DOWNLOAD_DIR=/downloads \
    TRANSMISSION_INCOMING_PORT=51413 \
    TRANSMISSION_UPNP=false \
    TRANSMISSION_USERNAME=admin \
    RSS_URLS="" \
    RSS_LABELS="" \
    RSS_SCHEDULE="*/30 * * * *"

RUN apk add --no-cache \
      transmission-daemon \
      transmission-cli \
      tini ca-certificates bash curl grep sed jq cronie

RUN mkdir -p /config /downloads /opt/default-scripts && \
    chown -R 1002:1002 /config /downloads /opt/default-scripts

# -----------------------------
# Default scripts (baked in)
# -----------------------------

# Post-download mover
COPY --chown=1002:1002 <<'EOF' /opt/default-scripts/on-complete.sh
#!/bin/sh

LABEL=$(echo "$TR_TORRENT_LABELS" | cut -d',' -f1)
[ -z "$LABEL" ] && exit 0

CAP_LABEL="$(printf "%s" "$LABEL" | sed 's/.*/\u&/')"

SRC="${TR_TORRENT_DIR}/${TR_TORRENT_NAME}"
DEST="/downloads/completed/${CAP_LABEL}"

mkdir -p "$DEST"
mv "$SRC" "$DEST/"
EOF

# On-added retracker injector
COPY --chown=1002:1002 <<'EOF' /opt/default-scripts/on-added.sh
#!/bin/sh

TORRENT_ID="$TR_TORRENT_ID"
IS_PRIVATE="$TR_TORRENT_IS_PRIVATE"

# Skip private torrents
[ "$IS_PRIVATE" = "1" ] && exit 0

RETRACKER_FILE="/config/retracker.txt"
[ ! -f "$RETRACKER_FILE" ] && exit 0

while IFS= read -r TRACKER; do
  [ -z "$TRACKER" ] && continue

  transmission-remote localhost:${TRANSMISSION_PORT} \
    --auth "${TRANSMISSION_USERNAME}:${TRANSMISSION_PASSWORD}" \
    --torrent "$TORRENT_ID" \
    --tracker-add "$TRACKER"

done < "$RETRACKER_FILE"
EOF

# RSS fetcher
COPY --chown=1002:1002 <<'EOF' /opt/default-scripts/rss-fetch.sh
#!/bin/sh

IFS=',' read -r -a FEEDS <<< "$RSS_URLS"
IFS=',' read -r -a LABELS <<< "$RSS_LABELS"

for i in "${!FEEDS[@]}"; do
  FEED="${FEEDS[$i]}"
  LABEL="${LABELS[$i]}"

  [ -z "$FEED" ] && continue

  XML=$(curl -fs "$FEED")

  # Magnets
  echo "$XML" | grep -o 'magnet:[^"<]*' | while read -r MAGNET; do
    transmission-remote localhost:${TRANSMISSION_PORT} \
      --auth "${TRANSMISSION_USERNAME}:${TRANSMISSION_PASSWORD}" \
      --add "$MAGNET" \
      --torrent-label "$LABEL"
  done

  # Torrent files
  echo "$XML" | grep -o 'http[^"<]*\.torrent' | while read -r TORRENT; do
    transmission-remote localhost:${TRANSMISSION_PORT} \
      --auth "${TRANSMISSION_USERNAME}:${TRANSMISSION_PASSWORD}" \
      --add "$TORRENT" \
      --torrent-label "$LABEL"
  done
done
EOF

# Cron installer
COPY --chown=1002:1002 <<'EOF' /opt/default-scripts/cron-install.sh
#!/bin/sh

echo "$RSS_SCHEDULE /config/rss-fetch.sh" > /etc/crontabs/1002
crond -f
EOF

RUN chmod -R 755 /opt/default-scripts

# -----------------------------
# Transmission startup wrapper
# -----------------------------
COPY --chown=1002:1002 <<'EOF' /opt/start-transmission.sh
#!/bin/sh

CONFIG_DIR="/config"
SETTINGS="$CONFIG_DIR/settings.json"

# Copy defaults if missing
for f in on-complete.sh on-added.sh rss-fetch.sh cron-install.sh; do
  [ ! -f "/config/$f" ] && cp "/opt/default-scripts/$f" "/config/$f"
done

chmod 755 /config/*.sh

# Create default settings if missing
if [ ! -f "$SETTINGS" ]; then
  cat > "$SETTINGS" <<SET
{
  "download-dir": "${TRANSMISSION_DOWNLOAD_DIR}",
  "rpc-enabled": true,
  "rpc-port": ${TRANSMISSION_PORT},
  "rpc-bind-address": "0.0.0.0",
  "rpc-whitelist-enabled": false,
  "rpc-authentication-required": false,
  "peer-port": ${TRANSMISSION_INCOMING_PORT},
  "port-forwarding-enabled": ${TRANSMISSION_UPNP},
  "script-torrent-done-enabled": true,
  "script-torrent-done-filename": "/config/on-complete.sh",
  "script-torrent-added-enabled": true,
  "script-torrent-added-filename": "/config/on-added.sh"
}
SET
fi

# Apply runtime overrides
jq --argjson port ${TRANSMISSION_INCOMING_PORT} \
   --argjson upnp ${TRANSMISSION_UPNP} \
   --argjson rpcport ${TRANSMISSION_PORT} \
   '.["peer-port"]=$port |
    .["port-forwarding-enabled"]=$upnp |
    .["rpc-port"]=$rpcport' \
   "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"

# Password logic
if [ -n "${TRANSMISSION_PASSWORD}" ]; then
  jq --arg user "${TRANSMISSION_USERNAME}" \
     --arg pass "${TRANSMISSION_PASSWORD}" \
     '.["rpc-authentication-required"]=true |
      .["rpc-username"]=$user |
      .["rpc-password"]=$pass' \
     "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
else
  jq '.["rpc-authentication-required"]=false' \
     "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
fi

exec transmission-daemon -f -g "$CONFIG_DIR"
EOF

RUN chmod 755 /opt/start-transmission.sh

USER 1002:1002

ENTRYPOINT ["/sbin/tini", "--"]
CMD ["/opt/start-transmission.sh"]

EXPOSE 9091 51413
VOLUME ["/config", "/downloads"]
