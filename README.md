# Proxmox UPS Toolkit (NUT) – layered guest shutdown + setup wizard

This toolkit builds on `proxmox-shutdown.sh` (jordanmack/proxmox-ups-shutdown) and adds:

- **Layered shutdown ordering** (least important first) via per-VM/CT priorities.
- **Test mode** (`--test`) and **plan preview** (`--plan`).
- **upssched timer integration** (start shutdown after N seconds on battery; cancel on power return).
- A **TUI wizard** (whiptail/dialog) to install NUT, configure UPS connection, and configure priorities.

## Files

- `proxmox-shutdown-advanced.sh` – install to `/usr/local/sbin/proxmox-shutdown.sh`
- `proxmox-ups-wizard.sh` – run as root: `sudo ./proxmox-ups-wizard.sh`

## Quick start (recommended)

1) Copy both scripts to your Proxmox host, then:

```bash
chmod +x proxmox-ups-wizard.sh proxmox-shutdown-advanced.sh
sudo ./proxmox-ups-wizard.sh
```

2) In the wizard:
- Install/update the shutdown script
- Configure NUT connection (USB / SNMP / Remote)
- Configure upssched timer
- Configure VM/CT priorities
- Restart services

3) Test (no changes):

```bash
/usr/local/sbin/proxmox-shutdown.sh --plan
/usr/local/sbin/proxmox-shutdown.sh --test --simulate --no-wait
```

## How layering works

Set priorities per guest:
- **Lower number = shutdown earlier** (less important).
- **Higher number = shutdown later** (more important).

Example:
- priority 10: dev/test VMs
- priority 50: apps
- priority 90: storage/auth/core services

## Where config is stored

- Shutdown orchestrator config: `/etc/proxmox-ups-shutdown.conf`
- NUT config: `/etc/nut/*`
