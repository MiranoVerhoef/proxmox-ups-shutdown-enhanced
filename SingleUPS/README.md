# Proxmox-UPS-Toolkit-SingleUPS (V0.4)

# Proxmox UPS Toolkit (NUT) – layered guest shutdown + wizard (whiptail)

## Files
- `proxmox-shutdown-advanced.sh` → installs to `/usr/local/sbin/proxmox-shutdown.sh`
- `proxmox-ups-wizard.sh` → run with `sudo ./proxmox-ups-wizard.sh`
- `proxmox-ups-monitor.sh` → UPS status logger (systemd timer)

## Logging
- Action log: `/var/log/proxmox-ups-toolkit/actions-YYYY-MM-DD.log`
- Status log: `/var/log/proxmox-ups-toolkit/status-YYYY-MM-DD.log`
- Retention: 7 days (auto-cleanup)

UPS status logger timer (default):
- runs every **15 seconds** via `proxmox-ups-monitor.timer`


## UI
This build is **whiptail-only**.


## UPS Connection Check
Use the main menu option **6** to query `upsc` and show status, charge, runtime and load.
