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

require_mount "/downloads"

parse_schedule_minutes() {
  SCHEDULE="${SCHEDULE:-}"

  # Trim whitespace
  S="$(echo "$SCHEDULE" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  [ -z "$S" ] && return 1

  # Split into minute and hour fields (hour may be empty)
  MIN_FIELD="${S%% *}"
  REST="${S#* }"
  [ "$REST" = "$S" ] && HOUR_FIELD=""
  HOUR_FIELD="${REST%% *}"

  # Helper: numeric check
  is_num() {
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
    return 0
  }

  # Helper: parse one field (minute or hour)
  # args: field, max_value (59 or 23)
  # output: type:value  where type is one of at,freq,start and value is either N or "A/STEP"
  parse_field() {
    FIELD="$1"; MAX="$2"
    if [ -z "$FIELD" ]; then
      echo "freq:1" && return 0
    fi

    if [ "$FIELD" = "*" ]; then
      echo "freq:1" && return 0
    fi

    case "$FIELD" in
      '*/'* )
        N="${FIELD#*/}"
        is_num "$N" || return 1
        [ "$N" -eq 0 ] 2>/dev/null && return 1
        echo "freq:$N" && return 0
        ;;
    esac

    case "$FIELD" in
      */* )
        A="${FIELD%%/*}"
        B="${FIELD#*/}"
        is_num "$A" || return 1
        is_num "$B" || return 1
        [ "$B" -eq 0 ] 2>/dev/null && return 1
        # validate ranges
        [ "$A" -ge 0 ] 2>/dev/null || return 1
        [ "$A" -le "$MAX" ] 2>/dev/null || return 1
        echo "start:$A/$B" && return 0
        ;;
    esac

    if is_num "$FIELD"; then
      [ "$FIELD" -ge 0 ] 2>/dev/null || return 1
      [ "$FIELD" -le "$MAX" ] 2>/dev/null || return 1
      echo "at:$FIELD" && return 0
    fi

    return 1
  }

  MIN_PARSED=$(parse_field "$MIN_FIELD" 59) || return 1
  HOUR_PARSED=$(parse_field "$HOUR_FIELD" 23) || return 1

  echo "min:${MIN_PARSED} hour:${HOUR_PARSED}"
  return 0
}

start_rss_scheduler() {
  [ -z "$RSSFEEDS" ] && return 0
  [ ! -x "/opt/default-scripts/rss-fetch.sh" ] && return 0

  PARSED=$(parse_schedule_minutes 2>/dev/null) || PARSED=""
  
  # default: run every 30 minutes
  if [ -z "$PARSED" ]; then
    MIN_MODE="freq"; MIN_VAL=30
    HOUR_MODE="freq"; HOUR_VAL=1
  else
    MIN_PART=$(echo "$PARSED" | sed -n 's/^min:\([^ ]*\) .*$/\1/p')
    HOUR_PART=$(echo "$PARSED" | sed -n 's/^.* hour:\(.*\)$/\1/p')

    MIN_MODE="${MIN_PART%%:*}"
    MIN_VAL="${MIN_PART#*:}"
    HOUR_MODE="${HOUR_PART%%:*}"
    HOUR_VAL="${HOUR_PART#*:}"
  fi
  
  matches_min() {
    local CM="$1"
    case "$MIN_MODE" in
      freq)
        local N="$MIN_VAL"
        [ $((CM % N)) -eq 0 ]
        ;;
      start)
        local A="${MIN_VAL%%/*}"
        local STEP="${MIN_VAL#*/}"
        [ "$CM" -lt "$A" ] && return 1
        local DIFF=$((CM - A))
        [ $((DIFF % STEP)) -eq 0 ]
        ;;
      at)
        [ "$CM" -eq "$MIN_VAL" ]
        ;;
      *)
        return 1
        ;;
    esac
  }

  matches_hour() {
    local CH="$1"
    local WRAPPED="$2"

    case "$HOUR_MODE" in
      freq)
        local N="$HOUR_VAL"
        [ $((CH % N)) -eq 0 ]
        ;;
      start)
        local A="${HOUR_VAL%%/*}"
        local STEP="${HOUR_VAL#*/}"

        # cron-like: do NOT match after midnight rollover
        [ "$WRAPPED" -eq 1 ] && return 1

        [ "$CH" -lt "$A" ] && return 1
        local DIFF=$((CH - A))
        [ $((DIFF % STEP)) -eq 0 ]
        ;;
      at)
        [ "$CH" -eq "$HOUR_VAL" ]
        ;;
      *)
        return 1
        ;;
    esac
  }

  while true; do
    M=$(date +%M); M=$((10#$M))
    H=$(date +%H); H=$((10#$H))
    S=$(date +%S); S=$((10#$S))

    FOUND=0

    for delta in $(seq 0 1439); do
      total_minutes=$((H * 60 + M + delta))
      CH=$(( total_minutes / 60 ))
      CM=$(( total_minutes % 60 ))

      WRAPPED=0
      if [ "$CH" -ge 24 ]; then
        CH=$((CH - 24))
        WRAPPED=1
      fi

      matches_min "$CM" || continue
      matches_hour "$CH" "$WRAPPED" || continue

      FOUND=1
      NEXT_DELTA="$delta"
      break
    done

    if [ "$FOUND" -ne 1 ]; then
      sleep 60
      continue
    fi

    WAIT_SEC=$(( NEXT_DELTA * 60 - S ))
    if [ "$WAIT_SEC" -lt 0 ]; then
      WAIT_SEC=0
    fi

    sleep "$WAIT_SEC"
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
  "dht-listen-port": ${INCOMING},
  "lpd-enabled": true,
  "pex-enabled": true,
  "preallocation": 0,
  "rename_partial_files": false,
  "encryption": "preferred"
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
