#!/usr/bin/env bash
# ==============================================================================
# Proxmox UPS Toolkit Wizard (NUT) - whiptail TUI setup & configuration
# ==============================================================================
set -u

SHUTDOWN_SCRIPT_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/proxmox-shutdown-advanced.sh"
SHUTDOWN_SCRIPT_DST="/usr/local/sbin/proxmox-shutdown.sh"
UPSSCHED_CMD_DST="/usr/local/sbin/proxmox-upssched-cmd"
MONITOR_SCRIPT_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/proxmox-ups-monitor.sh"
MONITOR_SCRIPT_DST="/usr/local/sbin/proxmox-ups-monitor.sh"
CONFIG_FILE="/etc/proxmox-ups-shutdown.conf"
LOG_DIR="/var/log/proxmox-ups-toolkit"
TRANSITION_DELAY="${TRANSITION_DELAY:-0.05}"

need_root() { [[ "${EUID:-$(id -u)}" -eq 0 ]] || { echo "Please run as root (sudo)."; exit 1; }; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }

# Prefer whiptail; fallback to plain.
UI="plain"
choose_ui() {
  if have_cmd whiptail; then UI="whiptail"; return 0; fi
  UI="plain"
}
choose_ui

# Always available clear helper
ui_clear() {
  # Clear screen (and try to clear scrollback for a cleaner SSH view)
  printf "\033[H\033[2J\033[3J" >/dev/null 2>&1 || true
  command -v clear >/dev/null 2>&1 && clear >/dev/null 2>&1 && return 0
  # ANSI full reset as fallback
  printf "\033c" >/dev/null 2>&1 || true
}

clear_full_screen() {
  # Strong clear: screen + scrollback (where supported)
  printf "\033[2J\033[H\033[3J" >/dev/null 2>&1 || true
  command -v clear >/dev/null 2>&1 && clear >/dev/null 2>&1 || true
  printf "\033[H\033[2J\033[3J" >/dev/null 2>&1 || true
}

ui_clear_hard() {
  # Extra-aggressive clear for SSH (try to clear scrollback + reset)
  printf "\033c" >/dev/null 2>&1 || true
  printf "\033[H\033[2J\033[3J" >/dev/null 2>&1 || true
  command -v clear >/dev/null 2>&1 && clear >/dev/null 2>&1 || true
  command -v tput >/dev/null 2>&1 && tput reset >/dev/null 2>&1 || true
}


ui_msg() {
  ui_clear
  local msg="$1"
  if [[ "$UI" == "whiptail" ]]; then
    whiptail --title "Proxmox UPS Toolkit" --msgbox "$msg" 18 78
  else
    echo; echo "$msg"; echo
    read -r -p "Press Enter to continue..."
  fi
}

ui_infobox() {
  ui_clear
  local msg="$1"
  if [[ "$UI" == "whiptail" ]]; then
    whiptail --title "Proxmox UPS Toolkit" --infobox "$msg" 10 78
  else
    echo; echo "$msg"; echo
  fi
}

ui_yesno() {
  ui_clear
  local msg="$1"
  if [[ "$UI" == "whiptail" ]]; then
    whiptail --title "Proxmox UPS Toolkit" --yesno "$msg" 18 78
    return $?
  else
    read -r -p "$msg [y/N]: " ans
    [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]]
  fi
}

ui_input() {
  ui_clear
  local prompt="$1" default="${2:-}"
  if [[ "$UI" == "whiptail" ]]; then
    whiptail --title "Proxmox UPS Toolkit" --inputbox "$prompt" 18 78 "$default" --cancel-button "Back" 3>&1 1>&2 2>&3
  else
    read -r -p "$prompt [$default]: " val
    echo "${val:-$default}"
  fi
}

ui_menu() {
  ui_clear
  local prompt="$1"; shift
  if [[ "$UI" == "whiptail" ]]; then
    whiptail --title "Proxmox UPS Toolkit" --menu "$prompt" 20 92 12 --cancel-button "Back" "$@" 3>&1 1>&2 2>&3
  else
    echo "$prompt"
    local i=1; local tags=()
    while [[ $# -gt 0 ]]; do
      local tag="$1"; local item="$2"; shift 2
      echo "  [$i] $item"
      tags+=("$tag"); ((i++))
    done
    read -r -p "Choose number: " choice
    echo "${tags[$((choice-1))]}"
  fi
}

backup_file() {
  local f="$1"
  if [[ -f "$f" ]]; then
    local ts; ts="$(date +%Y%m%d-%H%M%S)"
    cp -a "$f" "${f}.bak.${ts}"
  fi
}

# Keep UI visible while commands run; log output to /tmp/proxmox-ups-wizard.log
run_cmd_silent() {
  local label="$1"; shift
  local log="/tmp/proxmox-ups-wizard.log"
  ui_infobox "$label\n\n(Logging to $log)"
  {
    echo "[$(date -Is)] $label"
    echo "CMD: $*"
    "$@"
    echo "RC: $?"
    echo
  } >> "$log" 2>&1
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    ui_msg "Command failed (exit $rc).\n\n$label\n\nSee log:\n  $log"
  fi
  return $rc
}

apt_install_if_missing() {
  local pkg="$1"
  dpkg -s "$pkg" >/dev/null 2>&1 && return 0
  run_cmd_silent "Installing package: $pkg" bash -lc "apt-get update -y && DEBIAN_FRONTEND=noninteractive apt-get install -y $pkg"
}

install_prereqs() {
  need_root
  apt_install_if_missing nut
  apt_install_if_missing whiptail || true
  choose_ui
}

write_shutdown_script() {
  if [[ ! -f "$SHUTDOWN_SCRIPT_SRC" ]]; then
    ui_msg "Can't find:\n$SHUTDOWN_SCRIPT_SRC\n\nPut proxmox-shutdown-advanced.sh in the same folder as this wizard."
    return 1
  fi
  install -m 0755 "$SHUTDOWN_SCRIPT_SRC" "$SHUTDOWN_SCRIPT_DST"
  ui_msg "Installed shutdown script to:\n$SHUTDOWN_SCRIPT_DST"
}

install_logging_monitor() {
  mkdir -p "$LOG_DIR"
  chmod 0755 "$LOG_DIR" || true

  if [[ -f "$MONITOR_SCRIPT_SRC" ]]; then
    install -m 0755 "$MONITOR_SCRIPT_SRC" "$MONITOR_SCRIPT_DST"
  else
    ui_msg "Monitor script not found:\n$MONITOR_SCRIPT_SRC"
    return 1
  fi

  cat > /etc/systemd/system/proxmox-ups-monitor.service <<'EOF'
[Unit]
Description=Proxmox UPS status logger (NUT)
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/proxmox-ups-monitor.sh
EOF

  cat > /etc/systemd/system/proxmox-ups-monitor.timer <<'EOF'
[Unit]
Description=Run Proxmox UPS status logger every 15 seconds

[Timer]
OnBootSec=15s
OnUnitActiveSec=15s
AccuracySec=5s
Unit=proxmox-ups-monitor.service

[Install]
WantedBy=timers.target
EOF

  run_cmd_silent "Enabling UPS status logging timer" bash -lc "systemctl daemon-reload && systemctl enable --now proxmox-ups-monitor.timer"
}

list_vms() { qm list 2>/dev/null | awk 'NR>1 {printf "%s\t%s\t%s\n",$1,$2,$3}'; }
list_cts() { pct list 2>/dev/null | awk 'NR>1 {printf "%s\t%s\t%s\n",$1,$NF,$2}'; }

POWER_FAILURE_WAIT_TIME="${POWER_FAILURE_WAIT_TIME:-300}"
ACTION_DELAY="${ACTION_DELAY:-1}"
SHUTDOWN_TIMEOUT="${SHUTDOWN_TIMEOUT:-20}"
SYNC_AFTER_ACTION="${SYNC_AFTER_ACTION:-true}"
UPS_IDENTIFIER="${UPS_IDENTIFIER:-myups@localhost}"
DEFAULT_VM_ACTION="${DEFAULT_VM_ACTION:-shutdown}"
DEFAULT_CT_ACTION="${DEFAULT_CT_ACTION:-shutdown}"
DEFAULT_VM_PRIORITY="${DEFAULT_VM_PRIORITY:-50}"
DEFAULT_CT_PRIORITY="${DEFAULT_CT_PRIORITY:-50}"

declare -A VM_ACTIONS VM_PRIORITY CT_ACTIONS CT_PRIORITY

load_config() { [[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"; }

save_config() {
  backup_file "$CONFIG_FILE"
  {
    echo "# Generated by proxmox-ups-wizard.sh on $(date -Is)"
    echo "POWER_FAILURE_WAIT_TIME=${POWER_FAILURE_WAIT_TIME}"
    echo "ACTION_DELAY=${ACTION_DELAY}"
    echo "SHUTDOWN_TIMEOUT=${SHUTDOWN_TIMEOUT}"
    echo "SYNC_AFTER_ACTION=${SYNC_AFTER_ACTION}"
    echo "UPS_IDENTIFIER=\"${UPS_IDENTIFIER}\""
    echo "DEFAULT_VM_ACTION=\"${DEFAULT_VM_ACTION}\""
    echo "DEFAULT_CT_ACTION=\"${DEFAULT_CT_ACTION}\""
    echo "DEFAULT_VM_PRIORITY=${DEFAULT_VM_PRIORITY}"
    echo "DEFAULT_CT_PRIORITY=${DEFAULT_CT_PRIORITY}"
    echo "PROCEED_ON_UNKNOWN=${PROCEED_ON_UNKNOWN:-false}"
    echo "LOG_TAG=\"${LOG_TAG:-PVE-UPS}\""
    echo
    echo "declare -A VM_ACTIONS"
    for k in "${!VM_ACTIONS[@]}"; do printf 'VM_ACTIONS[%q]=%q\n' "$k" "${VM_ACTIONS[$k]}"; done | sort -n
    echo
    echo "declare -A VM_PRIORITY"
    for k in "${!VM_PRIORITY[@]}"; do printf 'VM_PRIORITY[%q]=%q\n' "$k" "${VM_PRIORITY[$k]}"; done | sort -n
    echo
    echo "declare -A CT_ACTIONS"
    for k in "${!CT_ACTIONS[@]}"; do printf 'CT_ACTIONS[%q]=%q\n' "$k" "${CT_ACTIONS[$k]}"; done | sort -n
    echo
    echo "declare -A CT_PRIORITY"
    for k in "${!CT_PRIORITY[@]}"; do printf 'CT_PRIORITY[%q]=%q\n' "$k" "${CT_PRIORITY[$k]}"; done | sort -n
  } > "$CONFIG_FILE"
  chmod 0644 "$CONFIG_FILE"
  ui_msg "Saved config to:\n$CONFIG_FILE"
}

show_layers_help() {
  ui_msg "How layers work (priorities)\n\n\
This toolkit shuts down guests in PRIORITY order:\n\
  - Lower number = shut down earlier (less important)\n\
  - Higher number = shut down later (more important)\n\n\
Example layers:\n\
  10  = Dev/Test / non-critical\n\
  50  = App servers\n\
  90  = Core services (storage, auth, DNS, DB)\n\nPreview any time:\n  /usr/local/sbin/proxmox-shutdown.sh --plan"
}

# --- Step 2 (NUT config) - simplified (existing-detect menu retained in earlier builds; keep baseline) ---
# (Keeping current behavior from your earlier working build; Step 2 can be iterated further as needed.)

detected_get() { local key="$1"; local blob="$2"; echo "$blob" | sed -n "s/.*${key}=\([^;]*\).*/\1/p"; }

detect_nut_config() {
  # Outputs: MODE=...;TYPE=...;UPSNAME=...;DRIVER=...;PORT=...;COMMUNITY=...;MONITOR=...;ROLE=...
  local mode type upsname driver port community monitor role
  mode="unknown"; type="unknown"; upsname=""; driver=""; port=""; community=""; monitor=""; role=""

  if [[ -f /etc/nut/nut.conf ]]; then
    mode="$(awk -F'=' '/^MODE=/{gsub(/"/,"",$2); print $2}' /etc/nut/nut.conf 2>/dev/null | tail -n1)"
    [[ -z "$mode" ]] && mode="unknown"
  fi

  if [[ "$mode" == "netclient" ]]; then
    type="remote"
    if [[ -f /etc/nut/upsmon.conf ]]; then
      monitor="$(awk '/^MONITOR[[:space:]]+/{print $2; exit}' /etc/nut/upsmon.conf 2>/dev/null || true)"
      role="$(awk '/^MONITOR[[:space:]]+/{print $6; exit}' /etc/nut/upsmon.conf 2>/dev/null || true)"
    fi
  else
    if [[ -f /etc/nut/ups.conf ]]; then
      upsname="$(awk '/^\[/{gsub(/\[|\]/,""); print; exit}' /etc/nut/ups.conf 2>/dev/null || true)"
      driver="$(awk -F'=' '/^[[:space:]]*driver[[:space:]]*=/{gsub(/[[:space:]]*/,"",$2); print $2; exit}' /etc/nut/ups.conf 2>/dev/null || true)"
      port="$(awk -F'=' '/^[[:space:]]*port[[:space:]]*=/{sub(/^[[:space:]]*/,"",$2); gsub(/[[:space:]]*/,"",$2); print $2; exit}' /etc/nut/ups.conf 2>/dev/null || true)"
      community="$(awk -F'=' '/^[[:space:]]*community[[:space:]]*=/{sub(/^[[:space:]]*/,"",$2); gsub(/[[:space:]]*/,"",$2); print $2; exit}' /etc/nut/ups.conf 2>/dev/null || true)"
      [[ "$driver" == "usbhid-ups" ]] && type="usb"
      [[ "$driver" == "snmp-ups" ]] && type="snmp"
    fi
  fi

  echo "MODE=$mode;TYPE=$type;UPSNAME=$upsname;DRIVER=$driver;PORT=$port;COMMUNITY=$community;MONITOR=$monitor;ROLE=$role"
}

show_detected_nut_summary() {
  local s="$1"
  local mode type upsname driver port community monitor role
  mode="$(detected_get MODE "$s")"
  type="$(detected_get TYPE "$s")"
  upsname="$(detected_get UPSNAME "$s")"
  driver="$(detected_get DRIVER "$s")"
  port="$(detected_get PORT "$s")"
  community="$(detected_get COMMUNITY "$s")"
  monitor="$(detected_get MONITOR "$s")"
  role="$(detected_get ROLE "$s")"

  if [[ "$mode" == "netclient" ]]; then
    ui_msg "Detected existing NUT configuration:\n\nMode: netclient (remote)\nMonitor: ${monitor:-<unknown>}\nRole: ${role:-<unknown>}"
  else
    ui_msg "Detected existing NUT configuration:\n\nMode: ${mode:-unknown}\nType: ${type:-unknown}\nUPS name: ${upsname:-<unknown>}\nDriver: ${driver:-<unknown>}\nPort/IP: ${port:-<unknown>}\nCommunity: ${community:-<n/a>}"
  fi
}

write_upsmon_with_upssched() {
  local monitor_target="$1" user="$2" pass="$3" role="$4"
  local upssched_path; upssched_path="$(command -v upssched 2>/dev/null || true)"
  if [[ -z "$upssched_path" ]]; then
    ui_msg "upssched not found.\n\nInstall NUT client components first (nut-client)."
    return 1
  fi

  backup_file /etc/nut/upsmon.conf
  cat > /etc/nut/upsmon.conf <<EOF
# Generated by proxmox-ups-wizard.sh
MONITOR ${monitor_target} 1 ${user} ${pass} ${role}
MINSUPPLIES 1
NOTIFYCMD ${upssched_path}
NOTIFYFLAG ONBATT EXEC
NOTIFYFLAG ONLINE EXEC
NOTIFYFLAG LOWBATT EXEC
NOTIFYFLAG COMMBAD EXEC
NOTIFYFLAG COMMOK EXEC
POLLFREQ 5
POLLFREQALERT 5
HOSTSYNC 15
DEADTIME 15
POWERDOWNFLAG /etc/killpower
RBWARNTIME 43200
NOCOMMWARNTIME 300
EOF
}

configure_nut_connection() {
  install_prereqs
  load_config

  local detected action_choice detected_type
  detected="$(detect_nut_config)"
  action_choice="reset"
  detected_type="$(detected_get TYPE "$detected")"

  if [[ -f /etc/nut/nut.conf || -f /etc/nut/ups.conf || -f /etc/nut/upsmon.conf ]]; then
    show_detected_nut_summary "$detected"
    action_choice="$(ui_menu "Existing NUT config found" \
      "edit"  "Edit existing config (keep current, adjust values)" \
      "reset" "Setup from scratch (overwrite NUT config)" \
      "back"  "Back" \
    )" || return 0
    [[ "$action_choice" == "back" ]] && return 0
  fi

  local choice
  if [[ "$action_choice" == "edit" && -n "$detected_type" && "$detected_type" != "unknown" ]]; then
    choice="$detected_type"
    ui_msg "Editing existing NUT config (type: $choice).\n\nReview/change values in the next screens."
  else
    choice="$(ui_menu "UPS connection type" \
      "usb"    "USB (usbhid-ups)" \
      "snmp"   "IP via SNMP (snmp-ups)" \
      "remote" "Remote NUT server (netclient)" \
    )" || return 0
  fi

  case "$choice" in
    usb)
      local upsname upsdesc adminpass
      upsname="$(ui_input "UPS name (identifier; e.g., myups)" "$(detected_get UPSNAME "$detected")")" || return 0
      [[ -z "$upsname" ]] && upsname="myups"
      upsdesc="$(ui_input "UPS description (optional)" "Proxmox UPS")" || return 0
      adminpass="$(ui_input "Password for NUT user (stored in /etc/nut/upsd.users)" "change-me")" || return 0

      backup_file /etc/nut/nut.conf; backup_file /etc/nut/ups.conf; backup_file /etc/nut/upsd.users; backup_file /etc/nut/upsmon.conf
      mkdir -p /etc/nut

      cat > /etc/nut/nut.conf <<EOF
MODE=standalone
EOF
      cat > /etc/nut/ups.conf <<EOF
maxretry = 3
[${upsname}]
  driver = usbhid-ups
  port = auto
  desc = "${upsdesc}"
EOF
      cat > /etc/nut/upsd.users <<EOF
[admin]
  password = ${adminpass}
  actions = SET
  instcmds = ALL
  upsmon master
EOF
      UPS_IDENTIFIER="${upsname}@localhost"
      write_upsmon_with_upssched "${upsname}@localhost" "admin" "${adminpass}" "master" || return 0
      ;;
    snmp)
      apt_install_if_missing nut-snmp || true
      local upsname upsdesc ip community adminpass
      upsname="$(ui_input "UPS name (identifier; e.g., myups)" "$(detected_get UPSNAME "$detected")")" || return 0
      [[ -z "$upsname" ]] && upsname="myups"
      ip="$(ui_input "UPS IP address" "$(detected_get PORT "$detected")")" || return 0
      [[ -z "$ip" ]] && ip="192.168.1.50"
      community="$(ui_input "SNMP community (v2c)" "$(detected_get COMMUNITY "$detected")")" || return 0
      [[ -z "$community" ]] && community="public"
      upsdesc="$(ui_input "UPS description (optional)" "Proxmox UPS (SNMP)")" || return 0
      adminpass="$(ui_input "Password for NUT user (stored in /etc/nut/upsd.users)" "change-me")" || return 0

      backup_file /etc/nut/nut.conf; backup_file /etc/nut/ups.conf; backup_file /etc/nut/upsd.users; backup_file /etc/nut/upsmon.conf
      mkdir -p /etc/nut

      cat > /etc/nut/nut.conf <<EOF
MODE=standalone
EOF
      cat > /etc/nut/ups.conf <<EOF
maxretry = 3
[${upsname}]
  driver = snmp-ups
  port = ${ip}
  community = ${community}
  desc = "${upsdesc}"
EOF
      cat > /etc/nut/upsd.users <<EOF
[admin]
  password = ${adminpass}
  actions = SET
  instcmds = ALL
  upsmon master
EOF
      UPS_IDENTIFIER="${upsname}@localhost"
      write_upsmon_with_upssched "${upsname}@localhost" "admin" "${adminpass}" "master" || return 0
      ;;
    remote)
      backup_file /etc/nut/nut.conf; backup_file /etc/nut/upsmon.conf
      mkdir -p /etc/nut
      cat > /etc/nut/nut.conf <<EOF
MODE=netclient
EOF
      local upsmon_target user pass
      upsmon_target="$(ui_input "Remote MONITOR target (upsname@ip-or-host)" "$(detected_get MONITOR "$detected")")" || return 0
      [[ -z "$upsmon_target" ]] && upsmon_target="ups@192.168.1.100"
      user="$(ui_input "Remote upsmon username" "monuser")" || return 0
      pass="$(ui_input "Remote upsmon password" "secret")" || return 0
      UPS_IDENTIFIER="$upsmon_target"
      write_upsmon_with_upssched "$upsmon_target" "$user" "$pass" "slave" || return 0
      ;;
  esac

  save_config
  ui_msg "NUT connection configured."
}


configure_upssched_timer() {
  install_prereqs
  load_config

  local seconds
  seconds="$(ui_input "How long to wait on battery before starting shutdown? (seconds)" "${POWER_FAILURE_WAIT_TIME}")" || return 0
  POWER_FAILURE_WAIT_TIME="$seconds"

  mkdir -p /etc/nut
  backup_file /etc/nut/upssched.conf
  backup_file "$UPSSCHED_CMD_DST"

  cat > /etc/nut/upssched.conf <<EOF
CMDSCRIPT ${UPSSCHED_CMD_DST}
PIPEFN /run/nut/upssched.pipe
LOCKFN /run/nut/upssched.lock
AT ONBATT * START-TIMER onbatt ${seconds}
AT ONLINE * CANCEL-TIMER onbatt
AT LOWBATT * EXECUTE lowbatt
AT COMMBAD * EXECUTE commbad
AT COMMOK  * EXECUTE commok
EOF

  cat > "$UPSSCHED_CMD_DST" <<'EOF'
#!/usr/bin/env bash
set -u
SCRIPT="/usr/local/sbin/proxmox-shutdown.sh"
log() { echo "PVE-UPS: upssched-cmd: $*" | tee >(logger -t "PVE-UPS"); }
case "${1:-}" in
  onbatt)  log "onbatt timer expired -> starting shutdown"; exec "$SCRIPT" --no-wait --event "onbatt-timer" ;;
  lowbatt) log "low battery -> immediate shutdown"; exec "$SCRIPT" --no-wait --event "lowbatt" ;;
  commbad) log "UPS comm lost -> running shutdown"; exec "$SCRIPT" --no-wait --event "commbad" ;;
  commok)  log "UPS comm restored"; exit 0 ;;
  *)       log "Unknown upssched action: ${1:-<empty>}"; exit 0 ;;
esac
EOF
  chmod 0755 "$UPSSCHED_CMD_DST"

  save_config
  ui_msg "upssched configured.\n\nRestart NUT services afterwards (Step 5)."
}

restart_nut_services() {
  run_cmd_silent "Restarting NUT services" bash -lc "systemctl daemon-reload && systemctl restart nut-client || true; systemctl restart nut-server || true; systemctl enable nut-client || true; systemctl enable nut-server || true"
  ui_msg "Restarted/enabled NUT services."
}

configure_guest_priorities() {
  load_config
  while true; do
    local menu_items=()
    menu_items+=("B" "Back")
    menu_items+=("S" "Save config")

    while IFS=$'\t' read -r id name status; do
      [[ -z "$id" ]] && continue
      local p="${VM_PRIORITY[$id]:-${DEFAULT_VM_PRIORITY:-50}}"
      local a="${VM_ACTIONS[$id]:-${DEFAULT_VM_ACTION:-shutdown}}"
      menu_items+=("vm:$id" "VM $id ($name) status=$status  prio=$p action=$a")
    done < <(list_vms)

    while IFS=$'\t' read -r id name status; do
      [[ -z "$id" ]] && continue
      local p="${CT_PRIORITY[$id]:-${DEFAULT_CT_PRIORITY:-50}}"
      local a="${CT_ACTIONS[$id]:-${DEFAULT_CT_ACTION:-shutdown}}"
      menu_items+=("ct:$id" "CT $id ($name) status=$status  prio=$p action=$a")
    done < <(list_cts)

    local choice
    choice="$(ui_menu "Edit guests (per VM/CT)" "${menu_items[@]}")" || return 0

    case "$choice" in
      B) return 0 ;;
      S) save_config ;;
      vm:*)
        local id="${choice#vm:}"
        local curp="${VM_PRIORITY[$id]:-${DEFAULT_VM_PRIORITY:-50}}"
        local np na
        np="$(ui_input "VM $id priority (lower=shutdown earlier)" "$curp")" || continue
        na="$(ui_menu "VM $id action" \
          "shutdown" "shutdown (graceful)" \
          "hibernate" "hibernate (suspend to disk)" \
          "stop" "stop (force off)" \
        )" || continue
        VM_PRIORITY[$id]="$np"
        VM_ACTIONS[$id]="$na"
        ;;
      ct:*)
        local id="${choice#ct:}"
        local curp="${CT_PRIORITY[$id]:-${DEFAULT_CT_PRIORITY:-50}}"
        local np na
        np="$(ui_input "CT $id priority (lower=shutdown earlier)" "$curp")" || continue
        na="$(ui_menu "CT $id action" \
          "shutdown" "shutdown (graceful)" \
          "stop" "stop (force off)" \
        )" || continue
        CT_PRIORITY[$id]="$np"
        CT_ACTIONS[$id]="$na"
        ;;
    esac
  done
}

configure_priorities() {
  load_config
  while true; do
    local choice
    choice="$(ui_menu "Layers / priorities\n\nLower number = shut down earlier (less important)." \
      "1" "Edit default priorities" \
      "2" "Edit default behavior" \
      "3" "Edit guest priorities" \
      "4" "Show explanation" \
      "S" "Save config" \
      "P" "Show current plan" \
      "B" "Back" \
    )" || return 0

    case "$choice" in
      1)
        DEFAULT_VM_PRIORITY="$(ui_input "Default VM priority (lower=shutdown earlier)" "${DEFAULT_VM_PRIORITY:-50}")" || true
        DEFAULT_CT_PRIORITY="$(ui_input "Default CT priority (lower=shutdown earlier)" "${DEFAULT_CT_PRIORITY:-50}")" || true
        ;;
      2)
        DEFAULT_VM_ACTION="$(ui_menu "Default VM action" \
          "shutdown" "shutdown (recommended)" \
          "hibernate" "hibernate (suspend to disk)" \
          "stop" "stop (force off)" \
        )" || true
        DEFAULT_CT_ACTION="$(ui_menu "Default CT action" \
          "shutdown" "shutdown (recommended)" \
          "stop" "stop (force off)" \
        )" || true
        ;;
      3) configure_guest_priorities ;;
      4) show_layers_help ;;
      S) save_config ;;
      P) ui_msg "$(${SHUTDOWN_SCRIPT_DST} --plan 2>/dev/null || echo "Install shutdown script first.")" ;;
      B) return 0 ;;
    esac
  done
}


check_ups_connection() {
  load_config
  if ! command -v upsc >/dev/null 2>&1; then
    ui_msg "The command 'upsc' was not found.\n\nInstall NUT first (Step 2)."
    return 1
  fi

  ui_infobox "Checking UPS connection...\n\nPlease wait."
  local out rc
  out="$(upsc "$UPS_IDENTIFIER" 2>&1)"
  rc=$?

  if [[ $rc -ne 0 ]]; then
    ui_msg "UPS query failed.\n\nUPS_IDENTIFIER: $UPS_IDENTIFIER\n\n$out"
    return 1
  fi

  local status charge runtime load
  status="$(echo "$out" | awk -F': ' '$1=="ups.status"{print $2; exit}')"
  charge="$(echo "$out" | awk -F': ' '$1=="battery.charge"{print $2; exit}')"
  runtime="$(echo "$out" | awk -F': ' '$1=="battery.runtime"{print $2; exit}')"
  load="$(echo "$out" | awk -F': ' '$1=="ups.load"{print $2; exit}')"

  [[ -z "$status" ]] && status="<n/a>"
  [[ -z "$charge" ]] && charge="<n/a>"
  [[ -z "$runtime" ]] && runtime="<n/a>"
  [[ -z "$load" ]] && load="<n/a>"

  tmp="$(mktemp /tmp/pve-ups-upsc.XXXXXX)"
  {
    echo "UPS connection OK"
    echo
    echo "UPS_IDENTIFIER : $UPS_IDENTIFIER"
    echo "ups.status     : $status"
    echo "battery.charge : $charge"
    echo "battery.runtime: $runtime"
    echo "ups.load       : $load"
    echo
    echo "---- Full upsc output ----"
    echo "$out"
  } > "$tmp"

  if [[ "$UI" == "whiptail" ]]; then
    ui_clear
    whiptail --title "UPS status" --scrolltext --textbox "$tmp" 24 92
  else
    ui_clear
    cat "$tmp"
    echo
    read -r -p "Press Enter to continue..."
  fi
  rm -f "$tmp"
}

run_test_menu() {
  local tchoice
  tchoice="$(ui_menu "Test menu" \
    "1" "Test without shutdown (safe; no changes)" \
    "2" "Test with actual shutdown/hibernation (guests only; host stays up)" \
    "B" "Back" \
  )" || return 0

  [[ "$tchoice" == "B" ]] && return 0

  [[ -x "$SHUTDOWN_SCRIPT_DST" ]] || write_shutdown_script || return 0

  tmp="$(mktemp /tmp/pve-ups-test.XXXXXX)"

  if [[ "$tchoice" == "2" ]]; then
    ui_yesno "WARNING: This will SHUT DOWN / HIBERNATE running VMs/CTs according to your plan.\n\nHost will NOT shut down.\n\nContinue?" || { rm -f "$tmp"; return 0; }
  fi

  # Clear the SSH view and show ONLY the wait message
  ui_clear_hard
  echo "Currently running test, please wait for the menu to come back or the result screen."
  echo

  if [[ "$tchoice" == "1" ]]; then
    bash -lc "/usr/local/sbin/proxmox-shutdown.sh --plan; echo; /usr/local/sbin/proxmox-shutdown.sh --test --simulate --no-wait" >"$tmp" 2>&1 || true
  else
    bash -lc "/usr/local/sbin/proxmox-shutdown.sh --plan; echo; /usr/local/sbin/proxmox-shutdown.sh --simulate --no-wait --dry-run-host" >"$tmp" 2>&1 || true
  fi

  if [[ "$UI" == "whiptail" ]]; then
    ui_clear
    whiptail --title "Test results" --scrolltext --textbox "$tmp" 24 92
  else
    ui_clear
    cat "$tmp"
    echo
    read -r -p "Press Enter to continue..."
  fi
  rm -f "$tmp"
}



first_setup() {
  ui_msg "First Setup will guide you through the full configuration:\n\n1) Install scripts\n2) Configure UPS connection\n3) Configure on-battery timer\n4) Configure layers/priorities\n5) Restart NUT services\n6) Check UPS status\n\nPress Back any time to stop."
  install_prereqs
  write_shutdown_script
  install_logging_monitor

  configure_nut_connection || true
  configure_upssched_timer || true
  configure_priorities || true
  restart_nut_services || true
  check_ups_connection || true

  ui_msg "First Setup completed.\n\nYou can re-run any step from the main menu."
}

main_menu() {
  need_root
  load_config
  while true; do
    local choice
    choice="$(ui_menu "Main menu" \
      "0" "First Setup" \
      "1" "Install/Update scripts + enable logging" \
      "2" "Configure UPS connection (NUT)" \
      "3" "Configure on-battery timer (upssched)" \
      "4" "Configure VM/CT layers (priorities/actions)" \
      "5" "Restart/Enable NUT services" \
      "6" "Check UPS connection/status" \
      "H" "Explain layers/priorities" \
      "T" "Test menu" \
      "X" "Exit" \
    )" || exit 0

    ui_infobox "Loading..."
    sleep 0.08

    case "$choice" in
      0)
        first_setup
        ;;
      1)
        ui_infobox "Step 1: Installing scripts + enabling logging..."
        sleep "$TRANSITION_DELAY"
        install_prereqs; write_shutdown_script; install_logging_monitor
        ;;
      2)
        ui_infobox "Step 2: Configure UPS connection (NUT)..."
        sleep "$TRANSITION_DELAY"
        configure_nut_connection
        ;;
      3)
        ui_infobox "Step 3: Configure on-battery timer..."
        sleep "$TRANSITION_DELAY"
        configure_upssched_timer
        ;;
      4)
        ui_infobox "Step 4: Configure layers/priorities..."
        sleep "$TRANSITION_DELAY"
        configure_priorities
        ;;
      5)
        ui_infobox "Step 5: Restarting/enabling NUT services..."
        sleep "$TRANSITION_DELAY"
        restart_nut_services
        ;;
      6)
        check_ups_connection
        ;;
      H)
        show_layers_help
        ;;
      T)
        run_test_menu
        ;;
      X) exit 0 ;;
    esac
  done
}

main_menu
