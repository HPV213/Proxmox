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
