#!/usr/bin/env bash
#
# Migrate a Proxmox VE node's MANAGEMENT bridge (the one carrying the IP
# this very SSH session is using, which on a clustered node is normally
# also the corosync ring address) from a Linux bridge to Open vSwitch.
#
# This is a high-risk, hard-to-reverse-if-wrong change: a bad network
# config can lock you out of a node that has no console/IPMI access. So
# this script:
#   - only ever touches the ONE bridge carrying the current SSH session's
#     IP (never touches other, VM-only vmbr's -- migrate those manually,
#     later, once you trust this script)
#   - refuses to run unless it can confidently classify the current setup
#     (single NIC or a Linux bond in a mode with a clean OVS equivalent,
#     static IP, no VLAN tagging already in play, no cluster SDN zones)
#   - stages the change via the Proxmox API without applying it, so you
#     can review a real diff first (--dry-run, the default)
#   - when actually applying (--apply), arms an unattended rollback timer
#     BEFORE touching the network, and only cancels it if you explicitly
#     confirm from a SEPARATE session after verifying connectivity
#
# This script is deliberately NOT meant to be curl|bash'd -- download it,
# read it, then run it from a local copy:
#   ./proxmox-ovs-migrate.sh --dry-run
#   ./proxmox-ovs-migrate.sh --apply --rollback-after=15
#   ./proxmox-ovs-migrate.sh --confirm --backup-dir=<path from the apply output>
#
# See docs/ovs-migration-runbook.md for the full pre-flight checklist and
# multi-node cluster rollout sequence.
#
set -euo pipefail
shopt -s nullglob

SELF=/usr/local/sbin/proxmox-ovs-migrate.sh
BACKUP_ROOT=/root/proxmox-ovs-migrate-backups
LOG=/var/log/proxmox-ovs-migrate.log

log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*" | tee -a "$LOG" >&2; }
bail() { echo "Error: $*" >&2; echo "No changes have been made." >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: proxmox-ovs-migrate.sh [ACTION] [OPTIONS]

Actions (default: --dry-run):
  --dry-run              Stage the OVS config, show a diff, revert pending. Safe, no changes.
  --apply                Actually apply. Arms an auto-rollback timer first.
  --confirm              Cancel the pending auto-rollback for an applied migration.
  --abort-now            Roll back immediately instead of waiting for the timer.
  --status               Read-only report on any in-flight migration.
  --rollback-execute      (internal, invoked by the rollback timer)

Options:
  --yes                  Skip the pre-apply confirmation prompt.
  --rollback-after=N     Minutes before auto-rollback fires if unconfirmed. Default 15 (5-60).
  --backup-dir=PATH      Target a specific migration for --confirm/--abort-now/--status.
                         Defaults to the most recent one.
  --simple               Put the IP directly on the OVSBridge (old 1:1 layout) instead of
                         the default VLAN-aware OVSBridge+OVSIntPort layout.
  --mgmt-vlan=N          Tag the management OVSIntPort with VLAN N (default: untagged).
EOF
}

# ---------------------------------------------------------------------------
# Arg parsing
# ---------------------------------------------------------------------------
ACTION="dry-run"
YES=0
ROLLBACK_MIN=15
BACKUP_DIR=""
SIMPLE=0
MGMT_VLAN=""

for arg in "$@"; do
  case "$arg" in
    --dry-run) ACTION="dry-run" ;;
    --apply) ACTION="apply" ;;
    --confirm) ACTION="confirm" ;;
    --abort-now) ACTION="abort-now" ;;
    --status) ACTION="status" ;;
    --rollback-execute) ACTION="rollback-execute" ;;
    --yes) YES=1 ;;
    --rollback-after=*) ROLLBACK_MIN="${arg#*=}" ;;
    --backup-dir=*) BACKUP_DIR="${arg#*=}" ;;
    --simple) SIMPLE=1 ;;
    --mgmt-vlan=*) MGMT_VLAN="${arg#*=}" ;;
    -h|--help) usage; exit 0 ;;
    *) bail "unknown argument: $arg (see --help)" ;;
  esac
done

if [ "$ACTION" = "apply" ] && { [ "$ROLLBACK_MIN" -lt 5 ] || [ "$ROLLBACK_MIN" -gt 60 ]; } 2>/dev/null; then
  bail "--rollback-after must be between 5 and 60 minutes."
fi

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || bail "must run as root."
command -v pvesh >/dev/null 2>&1 || bail "pvesh not found - this must run on a Proxmox VE node."
command -v ifreload >/dev/null 2>&1 || bail "ifreload not found - this node isn't using ifupdown2, unsupported."

NODE=$(hostname)
if ! pvesh get "/nodes/$NODE" >/dev/null 2>&1; then
  NODE=$(pvesh get /nodes --output-format=json | grep -oP '"node":"\K[^"]+' | head -n1)
fi

mkdir -p "$BACKUP_ROOT"
[ -z "$BACKUP_DIR" ] && [ -L "$BACKUP_ROOT/latest" ] && BACKUP_DIR="$(readlink -f "$BACKUP_ROOT/latest")"

# ---------------------------------------------------------------------------
# Actions that operate on an EXISTING backup dir (no discovery needed)
# ---------------------------------------------------------------------------
do_rollback_execute() {
  if [ -z "$BACKUP_DIR" ] || [ ! -d "$BACKUP_DIR" ]; then bail "no backup dir to roll back (--backup-dir)."; fi
  if [ -f "$BACKUP_DIR/.confirmed" ]; then log "rollback-execute: $BACKUP_DIR already confirmed, no-op."; exit 0; fi
  if [ ! -f "$BACKUP_DIR/.armed" ]; then log "rollback-execute: $BACKUP_DIR not armed, no-op."; exit 0; fi

  log "ROLLING BACK using $BACKUP_DIR"
  pvesh delete "/nodes/$NODE/network" >/dev/null 2>&1 || true
  cp -a "$BACKUP_DIR/interfaces.orig" /etc/network/interfaces
  if [ -d "$BACKUP_DIR/interfaces.d.orig" ]; then
    mkdir -p /etc/network/interfaces.d
    rsync -a --delete "$BACKUP_DIR/interfaces.d.orig/" /etc/network/interfaces.d/
  fi
  ifreload -a
  mv "$BACKUP_DIR/.armed" "$BACKUP_DIR/.rollback-executed-$(date -u +%Y%m%dT%H%M%SZ)"
  log "Rollback complete. Original network config restored."
}

do_confirm() {
  if [ -z "$BACKUP_DIR" ] || [ ! -d "$BACKUP_DIR" ]; then bail "no backup dir to confirm (--backup-dir)."; fi
  [ -f "$BACKUP_DIR/.armed" ] || bail "no armed migration at $BACKUP_DIR."
  systemctl stop pve-ovs-rollback.timer 2>/dev/null || true
  systemctl stop pve-ovs-rollback 2>/dev/null || true
  mv "$BACKUP_DIR/.armed" "$BACKUP_DIR/.confirmed"
  log "Confirmed $BACKUP_DIR. Auto-rollback cancelled."
  echo "==> Confirmed. This migration is now permanent."
}

do_abort_now() {
  if [ -z "$BACKUP_DIR" ] || [ ! -d "$BACKUP_DIR" ]; then bail "no backup dir to abort (--backup-dir)."; fi
  do_rollback_execute
  systemctl stop pve-ovs-rollback.timer 2>/dev/null || true
}

do_status() {
  echo "==> Proxmox node: $NODE"
  local found=0
  for d in "$BACKUP_ROOT"/*/; do
    [ -L "${d%/}" ] && continue   # skip the "latest" symlink, only list real backup dirs
    [ -f "$d/.armed" ] || continue
    found=1
    echo "==> In-flight migration: $d"
    systemctl show pve-ovs-rollback.timer -p NextElapseUSecRealtime 2>/dev/null || true
  done
  [ "$found" -eq 0 ] && echo "==> No in-flight (unconfirmed) migration."
  echo "==> ovs-vsctl show:"
  ovs-vsctl show 2>/dev/null || echo "    (openvswitch-switch not installed or not running)"
  if [ -f /etc/pve/corosync.conf ]; then
    echo "==> pvecm status:"
    pvecm status 2>&1 || true
  fi
}

case "$ACTION" in
  status) do_status; exit 0 ;;
  confirm) do_confirm; exit 0 ;;
  abort-now) do_abort_now; exit 0 ;;
  rollback-execute) do_rollback_execute; exit 0 ;;
esac

# ---------------------------------------------------------------------------
# From here on: --dry-run or --apply, both need full discovery.
# ---------------------------------------------------------------------------

# The whole safety design hinges on knowing, precisely, the IP this operator
# is reaching the box on right now -- SSH_CONNECTION's 3rd field is exactly
# that (client_ip client_port server_ip server_port). Refuse to guess it any
# other way (cron/at/detached shells don't have it, which is deliberate).
[ -n "${SSH_CONNECTION:-}" ] || bail "must run interactively over SSH (need \$SSH_CONNECTION to identify the current management IP)."
CRITICAL_IP="$(awk '{print $3}' <<< "$SSH_CONNECTION")"

echo "==> Proxmox node: $NODE"
echo "==> Current SSH session IP: $CRITICAL_IP"

# Defend against pvesh API field names having drifted on the installed PVE
# version -- fail loudly here rather than send a half-formed OVS config.
USAGE="$(pvesh usage "/nodes/$NODE/network" --verbose 2>&1 || true)"
for f in ovs_ports ovs_bonds ovs_options ovs_bridge type address netmask gateway; do
  grep -q -- "$f" <<< "$USAGE" || bail "pvesh API is missing the expected field '$f' -- verify manually against this PVE version before proceeding."
done

# Never stack a second in-flight migration on top of one that hasn't been
# confirmed or rolled back yet.
for d in "$BACKUP_ROOT"/*/; do
  [ -L "${d%/}" ] && continue   # skip the "latest" symlink, only check real backup dirs
  [ -f "$d/.armed" ] && bail "an unconfirmed migration is already armed at $d -- resolve it first (--confirm or --abort-now)."
done

if [ -d /etc/pve/sdn ] && [ -n "$(find /etc/pve/sdn -mindepth 1 -maxdepth 1 2>/dev/null)" ]; then
  bail "SDN zones are configured under /etc/pve/sdn -- out of scope for this script, migrate manually."
fi

CLUSTERED=0
[ -f /etc/pve/corosync.conf ] && CLUSTERED=1

if [ "$CLUSTERED" -eq 1 ]; then
  get_ring_addr() {
    awk -v n="$NODE" -v key="$1:" '
      /node[ \t]*\{/ { inblock=1; name=""; val="" }
      inblock && $1=="name:" { name=$2 }
      inblock && $1==key { val=$2 }
      inblock && /\}/ { if (name==n) print val; inblock=0 }
    ' /etc/pve/corosync.conf
  }
  RING0="$(get_ring_addr ring0_addr)"
  RING1="$(get_ring_addr ring1_addr)"
  [ -n "$RING1" ] && bail "dual-ring corosync detected (ring1_addr=$RING1) -- too complex for this script, migrate manually."
  if [ -n "$RING0" ] && [ "$RING0" != "$CRITICAL_IP" ]; then
    bail "SSH session IP ($CRITICAL_IP) does not match this node's corosync ring0_addr ($RING0). This script only supports the common case where management and corosync share one bridge -- refusing to guess."
  fi
  echo "==> Cluster detected, corosync ring0_addr matches SSH session IP: OK"
fi

# Physical NIC detection: same convention as proxmox-lldp-uplink-comment.sh.
PHYS_IFACES=()
for p in /sys/class/net/*; do
  iface="$(basename "$p")"
  [ -e "$p/device" ] && PHYS_IFACES+=("$iface")
done
is_phys() { local x; for x in "${PHYS_IFACES[@]}"; do [ "$x" = "$1" ] && return 0; done; return 1; }

mapfile -t ALL_IFACES < <(pvesh get "/nodes/$NODE/network" --output-format=json | grep -oP '"iface":"\K[^"]+')

declare -A IFTYPE IFADDR IFCIDR IFNETMASK IFGW IFBRPORTS IFSLAVES IFBONDMODE IFVLANAWARE
for iface in "${ALL_IFACES[@]}"; do
  json="$(pvesh get "/nodes/$NODE/network/$iface" --output-format=json)"
  IFTYPE["$iface"]="$(grep -oP '"type":"\K[^"]+' <<< "$json" || true)"
  IFADDR["$iface"]="$(grep -oP '"address":"\K[^"]+' <<< "$json" || true)"
  IFCIDR["$iface"]="$(grep -oP '"cidr":"\K[^"]+' <<< "$json" || true)"
  IFNETMASK["$iface"]="$(grep -oP '"netmask":"\K[^"]+' <<< "$json" || true)"
  IFGW["$iface"]="$(grep -oP '"gateway":"\K[^"]+' <<< "$json" || true)"
  IFBRPORTS["$iface"]="$(grep -oP '"bridge_ports":"\K[^"]+' <<< "$json" || true)"
  IFSLAVES["$iface"]="$(grep -oP '"slaves":"\K[^"]+' <<< "$json" || true)"
  IFBONDMODE["$iface"]="$(grep -oP '"bond_mode":"\K[^"]+' <<< "$json" || true)"
  IFVLANAWARE["$iface"]="$(grep -oP '"bridge_vlan_aware":\K[0-9]+' <<< "$json" || echo 0)"
done

# Refuse to touch a host with any half-migrated OVS interface already present.
for iface in "${ALL_IFACES[@]}"; do
  case "${IFTYPE[$iface]}" in
    OVSBridge|OVSPort|OVSBond|OVSIntPort)
      bail "interface $iface is already type ${IFTYPE[$iface]} -- a previous/partial OVS setup exists, refusing to touch it automatically." ;;
  esac
done

# Find the bridge carrying the current SSH session's IP. If none matches,
# the most common reason is a DHCP-addressed management bridge (out of
# scope -- corosync needs a stable IP, convert to static manually first).
MGMT_BRIDGE=""
for iface in "${ALL_IFACES[@]}"; do
  [ "${IFTYPE[$iface]}" = "bridge" ] || continue
  bare="${IFADDR[$iface]%%/*}"
  [ -z "$bare" ] && bare="${IFCIDR[$iface]%%/*}"
  if [ "$bare" = "$CRITICAL_IP" ]; then
    MGMT_BRIDGE="$iface"
    break
  fi
done
[ -n "$MGMT_BRIDGE" ] || bail "no vmbr carries the current SSH IP ($CRITICAL_IP) as a static address. (If this bridge uses DHCP, convert it to a static address first -- corosync/SSH need a stable IP through the cutover.)"

echo "==> Management bridge: $MGMT_BRIDGE"

[ "${IFVLANAWARE[$MGMT_BRIDGE]}" = "1" ] && bail "$MGMT_BRIDGE is already VLAN-aware -- different migration shape, not handled by this script."

BRPORTS="${IFBRPORTS[$MGMT_BRIDGE]}"
[ -n "$BRPORTS" ] || bail "$MGMT_BRIDGE has no bridge_ports set -- nothing to migrate."
read -ra BRPORT_TOKENS <<< "$BRPORTS"

BOND_IFACE=""
NIC_LIST=""
OVS_BOND_OPTS=""

if [ "${#BRPORT_TOKENS[@]}" -eq 1 ] && [ -n "${IFTYPE[${BRPORT_TOKENS[0]}]:-}" ] && [ "${IFTYPE[${BRPORT_TOKENS[0]}]}" = "bond" ]; then
  BOND_IFACE="${BRPORT_TOKENS[0]}"
  NIC_LIST="${IFSLAVES[$BOND_IFACE]}"
  [ -n "$NIC_LIST" ] || bail "bond $BOND_IFACE has no slaves configured."
  for n in $NIC_LIST; do is_phys "$n" || bail "bond slave $n is not a physical NIC -- unexpected topology, refusing."; done
  case "${IFBONDMODE[$BOND_IFACE]}" in
    802.3ad) OVS_BOND_OPTS="bond_mode=balance-tcp lacp=active other_config:lacp-time=fast" ;;
    active-backup) OVS_BOND_OPTS="bond_mode=active-backup" ;;
    balance-xor) OVS_BOND_OPTS="bond_mode=balance-slb" ;;
    *) bail "bond $BOND_IFACE mode '${IFBONDMODE[$BOND_IFACE]}' has no clean OVS equivalent (only 802.3ad, active-backup, balance-xor are supported)." ;;
  esac
  echo "==> Bond: $BOND_IFACE (mode ${IFBONDMODE[$BOND_IFACE]} -> $OVS_BOND_OPTS), slaves: $NIC_LIST"
elif [ "${#BRPORT_TOKENS[@]}" -eq 1 ] && is_phys "${BRPORT_TOKENS[0]}"; then
  NIC_LIST="${BRPORT_TOKENS[0]}"
  echo "==> Single physical NIC: $NIC_LIST"
else
  bail "$MGMT_BRIDGE's bridge_ports ('$BRPORTS') is not a single physical NIC or a single Linux bond -- ambiguous, define a real bond first if that's the intent."
fi

for n in $NIC_LIST; do
  [[ "$n" == *.* ]] && bail "$n looks like a VLAN sub-interface -- tagged trunking already in play on the mgmt path, not handled by this script."
done

# IP: prefer the combined "cidr" field if present, else address + netmask.
netmask_to_prefix() {
  local mask="$1" prefix=0 o1 o2 o3 o4 octet
  IFS='.' read -r o1 o2 o3 o4 <<< "$mask"
  for octet in "$o1" "$o2" "$o3" "$o4"; do
    case "$octet" in
      255) prefix=$((prefix+8));; 254) prefix=$((prefix+7));; 252) prefix=$((prefix+6));;
      248) prefix=$((prefix+5));; 240) prefix=$((prefix+4));; 224) prefix=$((prefix+3));;
      192) prefix=$((prefix+2));; 128) prefix=$((prefix+1));; 0) prefix=$((prefix+0));;
      *) return 1 ;;
    esac
  done
  echo "$prefix"
}

IP_BARE="$CRITICAL_IP"
if [ -n "${IFCIDR[$MGMT_BRIDGE]}" ]; then
  IP_PREFIX="${IFCIDR[$MGMT_BRIDGE]#*/}"
elif [[ "${IFADDR[$MGMT_BRIDGE]}" == */* ]]; then
  IP_PREFIX="${IFADDR[$MGMT_BRIDGE]#*/}"
elif [ -n "${IFNETMASK[$MGMT_BRIDGE]}" ]; then
  if [[ "${IFNETMASK[$MGMT_BRIDGE]}" =~ ^[0-9]+$ ]]; then
    IP_PREFIX="${IFNETMASK[$MGMT_BRIDGE]}"
  else
    IP_PREFIX="$(netmask_to_prefix "${IFNETMASK[$MGMT_BRIDGE]}")" || bail "couldn't parse netmask '${IFNETMASK[$MGMT_BRIDGE]}' on $MGMT_BRIDGE."
  fi
else
  bail "couldn't determine a prefix length for $MGMT_BRIDGE's address."
fi
IP_GW="${IFGW[$MGMT_BRIDGE]}"

echo "==> Management IP: $IP_BARE/$IP_PREFIX via $IP_GW"

# ---------------------------------------------------------------------------
# Stage the new config through the API (never applied until later).
# ---------------------------------------------------------------------------
stage_config() {
  # Bash suspends errexit for the whole dynamic extent of a function when
  # it's called as an `if`/`!` condition (as this one is, below), so every
  # step that must hard-fail the migration checks its own exit status
  # explicitly instead of relying on `set -e` here.
  pvesh delete "/nodes/$NODE/network/$MGMT_BRIDGE" >/dev/null 2>&1 || true
  if [ -n "$BOND_IFACE" ]; then
    pvesh delete "/nodes/$NODE/network/$BOND_IFACE" >/dev/null 2>&1 || true
  fi

  local bridge_ports
  if [ -n "$BOND_IFACE" ]; then
    pvesh create "/nodes/$NODE/network" -iface "$BOND_IFACE" -type OVSBond \
      -ovs_bridge "$MGMT_BRIDGE" -ovs_bonds "$NIC_LIST" -ovs_options "$OVS_BOND_OPTS" || return 1
    bridge_ports="$BOND_IFACE"
  else
    pvesh set "/nodes/$NODE/network/$NIC_LIST" -type OVSPort -ovs_bridge "$MGMT_BRIDGE" || return 1
    bridge_ports="$NIC_LIST"
  fi

  if [ "$SIMPLE" -eq 1 ]; then
    pvesh create "/nodes/$NODE/network" -iface "$MGMT_BRIDGE" -type OVSBridge \
      -ovs_ports "$bridge_ports" -autostart 1 \
      -address "$IP_BARE" -netmask "$IP_PREFIX" -gateway "$IP_GW" || return 1
  else
    pvesh create "/nodes/$NODE/network" -iface "$MGMT_BRIDGE" -type OVSBridge \
      -ovs_ports "$bridge_ports mgmt0" -autostart 1 || return 1
    local mgmt_opts=()
    [ -n "$MGMT_VLAN" ] && mgmt_opts=(-ovs_options "tag=$MGMT_VLAN")
    pvesh create "/nodes/$NODE/network" -iface mgmt0 -type OVSIntPort -ovs_bridge "$MGMT_BRIDGE" \
      -address "$IP_BARE" -netmask "$IP_PREFIX" -gateway "$IP_GW" -autostart 1 \
      -comments "management (migrated from $MGMT_BRIDGE by proxmox-ovs-migrate.sh)" \
      "${mgmt_opts[@]}" || return 1
  fi
  return 0
}

if ! stage_config; then
  log "staging failed, reverting pending changes"
  pvesh delete "/nodes/$NODE/network" >/dev/null 2>&1 || true
  bail "failed to stage the new OVS config -- pending changes reverted, nothing was applied."
fi

if [ "$ACTION" = "dry-run" ]; then
  echo
  echo "==> Dry run - proposed /etc/network/interfaces (not applied):"
  diff -u /etc/network/interfaces /etc/network/interfaces.new || true
  pvesh delete "/nodes/$NODE/network" >/dev/null 2>&1 || true
  echo
  echo "==> Dry run only. Re-run with --apply to actually migrate."
  exit 0
fi

# ---------------------------------------------------------------------------
# --apply from here on.
# ---------------------------------------------------------------------------
echo
echo "==> Proposed /etc/network/interfaces:"
diff -u /etc/network/interfaces /etc/network/interfaces.new || true
echo

if [ "$YES" -ne 1 ]; then
  read -r -p "Apply this change to $MGMT_BRIDGE on $NODE now? [y/N] " reply
  case "$reply" in
    y|Y|yes|YES) ;;
    *) pvesh delete "/nodes/$NODE/network" >/dev/null 2>&1 || true; echo "Aborted, no changes made."; exit 1 ;;
  esac
fi

TS="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_DIR="$BACKUP_ROOT/$TS"
mkdir -p "$BACKUP_DIR"
cp -a /etc/network/interfaces "$BACKUP_DIR/interfaces.orig"
[ -d /etc/network/interfaces.d ] && cp -a /etc/network/interfaces.d "$BACKUP_DIR/interfaces.d.orig"
pvesh get "/nodes/$NODE/network" --output-format=json > "$BACKUP_DIR/network-api-dump.json"
ip -o addr show > "$BACKUP_DIR/ip-addr.txt"
ip -o link show > "$BACKUP_DIR/ip-link.txt"
ip -o route show > "$BACKUP_DIR/ip-route.txt"
if [ "$CLUSTERED" -eq 1 ]; then
  cp -a /etc/pve/corosync.conf "$BACKUP_DIR/corosync.conf.orig"
  pvecm status > "$BACKUP_DIR/pvecm-status.txt" 2>&1 || true
fi
{
  echo "NODE=$NODE"
  echo "MGMT_BRIDGE=$MGMT_BRIDGE"
  echo "CRITICAL_IP=$CRITICAL_IP"
  echo "ROLLBACK_MIN=$ROLLBACK_MIN"
  echo "TIMESTAMP=$TS"
} > "$BACKUP_DIR/meta.env"
ln -sfn "$BACKUP_DIR" "$BACKUP_ROOT/latest"
log "backup written to $BACKUP_DIR"

# Self-install so the rollback timer and the --confirm command printed below
# still have something to invoke after this session/shell is gone.
if [ "$(readlink -f "$0" 2>/dev/null)" != "$SELF" ]; then
  install -m 0755 "$0" "$SELF"
fi

touch "$BACKUP_DIR/.armed"

# systemd-run creates a transient unit owned by PID 1 -- unlike a
# backgrounded `nohup ... &`, it survives even if this SSH session's whole
# cgroup gets torn down when the network changes underneath it.
systemd-run --unit=pve-ovs-rollback \
  --description="Proxmox OVS migration auto-rollback for $NODE" \
  --on-active="${ROLLBACK_MIN}min" \
  "$SELF" --rollback-execute --backup-dir="$BACKUP_DIR"

log "applying: pvesh set /nodes/$NODE/network"
pvesh set "/nodes/$NODE/network"

echo "==> Waiting for OVS to come up locally..."
ok=0
for _ in $(seq 1 12); do
  if ovs-vsctl show >/dev/null 2>&1 && ip -4 addr show mgmt0 2>/dev/null | grep -q "$IP_BARE"; then
    ok=1
    break
  fi
  sleep 5
done
if [ "$ok" -eq 1 ]; then
  echo "==> Local check: OVS up, mgmt0 has $IP_BARE. (This does NOT prove reachability from outside -- confirm from a separate session.)"
else
  echo "==> Local check FAILED: OVS/mgmt0 did not come up as expected within 60s."
fi
if [ "$CLUSTERED" -eq 1 ]; then
  pvecm status 2>&1 | grep -i quorate || true
fi

cat <<EOF

============================================================
 NETWORK CHANGE APPLIED. Auto-rollback armed for ${ROLLBACK_MIN} minutes.

 From a NEW, SEPARATE SSH session (leave this one open), confirm you can
 reach $IP_BARE, confirm at least one VM's connectivity, then run EXACTLY
 this to cancel the rollback:

     $SELF --confirm --backup-dir=$BACKUP_DIR

 If that command is not run within ${ROLLBACK_MIN} minutes, this node will
 AUTOMATICALLY revert to its previous network configuration.

 To roll back immediately instead of waiting:

     $SELF --abort-now --backup-dir=$BACKUP_DIR

 Check status anytime with:

     $SELF --status
============================================================
EOF
