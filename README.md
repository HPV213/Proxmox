# Proxmox

## LLDP uplink port commenter

`scripts/proxmox-lldp-uplink-comment.sh` runs on a Proxmox VE node, installs
`lldpd` if needed, discovers the upstream switch name/port for each physical
NIC via LLDP, and writes `{switch}-{port}` into that interface's Comment
field (via `pvesh`), then applies the network config.

Run as root on the node:

```sh
curl -fsSL https://raw.githubusercontent.com/HPV213/Proxmox/main/scripts/proxmox-lldp-uplink-comment.sh | bash
```

or

```sh
wget -qO- https://raw.githubusercontent.com/HPV213/Proxmox/main/scripts/proxmox-lldp-uplink-comment.sh | bash
```

## Hostname check / fix / rename

`scripts/proxmox-hostname-check.sh` checks, repairs and renames a PVE node
(based on <https://pve.proxmox.com/wiki/Renaming_a_PVE_node>). Run as root on the node.

```sh
# check only (read-only)
curl -fsSL https://raw.githubusercontent.com/HPV213/Proxmox/main/scripts/proxmox-hostname-check.sh | bash

# you already renamed by hand: move old node dir (VM/CT configs) + RRD, fix postfix
curl -fsSL https://raw.githubusercontent.com/HPV213/Proxmox/main/scripts/proxmox-hostname-check.sh | bash -s -- --fix

# fully automatic rename, no reboot needed
curl -fsSL https://raw.githubusercontent.com/HPV213/Proxmox/main/scripts/proxmox-hostname-check.sh | bash -s -- --rename NEWNAME
```

Options: `--old NAME` (with `--fix`), `--force` (clustered node / node with guests), `-y` (no prompts).
`--rename` backs up to `/root/pve-rename-backup-<timestamp>`, edits `/etc/hostname`, `/etc/hosts`,
`/etc/mailname`, `/etc/postfix/main.cf`, restarts the PVE services, moves guest configs and RRD data.
On any failure a detailed ERROR REPORT is printed at the end, ready to copy and paste.
