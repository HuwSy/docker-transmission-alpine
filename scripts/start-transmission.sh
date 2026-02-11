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
  SCHEDULE="${SCHEDULE:-}"

  # Trim whitespace
  S="$(echo "$SCHEDULE" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  [ -z "$S" ] && return 1

  # Split into minute and hour fields (hour may be empty)
  MIN_FIELD="${S%% *}"
  REST="${S#* }"
  [ "$REST" = "$S" ] && HOUR_FIELD=""; HOUR_FIELD="${REST%% *}"

  # Helper: numeric check
  is_num() {
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
    return 0
  }

  # Case: plain "*"
  if [ "$MIN_FIELD" = "*" ]; then
    echo "freq:1"   # every 1 minute
    return 0
  fi

  # Case: */N
  case "$MIN_FIELD" in
    '*/'* )
      N="${MIN_FIELD#*/}"
      is_num "$N" || return 1
      [ "$N" -eq 0 ] 2>/dev/null && return 1
      echo "freq:$N"
      return 0
      ;;
  esac

  # Case: A/B (start/interval)
  case "$MIN_FIELD" in
    */* )
      START="${MIN_FIELD%%/*}"
      STEP="${MIN_FIELD#*/}"
      is_num "$START" || return 1
      is_num "$STEP" || return 1
      [ "$STEP" -eq 0 ] 2>/dev/null && return 1
      # Ensure START in 0..59
      if [ "$START" -lt 0 ] || [ "$START" -gt 59 ]; then return 1; fi
      echo "start:$START/step:$STEP"
      return 0
      ;;
  esac

  # Case: single numeric minute (run once per hour at that minute)
  if is_num "$MIN_FIELD"; then
    [ "$MIN_FIELD" -ge 0 ] 2>/dev/null || return 1
    [ "$MIN_FIELD" -le 59 ] 2>/dev/null || return 1
    echo "at:$MIN_FIELD"
    return 0
  fi

  return 1
}

start_rss_scheduler() {
  [ -z "$RSSFEEDS" ] && return 0
  [ ! -x "/opt/default-scripts/rss-fetch.sh" ] && return 0

  PARSED=$(parse_schedule_minutes 2>/dev/null) || PARSED=""
  # default: run every 30 minutes
  if [ -z "$PARSED" ]; then
    MODE="freq"
    VAL=30
  else
    MODE="${PARSED%%:*}"
    VAL="${PARSED#*:}"
    # For start:step form adjust parsing
    if [ "$MODE" = "start" ]; then
      # PARSED like start:10/step:30
      START=$(echo "$PARSED" | sed -n 's/^start:\([0-9][0-9]*\)\/step:\([0-9][0-9]*\)$/\1/p')
      STEP=$(echo "$PARSED" | sed -n 's/^start:\([0-9][0-9]*\)\/step:\([0-9][0-9]*\)$/\2/p')
      [ -z "$START" ] || [ -z "$STEP" ] || { MODE="freq"; VAL=30; }
    fi
  fi

  /opt/default-scripts/rss-fetch.sh 2>/dev/null || true

  while true; do
    M=$(date +%M 2>/dev/null || echo 0); M=$((10#$M))
    H=$(date +%H 2>/dev/null || echo 0); H=$((10#$H))
    S=$(date +%S 2>/dev/null || echo 0); S=$((10#$S))

    # If mode is a single fixed minute ("at")
    if [ "${MODE}" = "at" ]; then
      TARGET_MIN=$VAL
      if [ "$M" -eq "$TARGET_MIN" ]; then
        # run immediately if at the exact minute (allow some seconds margin)
        if [ "$S" -lt 59 ]; then
          /opt/default-scripts/rss-fetch.sh 2>/dev/null || true
        fi
        # sleep until next hour + TARGET_MIN
        NEXT_WAIT_MIN=$(( (60 - M + TARGET_MIN) % 60 ))
        WAIT_SEC=$(( NEXT_WAIT_MIN * 60 - S ))
        [ "$WAIT_SEC" -le 0 ] && WAIT_SEC=$(( WAIT_SEC + 3600 ))
        sleep "$WAIT_SEC" || true
        continue
      fi
      # compute seconds until next TARGET_MIN this hour or next hour
      if [ "$M" -lt "$TARGET_MIN" ]; then
        DELAY_MIN=$(( TARGET_MIN - M ))
      else
        DELAY_MIN=$(( 60 - M + TARGET_MIN ))
      fi
      WAIT_SEC=$(( DELAY_MIN * 60 - S ))
      sleep "$WAIT_SEC" || true
      /opt/default-scripts/rss-fetch.sh 2>/dev/null || true
      continue
    fi

    # If mode is start:step
    if [ "${MODE}" = "start" ]; then
      # compute next minute in sequence START, START+STEP, ... modulo hour
      # find current offset from START
      if [ "$M" -lt "$START" ]; then
        NEXT_MIN=$START
      else
        DIFF=$(( M - START ))
        REM=$(( DIFF % STEP ))
        if [ "$REM" -eq 0 ]; then
          # at an exact slot; run now
          if [ "$S" -lt 59 ]; then
            /opt/default-scripts/rss-fetch.sh 2>/dev/null || true
          fi
          NEXT_MIN=$(( (M + STEP) % 60 ))
        else
          NEXT_MIN=$(( (M + (STEP - REM)) % 60 ))
        fi
      fi
      # compute wait seconds until NEXT_MIN
      if [ "$NEXT_MIN" -ge "$M" ]; then
        DELAY_MIN=$(( NEXT_MIN - M ))
      else
        DELAY_MIN=$(( 60 - M + NEXT_MIN ))
      fi
      WAIT_SEC=$(( DELAY_MIN * 60 - S ))
      [ "$WAIT_SEC" -le 0 ] && WAIT_SEC=$(( WAIT_SEC + 3600 ))
      sleep "$WAIT_SEC" || true
      /opt/default-scripts/rss-fetch.sh 2>/dev/null || true
      continue
    fi

    # Default: freq:N (every N minutes)
    if [ "${MODE}" = "freq" ]; then
      N=$VAL
      MOD=$((M % N))
      WAIT_MIN=$(((N - MOD) % N))
      WAIT_SEC=$((WAIT_MIN * 60 - S))
      if [ "$WAIT_SEC" -le 0 ]; then
        WAIT_SEC=$((WAIT_SEC + N * 60))
      fi
      sleep "$WAIT_SEC" || true
      /opt/default-scripts/rss-fetch.sh 2>/dev/null || true
      continue
    fi

    # fallback sleep
    sleep 60 || true
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
