#!/usr/bin/env bash
#
# Apply safe, fully-reversible host-level tuning on a Proxmox VE node:
# network throughput sysctls, memory/VM-density sysctls, and KSM. Unlike
# proxmox-ovs-migrate.sh, this never touches anything that can affect
# reachability (no ip_forward, rp_filter, or firewall/ICMP policy changes),
# so it needs no rollback timer -- it's just a sysctl.d drop-in plus a
# service enable, both trivially reversible with --revert.
#
# Usage (run as root on the PVE node):
#   curl -fsSL <raw-url>/scripts/proxmox-host-tune.sh | bash
#   wget -qO- <raw-url>/scripts/proxmox-host-tune.sh | bash
#
# Flags:
#   --dry-run              Show what would change, make no changes.
#   --revert                Restore the most recent backup, undoing this script's changes.
#   --aggressive-ksm        Lower the KSM merge threshold (more RAM saved, more CPU spent).
#   --enable-strict-overcommit   Set vm.overcommit_memory=2 (workload-dependent, off by default).
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

ACTION="apply"
AGGRESSIVE_KSM=0
STRICT_OVERCOMMIT=0

for arg in "$@"; do
  case "$arg" in
    --dry-run) ACTION="dry-run" ;;
    --revert) ACTION="revert" ;;
    --aggressive-ksm) AGGRESSIVE_KSM=1 ;;
    --enable-strict-overcommit) STRICT_OVERCOMMIT=1 ;;
    *) echo "Error: unknown argument: $arg" >&2; exit 1 ;;
  esac
done

CONF=/etc/sysctl.d/99-proxmox-host-tune.conf
KSMTUNED_CONF=/etc/ksmtuned.conf
BACKUP_ROOT=/root/proxmox-host-tune-backups

# ---------------------------------------------------------------------------
# --revert
# ---------------------------------------------------------------------------
if [ "$ACTION" = "revert" ]; then
  LATEST="$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | tail -n1 || true)"
  if [ -z "$LATEST" ]; then
    echo "Error: no backup found under $BACKUP_ROOT to revert to." >&2
    exit 1
  fi
  if [ -f "$LATEST/99-proxmox-host-tune.conf.bak" ]; then
    cp -a "$LATEST/99-proxmox-host-tune.conf.bak" "$CONF"
    echo "==> Restored $CONF from $LATEST"
  else
    rm -f "$CONF"
    echo "==> Removed $CONF (no prior version existed before this script ran)"
  fi
  if [ -f "$LATEST/ksmtuned.conf.bak" ]; then
    cp -a "$LATEST/ksmtuned.conf.bak" "$KSMTUNED_CONF"
    systemctl restart ksmtuned 2>/dev/null || true
    echo "==> Restored $KSMTUNED_CONF from $LATEST"
  fi
  sysctl --system >/dev/null
  echo "==> Reverted using $LATEST"
  exit 0
fi

# ---------------------------------------------------------------------------
# Desired tunables (single source of truth for both the status table and
# the generated conf file).
# ---------------------------------------------------------------------------
SYSCTL_KEYS=(
  "net.core.rmem_max=16777216"
  "net.core.wmem_max=16777216"
  "net.core.netdev_max_backlog=5000"
  "net.core.default_qdisc=fq"
  "net.ipv4.tcp_congestion_control=bbr"
  "net.ipv4.tcp_fin_timeout=15"
  "net.ipv4.tcp_slow_start_after_idle=0"
  "vm.swappiness=10"
  "vm.dirty_ratio=10"
  "vm.dirty_background_ratio=5"
  "kernel.panic=10"
  "kernel.panic_on_oops=1"
)
# Only touch conntrack if the module is actually loaded, otherwise
# `sysctl --system` just warns about a nonexistent key on every boot.
if [ -f /proc/sys/net/netfilter/nf_conntrack_max ]; then
  SYSCTL_KEYS+=("net.netfilter.nf_conntrack_max=262144")
fi
if [ "$STRICT_OVERCOMMIT" -eq 1 ]; then
  SYSCTL_KEYS+=("vm.overcommit_memory=2")
fi

echo "==> Proxmox node: $(hostname)"

declare -A OLDVAL
for kv in "${SYSCTL_KEYS[@]}"; do
  key="${kv%%=*}"
  OLDVAL["$key"]="$(sysctl -n "$key" 2>/dev/null || echo "(unavailable)")"
done

NEW_CONTENT="# Managed by proxmox-host-tune.sh - delete this file and run 'sysctl --system' to revert
"
for kv in "${SYSCTL_KEYS[@]}"; do
  NEW_CONTENT="$NEW_CONTENT${kv/=/ = }
"
done

if [ "$ACTION" = "dry-run" ]; then
  echo "==> Dry run - proposed $CONF:"
  echo "$NEW_CONTENT"
  if [ -f "$CONF" ]; then
    echo "==> Diff against current file:"
    diff -u "$CONF" <(echo "$NEW_CONTENT") || true
  fi
  echo "==> Dry run only. Re-run without --dry-run to apply."
  exit 0
fi

TS="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_DIR="$BACKUP_ROOT/$TS"
mkdir -p "$BACKUP_DIR"
[ -f "$CONF" ] && cp -a "$CONF" "$BACKUP_DIR/99-proxmox-host-tune.conf.bak"

echo "$NEW_CONTENT" > "$CONF"
echo "==> Wrote $CONF"
sysctl --system >/dev/null
echo "==> Applied via sysctl --system"

echo "==> Ensuring KSM is enabled..."
systemctl enable --now ksm >/dev/null 2>&1 || true
systemctl enable --now ksmtuned >/dev/null 2>&1 || true

if [ "$AGGRESSIVE_KSM" -eq 1 ]; then
  echo "==> --aggressive-ksm: lowering KSM merge threshold (trades CPU for more RAM savings)"
  [ -f "$KSMTUNED_CONF" ] && cp -a "$KSMTUNED_CONF" "$BACKUP_DIR/ksmtuned.conf.bak"
  if [ -f "$KSMTUNED_CONF" ] && grep -q '^KSM_THRES_COEF=' "$KSMTUNED_CONF"; then
    sed -i 's/^KSM_THRES_COEF=.*/KSM_THRES_COEF=10/' "$KSMTUNED_CONF"
  else
    echo "KSM_THRES_COEF=10" >> "$KSMTUNED_CONF"
  fi
  systemctl restart ksmtuned 2>/dev/null || true
fi

declare -A NEWVAL
for kv in "${SYSCTL_KEYS[@]}"; do
  key="${kv%%=*}"
  NEWVAL["$key"]="$(sysctl -n "$key" 2>/dev/null || echo "(unavailable)")"
done

echo
echo "==> Final sysctl status:"
printf '%-38s %-16s %-16s\n' "KEY" "BEFORE" "AFTER"
for kv in "${SYSCTL_KEYS[@]}"; do
  key="${kv%%=*}"
  status="changed"
  [ "${OLDVAL[$key]}" = "${NEWVAL[$key]}" ] && status="already set"
  printf '%-38s %-16s %-16s (%s)\n' "$key" "${OLDVAL[$key]}" "${NEWVAL[$key]}" "$status"
done

echo
echo "==> Backup of previous config: $BACKUP_DIR (undo with: $0 --revert)"
echo "==> Done."
