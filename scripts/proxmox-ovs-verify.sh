#!/usr/bin/env bash
#
# Read-only diagnostic for a Proxmox VE node's networking: prints OVS
# bridge/port/bond state, cluster quorum (if clustered), and current IP
# config. Safe to run anytime -- makes no changes. Useful before/after
# running proxmox-ovs-migrate.sh, or as a standalone health check.
#
# Usage (run as root on the PVE node):
#   curl -fsSL <raw-url>/scripts/proxmox-ovs-verify.sh | bash
#   wget -qO- <raw-url>/scripts/proxmox-ovs-verify.sh | bash
#
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Error: must run as root." >&2
  exit 1
fi

if ! command -v pvesh >/dev/null 2>&1; then
  echo "Error: pvesh not found - this script must run on a Proxmox VE node." >&2
  exit 1
fi

NODE=$(hostname)
if ! pvesh get "/nodes/$NODE" >/dev/null 2>&1; then
  NODE=$(pvesh get /nodes --output-format=json | grep -oP '"node":"\K[^"]+' | head -n1)
fi

echo "==> Proxmox node: $NODE"

echo
echo "==> Open vSwitch:"
if command -v ovs-vsctl >/dev/null 2>&1; then
  ovs-vsctl show || echo "    (ovs-vsctl show failed - is openvswitch-switch running?)"
else
  echo "    openvswitch-switch is not installed."
fi

echo
echo "==> IP addresses:"
ip -o -4 addr show | awk '{print "    "$2": "$4}'

echo
echo "==> Default route:"
ip -o route show default | sed 's/^/    /' || echo "    (none)"

echo
if [ -f /etc/pve/corosync.conf ]; then
  echo "==> Cluster / corosync:"
  pvecm status 2>&1 | sed 's/^/    /' || echo "    pvecm status failed"
else
  echo "==> Not part of a cluster (no /etc/pve/corosync.conf)."
fi

echo
echo "==> Proxmox network config (pvesh):"
pvesh get "/nodes/$NODE/network" --output-format=json \
  | grep -oP '"iface":"\K[^"]+' \
  | while read -r iface; do
      type=$(pvesh get "/nodes/$NODE/network/$iface" --output-format=json | grep -oP '"type":"\K[^"]+')
      printf '    %-12s %s\n' "$iface" "$type"
    done

LATEST_BACKUP_DIR="/root/proxmox-ovs-migrate-backups/latest"
if [ -L "$LATEST_BACKUP_DIR" ]; then
  echo
  echo "==> Most recent proxmox-ovs-migrate.sh backup: $(readlink -f "$LATEST_BACKUP_DIR")"
  for marker in .armed .confirmed; do
    [ -f "$LATEST_BACKUP_DIR/$marker" ] && echo "    status: $marker"
  done
  find "$LATEST_BACKUP_DIR" -maxdepth 1 -name '.rollback-executed-*' -printf '    status: %f\n' 2>/dev/null || true
fi

echo
echo "==> Done."
