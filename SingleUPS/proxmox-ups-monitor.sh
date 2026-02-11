#!/usr/bin/env bash
# ==============================================================================
# Proxmox UPS Toolkit - UPS status logger (NUT)
# Logs to: /var/log/proxmox-ups-toolkit/status-YYYY-MM-DD.log
# Retention: 7 days
# Interval: systemd timer (default 15s)
# ==============================================================================
set -u

CONFIG_FILE="${CONFIG_FILE:-/etc/proxmox-ups-shutdown.conf}"
LOG_DIR="${LOG_DIR:-/var/log/proxmox-ups-toolkit}"
LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-7}"
BOOST_LOW_BATT_THRESHOLD="${BOOST_LOW_BATT_THRESHOLD:-20}"

mkdir -p "$LOG_DIR" 2>/dev/null || true

if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
fi

UPS_IDENTIFIER="${UPS_IDENTIFIER:-myups@localhost}"
LOG_TAG="${LOG_TAG:-PVE-UPS-STATUS}"

have_cmd() { command -v "$1" >/dev/null 2>&1; }

upsc_get() {
  local key="$1"
  if have_cmd upsc; then
    upsc "$UPS_IDENTIFIER" "$key" 2>/dev/null || true
  else
    echo ""
  fi
}

ts="$(date -Is)"
status="$(upsc_get ups.status)"
charge="$(upsc_get battery.charge)"
runtime="$(upsc_get battery.runtime)"

[[ -z "$status" ]] && status="UNKNOWN"
[[ -z "$charge" ]] && charge="0"
[[ -z "$runtime" ]] && runtime="0"

shutdown="NO"
reason="online"

if [[ "$status" == "UNKNOWN" ]]; then
  shutdown="UNKNOWN"
  reason="upsc_failed"
elif [[ "$status" =~ OL ]]; then
  if [[ "$status" =~ BOOST ]] && [[ "$charge" =~ ^[0-9]+$ ]] && (( charge <= BOOST_LOW_BATT_THRESHOLD )); then
    shutdown="YES"
    reason="boost_low_battery"
  else
    shutdown="NO"
    reason="online"
  fi
else
  shutdown="YES"
  reason="on_battery"
fi

logfile="$LOG_DIR/status-$(date +%F).log"
line="$ts ups=$UPS_IDENTIFIER status=$status charge=${charge}% runtime=${runtime}s shutdown=$shutdown reason=$reason"
echo "$line" >> "$logfile"
logger -t "$LOG_TAG" -- "$line" 2>/dev/null || true

find "$LOG_DIR" -maxdepth 1 -type f -name "*.log" -mtime +"$LOG_RETENTION_DAYS" -delete 2>/dev/null || true
