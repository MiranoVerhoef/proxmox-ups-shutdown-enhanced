#!/usr/bin/env bash
# ==============================================================================
# Proxmox UPS Shutdown Orchestrator (NUT) - layered VM/CT shutdown
# Version: 1.0.2
# ==============================================================================
CONFIG_FILE="${CONFIG_FILE:-/etc/proxmox-ups-shutdown.conf}"

DRY_RUN_HOST_ONLY=false      # run guest actions but skip host shutdown
TEST_MODE=false              # do nothing destructive (guests + host)
SIMULATE_FAILURE=false       # skip UPS status check; proceed
NO_WAIT=false                # skip initial wait
PRINT_PLAN=false             # print plan and exit

POWER_FAILURE_WAIT_TIME=300
ACTION_DELAY=1
SHUTDOWN_TIMEOUT=20
SYNC_AFTER_ACTION=true

UPS_IDENTIFIER="myups@localhost"
DEFAULT_VM_ACTION="shutdown"   # shutdown|hibernate|stop
DEFAULT_CT_ACTION="shutdown"   # shutdown|stop
DEFAULT_VM_PRIORITY=50
DEFAULT_CT_PRIORITY=50
PROCEED_ON_UNKNOWN=false

LOG_TAG="PVE-UPS"

LOG_DIR="${LOG_DIR:-/var/log/proxmox-ups-toolkit}"
LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-7}"
ACTION_LOG="${LOG_DIR}/actions-$(date +%F).log"
STATUS_LOG="${LOG_DIR}/status-$(date +%F).log"
BOOST_LOW_BATT_THRESHOLD="${BOOST_LOW_BATT_THRESHOLD:-20}"

declare -A VM_ACTIONS VM_PRIORITY CT_ACTIONS CT_PRIORITY

if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
fi

usage() {
  cat <<'EOF'
Usage: proxmox-shutdown.sh [options]

Options:
  --plan                 Print ordered plan and exit.
  --test                 Test mode (no shutdowns at all).
  --dry-run-host          Shutdown guests but skip host shutdown.
  --simulate             Ignore UPS status and proceed.
  --no-wait              Skip POWER_FAILURE_WAIT_TIME sleep.
  --event <name>         Event name (for logs only).
  -h, --help             Help.

Priority:
  Lower number = shutdown earlier (less important).
EOF
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

init_logs() {
  mkdir -p "$LOG_DIR" 2>/dev/null || true
  # cheap retention cleanup
  find "$LOG_DIR" -maxdepth 1 -type f -name "*.log" -mtime +"$LOG_RETENTION_DAYS" -delete 2>/dev/null || true
}

log_message() {
  local msg="$*"
  local ts; ts="$(date -Is)"
  init_logs
  echo "$ts $msg" >> "$ACTION_LOG" 2>/dev/null || true
  echo "${LOG_TAG}: $msg" | tee >(logger -t "${LOG_TAG}")
}

log_status_line() {
  local line="$*"
  local ts; ts="$(date -Is)"
  init_logs
  echo "$ts $line" >> "$STATUS_LOG" 2>/dev/null || true
  logger -t "${LOG_TAG}-STATUS" -- "$ts $line" 2>/dev/null || true
}

acquire_lock() {
  local lockfile="/run/proxmox-ups-shutdown.lock"
  if have_cmd flock; then
    exec 200>"$lockfile" || true
    if ! flock -n 200; then
      log_message "Another shutdown run is already in progress. Exiting."
      exit 0
    fi
  else
    local lockdir="${lockfile}.d"
    if ! mkdir "$lockdir" 2>/dev/null; then
      log_message "Another shutdown run is already in progress. Exiting."
      exit 0
    fi
    trap 'rmdir "$lockdir" 2>/dev/null || true' EXIT
  fi
}

upsc_get() { local key="$1"; upsc "$UPS_IDENTIFIER" "$key" 2>/dev/null || true; }

get_vm_name() {
  local id="$1" name=""
  name="$(qm list 2>/dev/null | awk -v id="$id" 'NR>1 && $1==id {print $2; exit}')"
  [[ -z "$name" ]] && name="$(qm config "$id" 2>/dev/null | awk -F': ' '$1=="name"{print $2; exit}')"
  echo "${name:-vm-$id}"
}
get_ct_name() {
  local id="$1" name=""
  name="$(pct list 2>/dev/null | awk -v id="$id" 'NR>1 && $1==id {print $NF; exit}')"
  [[ -z "$name" ]] && name="$(pct config "$id" 2>/dev/null | awk -F': ' '$1=="hostname"{print $2; exit}')"
  echo "${name:-ct-$id}"
}

build_plan() {
  local id prio action name
  if have_cmd pct; then
    while read -r id; do
      [[ -z "$id" ]] && continue
      prio="${CT_PRIORITY[$id]:-$DEFAULT_CT_PRIORITY}"
      action="${CT_ACTIONS[$id]:-$DEFAULT_CT_ACTION}"
      name="$(get_ct_name "$id")"
      printf "%s\tct\t%s\t%s\t%s\n" "$prio" "$id" "$name" "$action"
    done < <(pct list 2>/dev/null | awk 'NR>1 && $2=="running"{print $1}')
  fi
  if have_cmd qm; then
    while read -r id; do
      [[ -z "$id" ]] && continue
      prio="${VM_PRIORITY[$id]:-$DEFAULT_VM_PRIORITY}"
      action="${VM_ACTIONS[$id]:-$DEFAULT_VM_ACTION}"
      name="$(get_vm_name "$id")"
      printf "%s\tvm\t%s\t%s\t%s\n" "$prio" "$id" "$name" "$action"
    done < <(qm list 2>/dev/null | awk 'NR>1 && $3=="running"{print $1}')
  fi
}

print_plan() {
  local plan
  plan="$(build_plan | sort -n -k1,1 -k2,2 -k3,3)"
  if [[ -z "$plan" ]]; then
    echo "No running guests found."
    return 0
  fi
  echo "Priority  Type  ID    Action     Name"
  echo "--------  ----  ----  ---------  ----------------"
  echo "$plan" | awk -F'\t' '{printf "%-8s  %-4s  %-4s  %-9s  %s\n",$1,$2,$3,$5,$4}'
}

do_action() {
  local type="$1" id="$2" action="$3"

  if [[ "$TEST_MODE" == true ]]; then
    log_message "[TEST] Would run: $type $id -> $action"
    return 0
  fi

  case "$type:$action" in
    ct:shutdown) log_message "Shutting down CT $id"; pct shutdown "$id" || true ;;
    ct:stop)     log_message "Stopping CT $id"; pct stop "$id" --skiplock 1 || true ;;
    vm:hibernate)log_message "Hibernating VM $id"; qm suspend "$id" --todisk 1 || true ;;
    vm:shutdown) log_message "Shutting down VM $id"; qm shutdown "$id" --skiplock 1 || true ;;
    vm:stop)     log_message "Stopping VM $id"; qm stop "$id" --skiplock 1 || true ;;
    *)
      log_message "Unknown action '$action' for $type $id; falling back to shutdown."
      [[ "$type" == "ct" ]] && pct shutdown "$id" || qm shutdown "$id" --skiplock 1 || true
      ;;
  esac

  [[ "$SYNC_AFTER_ACTION" == true ]] && sync
  sleep "$ACTION_DELAY"
}

force_stop_remaining() {
  local id
  if have_cmd pct; then
    while read -r id; do
      [[ -z "$id" ]] && continue
      log_message "CT $id still running. Forcing stop."
      [[ "$TEST_MODE" == true ]] && log_message "[TEST] Would run: pct stop $id --skiplock 1" || pct stop "$id" --skiplock 1 || true
      [[ "$SYNC_AFTER_ACTION" == true ]] && sync
    done < <(pct list 2>/dev/null | awk 'NR>1 && $2=="running"{print $1}')
  fi
  if have_cmd qm; then
    while read -r id; do
      [[ -z "$id" ]] && continue
      log_message "VM $id still running. Forcing stop."
      [[ "$TEST_MODE" == true ]] && log_message "[TEST] Would run: qm stop $id --skiplock 1" || qm stop "$id" --skiplock 1 || true
      [[ "$SYNC_AFTER_ACTION" == true ]] && sync
    done < <(qm list 2>/dev/null | awk 'NR>1 && $3=="running"{print $1}')
  fi
}

EVENT="${EVENT:-${NOTIFYTYPE:-}}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --plan) PRINT_PLAN=true ;;
    --test) TEST_MODE=true ;;
    --dry-run-host) DRY_RUN_HOST_ONLY=true ;;
    --simulate) SIMULATE_FAILURE=true ;;
    --no-wait) NO_WAIT=true ;;
    --event) EVENT="${2:-}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1"; usage; exit 2 ;;
  esac
  shift
done

# Backward compat
if [[ "${DRY_RUN:-false}" == true ]]; then DRY_RUN_HOST_ONLY=true; fi

# In test mode: fast/non-blocking
if [[ "$TEST_MODE" == true ]]; then
  POWER_FAILURE_WAIT_TIME=0
  SHUTDOWN_TIMEOUT=0
  ACTION_DELAY=0
  SYNC_AFTER_ACTION=false
fi

if [[ "$PRINT_PLAN" == true ]]; then
  print_plan
  exit 0
fi

if ! have_cmd qm && ! have_cmd pct; then
  log_message "Neither 'qm' nor 'pct' found. Are you running this on a Proxmox host?"
  exit 1
fi

acquire_lock
init_logs

if [[ "$NO_WAIT" != true && "$POWER_FAILURE_WAIT_TIME" -gt 0 ]]; then
  log_message "Event=${EVENT:-unknown}. Waiting ${POWER_FAILURE_WAIT_TIME}s for power restoration..."
  sleep "$POWER_FAILURE_WAIT_TIME"
fi

UPS_STATUS="UNKNOWN"
BATTERY_LEVEL="0"
BATTERY_RUNTIME="0"

if [[ "$SIMULATE_FAILURE" == true ]]; then
  log_message "Simulating power failure. Proceeding with shutdown sequence."
else
  local_status="$(upsc_get ups.status)"
  local_batt="$(upsc_get battery.charge)"
  local_runtime="$(upsc_get battery.runtime)"
  [[ -n "$local_status" ]] && UPS_STATUS="$local_status"
  [[ -n "$local_batt" ]] && BATTERY_LEVEL="$local_batt"
  [[ -n "$local_runtime" ]] && BATTERY_RUNTIME="$local_runtime"

  log_status_line "ups=${UPS_IDENTIFIER} status=${UPS_STATUS} charge=${BATTERY_LEVEL}% runtime=${BATTERY_RUNTIME}s"

  if [[ "$UPS_STATUS" =~ OL ]]; then
    if [[ "$UPS_STATUS" =~ BOOST && "$BATTERY_LEVEL" -le "$BOOST_LOW_BATT_THRESHOLD" ]]; then
      log_message "UPS is online but BOOST and battery low (${BATTERY_LEVEL}%). Proceeding with shutdown."
    else
      log_message "Power restored / UPS online (status=${UPS_STATUS}, battery=${BATTERY_LEVEL}%). Exiting."
      exit 0
    fi
  fi

  if [[ "$UPS_STATUS" == "UNKNOWN" && "$PROCEED_ON_UNKNOWN" != true ]]; then
    log_message "Could not read UPS status via upsc (${UPS_IDENTIFIER}). Refusing to proceed (set PROCEED_ON_UNKNOWN=true to override)."
    exit 1
  fi
  log_message "UPS status=${UPS_STATUS}, battery=${BATTERY_LEVEL}%. Power not restored. Starting layered shutdown."
fi

PLAN="$(build_plan | sort -n -k1,1 -k2,2 -k3,3)"

if [[ -z "$PLAN" ]]; then
  log_message "No running guests found."
else
  log_message "Shutdown plan (least important first):"
  echo "$PLAN" | awk -F'\t' '{printf "  prio=%s  %s %s  action=%s  name=%s\n",$1,$2,$3,$5,$4}' | while read -r line; do log_message "$line"; done

  while IFS=$'\t' read -r prio type id name action; do
    do_action "$type" "$id" "$action"
  done <<< "$PLAN"
fi

if [[ "$SHUTDOWN_TIMEOUT" -gt 0 ]]; then
  log_message "Waiting ${SHUTDOWN_TIMEOUT}s for guests to stop gracefully..."
  sleep "$SHUTDOWN_TIMEOUT"
fi

force_stop_remaining
log_message "Guest shutdown complete."

if [[ "$TEST_MODE" == true ]]; then
  log_message "[TEST] Host shutdown skipped."
  exit 0
fi

if [[ "$DRY_RUN_HOST_ONLY" == true ]]; then
  log_message "Dry-run-host enabled. Host shutdown skipped."
  exit 0
fi

log_message "Shutting down host now."
sync
shutdown -h now "UPS power failure detected. System shutting down."
