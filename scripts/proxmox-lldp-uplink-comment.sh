#!/usr/bin/env bash
#
# Detect the upstream switch (name + port) for each physical NIC on a
# Proxmox VE node via LLDP, and write it into that interface's "Comment"
# field as "{switch}-{port}" using the Proxmox network API.
#
# Usage (run as root on the PVE node):
#   curl -fsSL <raw-url>/scripts/proxmox-lldp-uplink-comment.sh | bash
#   wget -qO- <raw-url>/scripts/proxmox-lldp-uplink-comment.sh | bash
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

# hostname usually matches the PVE node id, but fall back to querying the
# API in case the local hostname was set up differently from the node id.
NODE=$(hostname)
if ! pvesh get "/nodes/$NODE" >/dev/null 2>&1; then
  NODE=$(pvesh get /nodes --output-format=json | grep -oP '"node":"\K[^"]+' | head -n1)
fi

echo "==> Proxmox node: $NODE"

if ! command -v lldpcli >/dev/null 2>&1; then
  echo "==> Installing lldpd..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y lldpd >/dev/null
fi

systemctl enable --now lldpd >/dev/null 2>&1 || systemctl restart lldpd

# Switches commonly transmit LLDPDUs every 30s, so poll for a while before
# giving up on a given interface.
echo "==> Waiting for LLDP neighbors (up to 60s)..."
NEIGHBORS=""
for _ in $(seq 1 12); do
  NEIGHBORS=$(lldpcli show neighbors -f keyvalue 2>/dev/null || true)
  [ -n "$NEIGHBORS" ] && break
  sleep 5
done

if [ -z "$NEIGHBORS" ]; then
  echo "No LLDP neighbors found. Make sure LLDP is enabled on the switch side and re-run." >&2
  exit 1
fi

declare -A SW_NAME SW_PORT

while IFS='=' read -r k v; do
  iface="${k#lldp.}"
  iface="${iface%%.*}"
  case "$k" in
    lldp.*.chassis.name) SW_NAME["$iface"]="$v" ;;
    lldp.*.port.ifname) SW_PORT["$iface"]="$v" ;;
    lldp.*.port.id) [ -z "${SW_PORT[$iface]:-}" ] && SW_PORT["$iface"]="$v" ;;
  esac
done <<< "$NEIGHBORS"

if [ "${#SW_NAME[@]}" -eq 0 ]; then
  echo "LLDP data received, but no chassis name was found." >&2
  exit 1
fi

CHANGED=0
for iface in "${!SW_NAME[@]}"; do
  sw="${SW_NAME[$iface]}"
  port="${SW_PORT[$iface]:-unknown}"
  comment="${sw}-${port}"

  if ! pvesh get "/nodes/$NODE/network/$iface" >/dev/null 2>&1; then
    echo "Skip $iface: not defined in Proxmox network config."
    continue
  fi

  echo "==> $iface -> \"$comment\""
  pvesh set "/nodes/$NODE/network/$iface" -comments "$comment"
  CHANGED=1
done

if [ "$CHANGED" -eq 1 ]; then
  echo "==> Applying network configuration..."
  pvesh set "/nodes/$NODE/network"
fi

echo "==> Done."
