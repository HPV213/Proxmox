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

## Hostname check / rename

`scripts/proxmox-hostname-check.sh` checks that a node's hostname is configured
correctly (based on <https://pve.proxmox.com/wiki/Renaming_a_PVE_node>):
`/etc/hostname`, `/etc/hosts` (must map to the real IP, not loopback),
`/etc/mailname`, postfix, `pve-cluster`, `/etc/pve/nodes/*`, corosync and RRD data.

```sh
bash proxmox-hostname-check.sh                  # check only
bash proxmox-hostname-check.sh --rename NEW     # edit files (with .bak-rename backups), then reboot
bash proxmox-hostname-check.sh --cleanup        # after reboot: move old node dir + RRD to new name
```

`--rename` refuses clustered nodes or nodes with VM/CT configs unless `--force` is given.
