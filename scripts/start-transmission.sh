#!/bin/sh

CONFIG_DIR="/config"
SETTINGS="$CONFIG_DIR/settings.json"

is_mountpoint() {
  MP="$1"
  awk -v mp="$MP" '$5==mp {found=1} END{exit !found}' /proc/self/mountinfo
}

require_mount() {
  MP="$1"
  if ! is_mountpoint "$MP"; then
    echo "ERROR: $MP is not mounted." >&2
    exit 1
  fi
  if [ ! -w "$MP" ]; then
    echo "ERROR: $MP is mounted but not writable." >&2
    exit 1
  fi
}

require_mount "/config"
require_mount "/downloads"

parse_schedule_minutes() {
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
  "utp-enabled": true,
  "dht-listen-port": ${INCOMING},
  "lpd-enabled": true,
  "pex-enabled": true,
  "webseeds-enabled": true
}
SET
fi

if [ -f "$SETTINGS" ] && [ -w "$CONFIG_DIR" ]; then
  jq --argjson port ${INCOMING} \
     --argjson upnp ${UPNP} \
     --argjson rpcport ${WEBUI} \
     '. ["peer-port"]=$port |
      .["port-forwarding-enabled"]=$upnp |
      .["rpc-port"]=$rpcport' \
     "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
fi

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
