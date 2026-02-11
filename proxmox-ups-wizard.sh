#!/usr/bin/env bash
# ==============================================================================
# Proxmox UPS Toolkit Wizard (NUT) - TUI setup & configuration
# ==============================================================================
# - Installs NUT (Network UPS Tools) if missing.
# - Helps configure UPS connection (USB / SNMP / Remote NUT).
# - Installs the shutdown orchestrator and configures layered VM/CT priorities.
# - Optionally configures upssched timers so shutdown only starts after a delay,
#   and is cancelled when power returns.
#
# Run: sudo ./proxmox-ups-wizard.sh
#
# Notes:
# - Designed for Debian/Proxmox (apt + /etc/nut).
# - Always creates backups before overwriting /etc/nut/*.
# ==============================================================================

set -u

SHUTDOWN_SCRIPT_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/proxmox-shutdown-advanced.sh"
SHUTDOWN_SCRIPT_DST="/usr/local/sbin/proxmox-shutdown.sh"
UPSSCHED_CMD_DST="/usr/local/sbin/proxmox-upssched-cmd"
CONFIG_FILE="/etc/proxmox-ups-shutdown.conf"

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "Please run as root (sudo)."
    exit 1
  fi
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

# Prefer whiptail; fallback to dialog; fallback to plain prompts.
UI="plain"
choose_ui() {
  if have_cmd whiptail; then UI="whiptail"; return 0; fi
  if have_cmd dialog; then UI="dialog"; return 0; fi
  UI="plain"
}
choose_ui

ui_msg() {
  local msg="$1"
  if [[ "$UI" == "whiptail" ]]; then
    whiptail --title "Proxmox UPS Toolkit" --msgbox "$msg" 18 78
  elif [[ "$UI" == "dialog" ]]; then
    dialog --title "Proxmox UPS Toolkit" --msgbox "$msg" 18 78
  else
    echo
    echo "$msg"
    echo
    read -r -p "Press Enter to continue..."
  fi
}

ui_yesno() {
  local msg="$1"
  if [[ "$UI" == "whiptail" ]]; then
    whiptail --title "Proxmox UPS Toolkit" --yesno "$msg" 18 78
    return $?
  elif [[ "$UI" == "dialog" ]]; then
    dialog --title "Proxmox UPS Toolkit" --yesno "$msg" 18 78
    return $?
  else
    read -r -p "$msg [y/N]: " ans
    [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]]
  fi
}

ui_input() {
  local prompt="$1" default="${2:-}"
  if [[ "$UI" == "whiptail" ]]; then
    whiptail --title "Proxmox UPS Toolkit" --inputbox "$prompt" 18 78 "$default" 3>&1 1>&2 2>&3
  elif [[ "$UI" == "dialog" ]]; then
    dialog --title "Proxmox UPS Toolkit" --inputbox "$prompt" 18 78 "$default" 3>&1 1>&2 2>&3
  else
    read -r -p "$prompt [$default]: " val
    echo "${val:-$default}"
  fi
}

ui_menu() {
  local prompt="$1"; shift
  # remaining args are pairs: tag item
  if [[ "$UI" == "whiptail" ]]; then
    whiptail --title "Proxmox UPS Toolkit" --menu "$prompt" 20 92 12 "$@" 3>&1 1>&2 2>&3
  elif [[ "$UI" == "dialog" ]]; then
    dialog --title "Proxmox UPS Toolkit" --menu "$prompt" 20 92 12 "$@" 3>&1 1>&2 2>&3
  else
    echo "$prompt"
    local i=1
    local tags=()
    while [[ $# -gt 0 ]]; do
      local tag="$1"; local item="$2"; shift 2
      echo "  [$i] $item"
      tags+=("$tag")
      ((i++))
    done
    read -r -p "Choose number: " choice
    echo "${tags[$((choice-1))]}"
  fi
}

backup_file() {
  local f="$1"
  if [[ -f "$f" ]]; then
    local ts
    ts="$(date +%Y%m%d-%H%M%S)"
    cp -a "$f" "${f}.bak.${ts}"
  fi
}

apt_install_if_missing() {
  local pkg="$1"
  if dpkg -s "$pkg" >/dev/null 2>&1; then
    return 0
  fi
  ui_msg "Installing package: $pkg"
  apt-get update -y >/dev/null
  DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg"
}

install_prereqs() {
  need_root
  # NUT meta-package installs nut-client + nut-server in Debian. (Extra drivers installed as needed.)
  apt_install_if_missing nut

  # Try to ensure we have a TUI if possible.
  if [[ "$UI" == "plain" ]]; then
    # Attempt to install whiptail for a nicer wizard (safe even if already installed).
    ui_msg "Optional: installing 'whiptail' for a nicer setup UI (if available)..."
    apt-get update -y >/dev/null
    DEBIAN_FRONTEND=noninteractive apt-get install -y whiptail >/dev/null 2>&1 || true
    choose_ui
  fi
}

write_shutdown_script() {
  if [[ ! -f "$SHUTDOWN_SCRIPT_SRC" ]]; then
    ui_msg "Can't find $SHUTDOWN_SCRIPT_SRC. Put proxmox-shutdown-advanced.sh in the same folder as this wizard."
    return 1
  fi
  install -m 0755 "$SHUTDOWN_SCRIPT_SRC" "$SHUTDOWN_SCRIPT_DST"
  ui_msg "Installed shutdown script to:\n$SHUTDOWN_SCRIPT_DST"
}

# ------------------------------
# VM/CT inventory helpers
# ------------------------------
list_vms() {
  qm list 2>/dev/null | awk 'NR>1 {printf "%s\t%s\t%s\n",$1,$2,$3}'
}
list_cts() {
  pct list 2>/dev/null | awk 'NR>1 {printf "%s\t%s\t%s\n",$1,$NF,$2}'
}

# ------------------------------
# Config in memory
# ------------------------------
# defaults
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

load_config() {
  if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
  fi
}

save_config() {
  backup_file "$CONFIG_FILE"
  {
    echo "# Generated by proxmox-ups-wizard.sh on $(date -Is)"
    echo "CONFIG_FILE=\"$CONFIG_FILE\""
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
    for k in "${!VM_ACTIONS[@]}"; do
      printf 'VM_ACTIONS[%q]=%q\n' "$k" "${VM_ACTIONS[$k]}"
    done | sort -n
    echo
    echo "declare -A VM_PRIORITY"
    for k in "${!VM_PRIORITY[@]}"; do
      printf 'VM_PRIORITY[%q]=%q\n' "$k" "${VM_PRIORITY[$k]}"
    done | sort -n
    echo
    echo "declare -A CT_ACTIONS"
    for k in "${!CT_ACTIONS[@]}"; do
      printf 'CT_ACTIONS[%q]=%q\n' "$k" "${CT_ACTIONS[$k]}"
    done | sort -n
    echo
    echo "declare -A CT_PRIORITY"
    for k in "${!CT_PRIORITY[@]}"; do
      printf 'CT_PRIORITY[%q]=%q\n' "$k" "${CT_PRIORITY[$k]}"
    done | sort -n
  } > "$CONFIG_FILE"
  chmod 0644 "$CONFIG_FILE"
  ui_msg "Saved config to:\n$CONFIG_FILE"
}

# ------------------------------
# NUT configuration
# ------------------------------
configure_nut_connection() {
  install_prereqs
  load_config

  local mode choice upsname upsdesc upstype
  choice="$(ui_menu "UPS connection type" \
    "usb"    "USB (local, common: APC/Eaton/CyberPower via usbhid-ups)" \
    "snmp"   "IP via SNMP (nut-snmp, for network management cards)" \
    "remote" "Remote NUT server (netclient; e.g., Synology/pfSense as server)" \
  )" || return 0

  case "$choice" in
      G)
        guided_setup
        ;;
      H)
        show_layers_help
        ;;
    usb)
      upstype="usb"
      upsname="$(ui_input "UPS name (identifier in NUT config; e.g., myups)" "myups")" || return 0
      upsdesc="$(ui_input "UPS description (optional)" "Proxmox UPS")" || return 0
      backup_file /etc/nut/nut.conf
      backup_file /etc/nut/ups.conf
      backup_file /etc/nut/upsd.users
      backup_file /etc/nut/upsmon.conf

      mkdir -p /etc/nut
      cat > /etc/nut/nut.conf <<EOF
# Generated by proxmox-ups-wizard.sh
MODE=standalone
EOF
      cat > /etc/nut/ups.conf <<EOF
# Generated by proxmox-ups-wizard.sh
maxretry = 3

[${upsname}]
  driver = usbhid-ups
  port = auto
  desc = "${upsdesc}"
EOF
      local adminpass
      adminpass="$(ui_input "Create a password for the upsmon user (stored in /etc/nut/upsd.users)" "change-me")" || return 0
      cat > /etc/nut/upsd.users <<EOF
# Generated by proxmox-ups-wizard.sh
[admin]
  password = ${adminpass}
  actions = SET
  instcmds = ALL
  upsmon master
EOF
      UPS_IDENTIFIER="${upsname}@localhost"
      write_upsmon_with_upssched "${upsname}@localhost" "admin" "${adminpass}" "master"
      ;;
    snmp)
      upstype="snmp"
      apt_install_if_missing nut-snmp
      upsname="$(ui_input "UPS name (identifier in NUT config; e.g., myups)" "myups")" || return 0
      local ip community
      ip="$(ui_input "UPS IP address" "192.168.1.50")" || return 0
      community="$(ui_input "SNMP community (v2c)" "public")" || return 0
      upsdesc="$(ui_input "UPS description (optional)" "Proxmox UPS (SNMP)")" || return 0

      backup_file /etc/nut/nut.conf
      backup_file /etc/nut/ups.conf
      backup_file /etc/nut/upsd.users
      backup_file /etc/nut/upsmon.conf

      mkdir -p /etc/nut
      cat > /etc/nut/nut.conf <<EOF
# Generated by proxmox-ups-wizard.sh
MODE=standalone
EOF
      cat > /etc/nut/ups.conf <<EOF
# Generated by proxmox-ups-wizard.sh
maxretry = 3

[${upsname}]
  driver = snmp-ups
  port = ${ip}
  community = ${community}
  desc = "${upsdesc}"
EOF
      local adminpass
      adminpass="$(ui_input "Create a password for the upsmon user (stored in /etc/nut/upsd.users)" "change-me")" || return 0
      cat > /etc/nut/upsd.users <<EOF
# Generated by proxmox-ups-wizard.sh
[admin]
  password = ${adminpass}
  actions = SET
  instcmds = ALL
  upsmon master
EOF
      UPS_IDENTIFIER="${upsname}@localhost"
      write_upsmon_with_upssched "${upsname}@localhost" "admin" "${adminpass}" "master"
      ;;
    remote)
      upstype="remote"
      backup_file /etc/nut/nut.conf
      backup_file /etc/nut/upsmon.conf
      mkdir -p /etc/nut
      cat > /etc/nut/nut.conf <<EOF
# Generated by proxmox-ups-wizard.sh
MODE=netclient
EOF
      local upsmon_target user pass
      upsmon_target="$(ui_input "Remote MONITOR target (format: upsname@ip-or-host)" "ups@192.168.1.100")" || return 0
      user="$(ui_input "Remote upsmon username" "monuser")" || return 0
      pass="$(ui_input "Remote upsmon password" "secret")" || return 0
      UPS_IDENTIFIER="$upsmon_target"
      write_upsmon_with_upssched "$upsmon_target" "$user" "$pass" "slave"
      ;;
    *)
      return 0
      ;;
  esac

  ui_msg "NUT connection configured.\n\nNext: Configure upssched timer and VM/CT priorities."
}

write_upsmon_with_upssched() {
  local monitor_target="$1" user="$2" pass="$3" role="$4"

  # Use upssched as NOTIFYCMD (recommended by NUT docs)
  local upssched_path
  upssched_path="$(command -v upssched 2>/dev/null || true)"
  if [[ -z "$upssched_path" ]]; then
    ui_msg "upssched not found. Is nut-client installed?"
    return 1
  fi

  backup_file /etc/nut/upsmon.conf
  cat > /etc/nut/upsmon.conf <<EOF
# Generated by proxmox-ups-wizard.sh
MONITOR ${monitor_target} 1 ${user} ${pass} ${role}
MINSUPPLIES 1

# Use upssched for timer/cancel logic:
NOTIFYCMD ${upssched_path}
NOTIFYFLAG ONBATT EXEC
NOTIFYFLAG ONLINE EXEC
NOTIFYFLAG LOWBATT EXEC
NOTIFYFLAG COMMBAD EXEC
NOTIFYFLAG COMMOK EXEC

# Tuning (reasonable defaults)
POLLFREQ 5
POLLFREQALERT 5
HOSTSYNC 15
DEADTIME 15
POWERDOWNFLAG /etc/killpower
RBWARNTIME 43200
NOCOMMWARNTIME 300
EOF
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
# Generated by proxmox-ups-wizard.sh
CMDSCRIPT ${UPSSCHED_CMD_DST}
PIPEFN /run/nut/upssched.pipe
LOCKFN /run/nut/upssched.lock

# Start a timer on battery; cancel if power returns.
AT ONBATT * START-TIMER onbatt ${seconds}
AT ONLINE * CANCEL-TIMER onbatt

# If battery is low, shutdown immediately.
AT LOWBATT * EXECUTE lowbatt

# Optional comm events
AT COMMBAD * EXECUTE commbad
AT COMMOK  * EXECUTE commok
EOF

  cat > "$UPSSCHED_CMD_DST" <<'EOF'
#!/usr/bin/env bash
# Called by upssched. Argument is the action name from upssched.conf.
set -u

SCRIPT="/usr/local/sbin/proxmox-shutdown.sh"

log() { echo "PVE-UPS: upssched-cmd: $*" | tee >(logger -t "PVE-UPS"); }

case "${1:-}" in
  onbatt)
    log "onbatt timer expired -> starting shutdown sequence"
    exec "$SCRIPT" --no-wait --event "onbatt-timer"
    ;;
  lowbatt)
    log "low battery -> starting immediate shutdown sequence"
    exec "$SCRIPT" --no-wait --event "lowbatt"
    ;;
  commbad)
    log "UPS communication lost -> running shutdown (policy: proceed)"
    exec "$SCRIPT" --no-wait --event "commbad"
    ;;
  commok)
    log "UPS communication restored"
    exit 0
    ;;
  *)
    log "Unknown upssched action: ${1:-<empty>}"
    exit 0
    ;;
esac
EOF
  chmod 0755 "$UPSSCHED_CMD_DST"

  save_config

  ui_msg "upssched configured.\n\nRestart NUT services:\n  systemctl restart nut-server nut-client\n\nTest (no changes):\n  ${SHUTDOWN_SCRIPT_DST} --plan\n  ${SHUTDOWN_SCRIPT_DST} --test --simulate --no-wait"
}


show_layers_help() {
  ui_msg "How layers work (priorities)\n\n\
This toolkit shuts down guests in PRIORITY order:\n\
  - Lower number = shut down earlier (less important)\n\
  - Higher number = shut down later (more important)\n\n\
Think of it as layers:\n\
  10  = Dev/Test / non-critical\n\
  50  = App servers\n\
  90  = Core services (storage, auth, DNS, DB)\n\n\
Tips:\n\
  • Give dependent services higher priority than what depends on them.\n\
    Example: shut down app servers BEFORE databases/storage.\n\
  • Use 'shutdown' for graceful stop. Use 'stop' only if needed.\n\
  • For VMs you can choose 'hibernate' (suspend to disk) if it works for that guest.\n\n\
You can preview the exact order any time with:\n\
  /usr/local/sbin/proxmox-shutdown.sh --plan"
}

restart_nut_services() {
  # On netclient installs, nut-server may be disabled; restart anyway if present.
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl restart nut-client >/dev/null 2>&1 || true
  systemctl restart nut-server >/dev/null 2>&1 || true
  systemctl enable nut-client >/dev/null 2>&1 || true
  systemctl enable nut-server >/dev/null 2>&1 || true
  ui_msg "Restarted/enabled NUT services (nut-client/nut-server)."
}

# ------------------------------
# Priorities wizard
# ------------------------------
configure_priorities() {
  load_config

  DEFAULT_VM_PRIORITY="$(ui_input "Default VM priority (lower=shutdown earlier)" "$DEFAULT_VM_PRIORITY")" || return 0
  DEFAULT_CT_PRIORITY="$(ui_input "Default CT priority (lower=shutdown earlier)" "$DEFAULT_CT_PRIORITY")" || return 0
  DEFAULT_VM_ACTION="$(ui_menu "Default VM action" \
    "shutdown" "shutdown (recommended)" \
    "hibernate" "hibernate (suspend to disk)" \
    "stop" "stop (force off; not graceful)" \
  )" || return 0
  DEFAULT_CT_ACTION="$(ui_menu "Default CT action" \
    "shutdown" "shutdown (recommended)" \
    "stop" "stop (force off; not graceful)" \
  )" || return 0

  show_layers_help


  while true; do
    local menu_items=()
    menu_items+=("save" "Save and return to main menu")
    menu_items+=("plan" "Show current shutdown plan")
    menu_items+=("help" "Explain layers/priorities")
    menu_items+=("exit" "Exit without saving")

    # Add VMs
    while IFS=$'\t' read -r id name status; do
      [[ -z "$id" ]] && continue
      local p="${VM_PRIORITY[$id]:-$DEFAULT_VM_PRIORITY}"
      local a="${VM_ACTIONS[$id]:-$DEFAULT_VM_ACTION}"
      menu_items+=("vm:$id" "VM $id ($name) status=$status  prio=$p action=$a")
    done < <(list_vms)

    # Add CTs
    while IFS=$'\t' read -r id name status; do
      [[ -z "$id" ]] && continue
      local p="${CT_PRIORITY[$id]:-$DEFAULT_CT_PRIORITY}"
      local a="${CT_ACTIONS[$id]:-$DEFAULT_CT_ACTION}"
      menu_items+=("ct:$id" "CT $id ($name) status=$status  prio=$p action=$a")
    done < <(list_cts)

    local choice
    choice="$(ui_menu "Select a guest to set priority/action" "${menu_items[@]}")" || return 0

    case "$choice" in
      save)
        save_config
        return 0
        ;;
      plan)
        ui_msg "$(${SHUTDOWN_SCRIPT_DST} --plan 2>/dev/null || echo "Install shutdown script first.")"
        ;;
      help)
        show_layers_help
        ;;
      X)
        return 0
        ;;
      vm:*)
        local id="${choice#vm:}"
        local curp="${VM_PRIORITY[$id]:-$DEFAULT_VM_PRIORITY}"
        local cura="${VM_ACTIONS[$id]:-$DEFAULT_VM_ACTION}"
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
        local curp="${CT_PRIORITY[$id]:-$DEFAULT_CT_PRIORITY}"
        local cura="${CT_ACTIONS[$id]:-$DEFAULT_CT_ACTION}"
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

# ------------------------------
# Main menu
# ------------------------------

guided_setup() {
  need_root
  ui_msg "Guided setup\n\nThis will walk you through Step 1 → Step 5."

  ui_msg "Step 1/5: Install/Update shutdown script"
  install_prereqs
  write_shutdown_script || true

  ui_msg "Step 2/5: Configure UPS connection (NUT)"
  configure_nut_connection

  ui_msg "Step 3/5: Configure on-battery timer (upssched)"
  configure_upssched_timer

  ui_msg "Step 4/5: Configure VM/CT layers (priorities/actions)"
  show_layers_help
  configure_priorities

  ui_msg "Step 5/5: Restart & enable NUT services"
  restart_nut_services

  ui_msg "Setup complete.\n\nSuggested next steps:\n  • Show plan: /usr/local/sbin/proxmox-shutdown.sh --plan\n  • Test run:   /usr/local/sbin/proxmox-shutdown.sh --test --simulate --no-wait"
}


main_menu() {
  need_root
  load_config

  while true; do
    local choice
    choice="$(ui_menu "Main menu" \
      "G"  "Guided setup (run steps 1→5)" \
      "1"  "Install/Update shutdown script" \
      "2"  "Configure UPS connection (NUT)" \
      "3"  "Configure on-battery timer (upssched)" \
      "4"  "Configure VM/CT layers (priorities/actions)" \
      "5"  "Restart/Enable NUT services" \
      "H"  "Explain how layers/priorities work" \
      "T"  "Run TEST (shows plan + output; no changes)" \
      "X"  "Exit" \
    )" || exit 0

    case "$choice" in
      1)
        install_prereqs
        write_shutdown_script
        ;;
      2)
        configure_nut_connection
        ;;
      3)
        configure_upssched_timer
        ;;
      4)
        configure_priorities
        ;;
      5)
        restart_nut_services
        ;;
      T)
        install_prereqs
        write_shutdown_script >/dev/null 2>&1 || true

        tmp="$(mktemp /tmp/pve-ups-test.XXXXXX)"
        {
          echo "=== Current shutdown plan ==="
          echo
          /usr/local/sbin/proxmox-shutdown.sh --plan 2>/dev/null || true
          echo
          echo "=== Running TEST (no changes) ==="
          echo "Command: /usr/local/sbin/proxmox-shutdown.sh --test --simulate --no-wait"
          echo
          /usr/local/sbin/proxmox-shutdown.sh --test --simulate --no-wait 2>&1 || true
          echo
          echo "Done. Nothing was shut down because this was TEST mode."
        } > "$tmp"

        if [[ "$UI" == "whiptail" ]]; then
          whiptail --title "Test results" --scrolltext --textbox "$tmp" 24 92
        elif [[ "$UI" == "dialog" ]]; then
          dialog --title "Test results" --textbox "$tmp" 24 92
        else
          cat "$tmp"
          echo
          read -r -p "Press Enter to continue..."
        fi
        rm -f "$tmp"
        ;;
      X)
        exit 0
        ;;
    esac
  done
}

main_menu
