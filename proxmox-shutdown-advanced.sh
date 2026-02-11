#!/usr/bin/env bash
# ==============================================================================
# Proxmox UPS Shutdown Orchestrator (NUT)
# ==============================================================================
# Purpose:
#   - Layered shutdown of Proxmox VMs/CTs (least important first) on UPS events.
#   - Optional hibernate (suspend to disk) for selected VMs.
#   - Designed to be called by NUT (upsmon/upssched) on power events.
#
# Based on jordanmack/proxmox-ups-shutdown proxmox-shutdown.sh (MIT).
# Added: priorities, test mode, arg parsing, locking, upssched-friendly hooks.
#
# Version: 1.0.0
# ==============================================================================

# ------------------------------
# Defaults (can be overridden by config)
# ------------------------------
CONFIG_FILE="${CONFIG_FILE:-/etc/proxmox-ups-shutdown.conf}"

# Mode flags
DRY_RUN_HOST_ONLY=false      # Keep original behavior: do guest actions but skip host shutdown.
TEST_MODE=false              # New: do nothing destructive (guests + host).
SIMULATE_FAILURE=false       # Skip UPS status check; proceed.
NO_WAIT=false                # Skip initial wait (useful when called by upssched timer).
PRINT_PLAN=false             # Print ordered plan and exit.

# Timing
POWER_FAILURE_WAIT_TIME=300  # Seconds to wait for power restoration (when NOT using upssched timer).
ACTION_DELAY=1               # Seconds between guest actions.
SHUTDOWN_TIMEOUT=20          # Seconds to wait before forcing remaining guests off.
SYNC_AFTER_ACTION=true       # Call sync after each guest action.

# UPS query
UPS_IDENTIFIER="myups@localhost"   # For upsc queries: "<upsname>@<host>"

# Defaults for priorities/actions
DEFAULT_VM_ACTION="shutdown"       # shutdown|hibernate|stop
DEFAULT_CT_ACTION="shutdown"       # shutdown|stop
DEFAULT_VM_PRIORITY=50             # Lower = less important => shut down earlier
DEFAULT_CT_PRIORITY=50

# Optional: proceed with shutdown if upsc fails (UNKNOWN status).
PROCEED_ON_UNKNOWN=false

# Logging
LOG_TAG="PVE-UPS"

# Per-guest overrides (populated in config)
declare -A VM_ACTIONS
declare -A VM_PRIORITY
declare -A CT_ACTIONS
declare -A CT_PRIORITY

# ------------------------------
# Load config (if present)
# ------------------------------
if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
fi

# ------------------------------
# Helpers
# ------------------------------
usage() {
  cat <<'EOF'
Usage: proxmox-shutdown.sh [options]

Options:
  --plan                 Print the ordered shutdown plan and exit.
  --test                 Test mode (no changes; prints what would happen).
  --dry-run-host          Run guest actions but skip host shutdown.
  --simulate             Ignore UPS status and proceed.
  --no-wait              Skip the initial POWER_FAILURE_WAIT_TIME sleep.
  --event <name>         Event name (optional). For logs only.
  -h, --help             Show this help.

Notes:
  * Priorities: lower number = shut down earlier (least important first).
  * Intended to be called by NUT (upsmon/upssched). It is safe to call manually.

EOF
}

log_message() {
  # Log to stdout and syslog.
  echo "${LOG_TAG}: $*" | tee >(logger -t "${LOG_TAG}")
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

# Simple lock to prevent multiple concurrent runs.
acquire_lock() {
  local lockfile="/run/proxmox-ups-shutdown.lock"
  if have_cmd flock; then
    exec 200>"$lockfile" || true
    if ! flock -n 200; then
      log_message "Another shutdown run is already in progress. Exiting."
      exit 0
    fi
  else
    # Fallback: mkdir lock
    local lockdir="${lockfile}.d"
    if ! mkdir "$lockdir" 2>/dev/null; then
      log_message "Another shutdown run is already in progress. Exiting."
      exit 0
    fi
    trap 'rmdir "$lockdir" 2>/dev/null || true' EXIT
  fi
}

# Safe upsc wrapper
upsc_get() {
  local key="$1"
  upsc "$UPS_IDENTIFIER" "$key" 2>/dev/null || true
}

# Fetch names (best effort)
get_vm_name() {
  local id="$1"
  local name
  name="$(qm list 2>/dev/null | awk -v id="$id" 'NR>1 && $1==id {print $2; exit}')"
  if [[ -z "$name" ]] && have_cmd qm; then
    name="$(qm config "$id" 2>/dev/null | awk -F': ' '$1=="name"{print $2; exit}')"
  fi
  echo "${name:-vm-$id}"
}
get_ct_name() {
  local id="$1"
  local name
  name="$(pct list 2>/dev/null | awk -v id="$id" 'NR>1 && $1==id {print $NF; exit}')"
  if [[ -z "$name" ]] && have_cmd pct; then
    name="$(pct config "$id" 2>/dev/null | awk -F': ' '$1=="hostname"{print $2; exit}')"
  fi
  echo "${name:-ct-$id}"
}

# Build shutdown plan: prints tab-separated lines:
#   priority  type  id  name  action
build_plan() {
  local id prio action name

  # CTs (running)
  if have_cmd pct; then
    while read -r id; do
      [[ -z "$id" ]] && continue
      prio="${CT_PRIORITY[$id]:-$DEFAULT_CT_PRIORITY}"
      action="${CT_ACTIONS[$id]:-$DEFAULT_CT_ACTION}"
      name="$(get_ct_name "$id")"
      printf "%s\tct\t%s\t%s\t%s\n" "$prio" "$id" "$name" "$action"
    done < <(pct list 2>/dev/null | awk 'NR>1 && $2=="running"{print $1}' | xargs -r -n1 echo)
  fi

  # VMs (running)
  if have_cmd qm; then
    while read -r id; do
      [[ -z "$id" ]] && continue
      prio="${VM_PRIORITY[$id]:-$DEFAULT_VM_PRIORITY}"
      action="${VM_ACTIONS[$id]:-$DEFAULT_VM_ACTION}"
      name="$(get_vm_name "$id")"
      printf "%s\tvm\t%s\t%s\t%s\n" "$prio" "$id" "$name" "$action"
    done < <(qm list 2>/dev/null | awk 'NR>1 && $3=="running"{print $1}' | xargs -r -n1 echo)
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

# Execute actions (respects TEST_MODE)
do_action() {
  local type="$1" id="$2" action="$3"

  if [[ "$TEST_MODE" == true ]]; then
    log_message "[TEST] Would run: $type $id -> $action"
    return 0
  fi

  case "$type:$action" in
    ct:shutdown)
      log_message "Shutting down CT $id"
      pct shutdown "$id" || true
      ;;
    ct:stop)
      log_message "Stopping CT $id"
      pct stop "$id" --skiplock 1 || true
      ;;
    vm:hibernate)
      log_message "Hibernating VM $id (suspend to disk)"
      qm suspend "$id" --todisk 1 || true
      ;;
    vm:shutdown)
      log_message "Shutting down VM $id"
      qm shutdown "$id" --skiplock 1 || true
      ;;
    vm:stop)
      log_message "Stopping VM $id"
      qm stop "$id" --skiplock 1 || true
      ;;
    *)
      log_message "Unknown action '$action' for $type $id. Falling back to shutdown."
      if [[ "$type" == "ct" ]]; then
        pct shutdown "$id" || true
      else
        qm shutdown "$id" --skiplock 1 || true
      fi
      ;;
  esac

  if [[ "$SYNC_AFTER_ACTION" == true ]]; then
    sync
  fi
  sleep "$ACTION_DELAY"
}

force_stop_remaining() {
  local id

  if have_cmd pct; then
    while read -r id; do
      [[ -z "$id" ]] && continue
      log_message "CT $id still running. Forcing stop."
      if [[ "$TEST_MODE" == true ]]; then
        log_message "[TEST] Would run: pct stop $id --skiplock 1"
      else
        pct stop "$id" --skiplock 1 || true
      fi
      [[ "$SYNC_AFTER_ACTION" == true ]] && sync
      sleep "$ACTION_DELAY"
    done < <(pct list 2>/dev/null | awk 'NR>1 && $2=="running"{print $1}' | xargs -r -n1 echo)
  fi

  if have_cmd qm; then
    while read -r id; do
      [[ -z "$id" ]] && continue
      log_message "VM $id still running. Forcing stop."
      if [[ "$TEST_MODE" == true ]]; then
        log_message "[TEST] Would run: qm stop $id --skiplock 1"
      else
        qm stop "$id" --skiplock 1 || true
      fi
      [[ "$SYNC_AFTER_ACTION" == true ]] && sync
      sleep "$ACTION_DELAY"
    done < <(qm list 2>/dev/null | awk 'NR>1 && $3=="running"{print $1}' | xargs -r -n1 echo)
  fi
}

# ------------------------------
# Arg parsing
# ------------------------------
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

# Backward-compat: if config sets DRY_RUN=true (old meaning), map to dry-run-host.
if [[ "${DRY_RUN:-false}" == true ]]; then
  DRY_RUN_HOST_ONLY=true
fi

# In test mode, make execution fast and non-blocking.
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

# ------------------------------
# Sanity checks
# ------------------------------
if ! have_cmd qm && ! have_cmd pct; then
  log_message "Neither 'qm' nor 'pct' found. Are you running this on a Proxmox host?"
  exit 1
fi

acquire_lock

# ------------------------------
# Wait for restoration (if not using upssched timer)
# ------------------------------
if [[ "$NO_WAIT" != true && "$POWER_FAILURE_WAIT_TIME" -gt 0 ]]; then
  log_message "Event=${EVENT:-unknown}. Waiting ${POWER_FAILURE_WAIT_TIME}s for power restoration..."
  sleep "$POWER_FAILURE_WAIT_TIME"
fi

# ------------------------------
# UPS status check
# ------------------------------
UPS_STATUS="UNKNOWN"
BATTERY_LEVEL="0"

if [[ "$SIMULATE_FAILURE" == true ]]; then
  log_message "Simulating power failure. Proceeding with shutdown sequence."
else
  local_status="$(upsc_get ups.status)"
  local_batt="$(upsc_get battery.charge)"
  [[ -n "$local_status" ]] && UPS_STATUS="$local_status"
  [[ -n "$local_batt" ]] && BATTERY_LEVEL="$local_batt"

  if [[ "$UPS_STATUS" =~ OL ]]; then
    log_message "Power restored / UPS online (status=${UPS_STATUS}, battery=${BATTERY_LEVEL}%). Exiting."
    exit 0
  fi

  if [[ "$UPS_STATUS" == "UNKNOWN" && "$PROCEED_ON_UNKNOWN" != true ]]; then
    log_message "Could not read UPS status via upsc (${UPS_IDENTIFIER}). Refusing to proceed (set PROCEED_ON_UNKNOWN=true to override)."
    exit 1
  fi

  log_message "UPS status=${UPS_STATUS}, battery=${BATTERY_LEVEL}%. Power not restored. Starting layered shutdown."
fi

# ------------------------------
# Build and execute plan
# ------------------------------
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

# ------------------------------
# Force stop remaining guests (after grace period)
# ------------------------------
log_message "Waiting ${SHUTDOWN_TIMEOUT}s for guests to stop gracefully..."
sleep "$SHUTDOWN_TIMEOUT"
force_stop_remaining

# ------------------------------
# Host shutdown
# ------------------------------
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
