#!/usr/bin/env bash
#
# Detect the upstream switch (name + port) for each physical NIC on a
# Proxmox VE node via LLDP, and write it into that interface's "Comment"
# field as "{switch}-{port}" using the Proxmox network API.
#
# Any physical NIC that is administratively down is brought up first, so
# that a port actually cabled to a switch has a chance to exchange LLDP
# before we give up on it. At the end a status table is printed, including
# any port that is still link-down or received no LLDP data.
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

# Only consider real hardware NICs (they have a "device" symlink in sysfs).
# This excludes vmbrX/bondX/veth/fwln/fwpr/tap etc, which can otherwise show
# up as bogus LLDP "neighbors" because a Linux bridge floods LLDP's
# multicast frames to every port, including VM-facing veth pairs.
PHYS_IFACES=()
for p in /sys/class/net/*; do
  iface="$(basename "$p")"
  [ -e "$p/device" ] && PHYS_IFACES+=("$iface")
done

if [ "${#PHYS_IFACES[@]}" -eq 0 ]; then
  echo "Error: no physical NICs found under /sys/class/net." >&2
  exit 1
fi

echo "==> Physical NICs: ${PHYS_IFACES[*]}"

echo "==> Enabling any administratively-down physical ports..."
for iface in "${PHYS_IFACES[@]}"; do
  if ! ip link show "$iface" | head -n1 | grep -q '<.*UP.*>'; then
    echo "    $iface was down, bringing it up"
    ip link set dev "$iface" up || true
  fi
done

if ! command -v lldpcli >/dev/null 2>&1; then
  echo "==> Installing lldpd..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y lldpd >/dev/null
fi

systemctl enable --now lldpd >/dev/null 2>&1 || systemctl restart lldpd

# Switches commonly transmit LLDPDUs every 30s, and a port that was just
# brought up may sit in STP listening/learning state for a while before it
# forwards frames, so poll for a good while before giving up.
echo "==> Waiting for LLDP neighbors (up to 90s)..."
NEIGHBORS=""
for _ in $(seq 1 18); do
  NEIGHBORS=$(lldpcli show neighbors -f keyvalue 2>/dev/null || true)
  [ -n "$NEIGHBORS" ] && break
  sleep 5
done

# Cisco IOS-style abbreviations, applied to the port name reported by the
# neighbor so comments stay short and use a naming convention network
# admins already recognize (Gi0/1, Te1/1, Eth1/27, Po1, ...).
shorten_port_name() {
  sed -E \
    -e 's/^HundredGig(abitEthernet|E)?/Hu/I' \
    -e 's/^FortyGig(abitEthernet|E)?/Fo/I' \
    -e 's/^TwentyFiveGig(abitEthernet|E)?/Twe/I' \
    -e 's/^TenGig(abitEthernet|E)?/Te/I' \
    -e 's/^Gigabit ?Ethernet|^GigE/Gi/I' \
    -e 's/^FastEthernet/Fa/I' \
    -e 's/^Port-?[Cc]hannel/Po/I' \
    -e 's/^Management/Mgmt/I' \
    -e 's/^Ethernet/Eth/I' \
    <<< "$1"
}

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

declare -A STATUS
CHANGED=0

for iface in "${PHYS_IFACES[@]}"; do
  if [ -z "${SW_NAME[$iface]:-}" ]; then
    carrier=$(cat "/sys/class/net/$iface/carrier" 2>/dev/null || echo 0)
    if [ "$carrier" = "1" ]; then
      STATUS["$iface"]="link up, no LLDP data"
    else
      STATUS["$iface"]="link down"
    fi
    continue
  fi

  if ! pvesh get "/nodes/$NODE/network/$iface" >/dev/null 2>&1; then
    STATUS["$iface"]="LLDP neighbor found, but not defined in Proxmox network config"
    continue
  fi

  sw="${SW_NAME[$iface]}"
  port="$(shorten_port_name "${SW_PORT[$iface]:-unknown}")"
  comment="${sw}-${port}"
  type="$(pvesh get "/nodes/$NODE/network/$iface" --output-format=json | grep -oP '"type":"\K[^"]+')"

  echo "==> $iface -> \"$comment\""
  pvesh set "/nodes/$NODE/network/$iface" -type "$type" -comments "$comment"
  STATUS["$iface"]="comment set: $comment"
  CHANGED=1
done

if [ "$CHANGED" -eq 1 ]; then
  echo "==> Applying network configuration..."
  pvesh set "/nodes/$NODE/network"
fi

echo
echo "==> Final port status:"
printf '%-12s %s\n' "IFACE" "STATUS"
for iface in "${PHYS_IFACES[@]}"; do
  printf '%-12s %s\n' "$iface" "${STATUS[$iface]:-unknown}"
done

echo "==> Done."
