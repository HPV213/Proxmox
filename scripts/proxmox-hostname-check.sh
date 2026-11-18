#!/usr/bin/env bash
#
# Check (and optionally change) the hostname / node name of a Proxmox VE node,
# following https://pve.proxmox.com/wiki/Renaming_a_PVE_node
#
# Modes:
#   (no args)             Check only. Read-only, prints OK/WARN/FAIL per item.
#   --rename NEWNAME      Rename the node: backs up then edits /etc/hostname,
#                         /etc/hosts, /etc/mailname, /etc/postfix/main.cf.
#                         Reboot afterwards, then run --cleanup.
#   --cleanup             After the reboot: move the old node's data
#                         (/etc/pve/nodes/OLD, RRD stats) to the new name.
#   --old NAME            With --cleanup: the old node name (auto-detected
#                         when exactly one stale directory exists).
#   --force               Allow --rename on a cluster node / node with guests.
#   -y, --yes             Do not ask for confirmation.
#
# Usage (run as root on the PVE node):
#   bash proxmox-hostname-check.sh
#   bash proxmox-hostname-check.sh --rename pve2
#   bash proxmox-hostname-check.sh --cleanup
#
set -uo pipefail
shopt -s nullglob

NEW=""; OLD=""; MODE=check; FORCE=0; YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --rename)  MODE=rename; NEW="${2:-}"; shift 2 || { echo "--rename needs a name" >&2; exit 2; } ;;
    --cleanup) MODE=cleanup; shift ;;
    --old)     OLD="${2:-}"; shift 2 || { echo "--old needs a name" >&2; exit 2; } ;;
    --force)   FORCE=1; shift ;;
    -y|--yes)  YES=1; shift ;;
    -h|--help) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

if [ "$(id -u)" -ne 0 ]; then echo "Error: must run as root." >&2; exit 1; fi

R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; N=$'\e[0m'
[ -t 1 ] || { R=""; G=""; Y=""; N=""; }
FAILS=0; WARNS=0
ok()   { echo "  ${G}[OK]${N}   $*"; }
warn() { echo "  ${Y}[WARN]${N} $*"; WARNS=$((WARNS+1)); }
fail() { echo "  ${R}[FAIL]${N} $*"; FAILS=$((FAILS+1)); }

confirm() {
  [ "$YES" -eq 1 ] && return 0
  read -r -p "$1 [y/N] " a </dev/tty
  [[ "$a" =~ ^[Yy]$ ]]
}

valid_name() { [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; }

in_cluster() { [ -f /etc/pve/corosync.conf ] || [ -f /etc/corosync/corosync.conf ]; }

guest_count() {
  local n="$1" c=0
  for d in qemu-server lxc; do
    c=$((c + $(ls /etc/pve/nodes/"$n"/$d/*.conf 2>/dev/null | wc -l)))
  done
  echo "$c"
}

# ---------------------------------------------------------------- check
do_check() {
  local short fqdn static ip
  short=$(hostname -s 2>/dev/null || hostname)
  fqdn=$(hostname -f 2>/dev/null || true)
  echo "==> Hostname check for node: $short"

  echo "[1] Hostname files"
  if [ -s /etc/hostname ]; then
    static=$(tr -d ' \t\r\n' </etc/hostname)
    if [ "$static" = "$short" ] || [ "${static%%.*}" = "$short" ]; then
      ok "/etc/hostname = $static, matches running hostname ($short)"
    else
      fail "/etc/hostname ($static) differs from running hostname ($short) - reboot needed or file wrong"
    fi
    valid_name "${static%%.*}" || fail "'$static' is not a valid hostname (letters, digits, '-')"
    [[ "$static" =~ [A-Z] ]] && warn "hostname contains uppercase letters; lowercase is recommended"
  else
    fail "/etc/hostname missing or empty"
  fi

  echo "[2] /etc/hosts"
  if grep -Eq "^[^#]*[[:space:]]$short([[:space:]]|\$)" /etc/hosts; then
    ip=$(grep -E "^[^#]*[[:space:]]$short([[:space:]]|\$)" /etc/hosts | awk '{print $1}' | head -n1)
    case "$ip" in
      127.*|::1) fail "/etc/hosts maps $short to loopback ($ip); it must map to the node's real IP" ;;
      *)
        ok "/etc/hosts maps $short -> $ip"
        if ip -o addr show 2>/dev/null | grep -qE "[[:space:]]${ip//./\\.}/"; then
          ok "$ip is configured on a local interface"
        else
          fail "$ip is not assigned to any local interface"
        fi ;;
    esac
  else
    fail "/etc/hosts has no entry for '$short' (needed: '<node IP> <fqdn> $short')"
  fi
  [ -n "$fqdn" ] && ok "hostname -f = $fqdn" || warn "hostname -f returns nothing (no FQDN resolvable)"
  if getent hosts "$short" >/dev/null 2>&1; then
    ok "'$short' resolves: $(getent hosts "$short" | head -n1)"
  else
    fail "'$short' does not resolve"
  fi

  echo "[3] Optional files (not needed by Proxmox itself)"
  if [ -f /etc/mailname ]; then
    grep -q "$short" /etc/mailname && ok "/etc/mailname contains $short" || warn "/etc/mailname does not contain $short: $(cat /etc/mailname)"
  fi
  if [ -f /etc/postfix/main.cf ]; then
    grep -Eq "^(myhostname|mydestination).*$short" /etc/postfix/main.cf \
      && ok "/etc/postfix/main.cf references $short" \
      || warn "/etc/postfix/main.cf has no reference to $short"
  fi

  echo "[4] Proxmox services / config"
  if systemctl is-active --quiet pve-cluster; then ok "pve-cluster is active"; else fail "pve-cluster is not active (usually a hostname/hosts problem)"; fi
  if [ -d /etc/pve/nodes/"$short" ]; then
    ok "/etc/pve/nodes/$short exists"
  else
    fail "/etc/pve/nodes/$short missing"
  fi
  local stale=()
  for d in /etc/pve/nodes/*/; do
    d=$(basename "$d")
    [ "$d" != "$short" ] && stale+=("$d")
  done
  if [ "${#stale[@]}" -gt 0 ]; then
    if in_cluster; then
      ok "other nodes present (cluster): ${stale[*]}"
    else
      warn "stale node dir(s) left over: ${stale[*]}  -> run this script with --cleanup"
    fi
  fi
  if in_cluster; then
    warn "cluster config found; renaming nodes in a cluster is not recommended"
    if grep -qE "name:[[:space:]]*$short\b" /etc/pve/corosync.conf 2>/dev/null; then
      ok "corosync.conf has node '$short'"
    else
      fail "corosync.conf has no node named '$short'"
    fi
  fi
  for t in node storage; do
    [ -d /var/lib/rrdcached/db/pve2-$t/"$short" ] \
      && ok "RRD pve2-$t/$short exists" \
      || warn "RRD pve2-$t/$short missing (graph history not migrated yet)"
  done

  echo
  echo "Result: $FAILS fail, $WARNS warn"
  [ "$FAILS" -eq 0 ]
}

# --------------------------------------------------------------- rename
do_rename() {
  local old
  old=$(hostname -s)
  valid_name "$NEW" || { echo "Error: invalid new name '$NEW'." >&2; exit 1; }
  NEW=$(echo "$NEW" | tr 'A-Z' 'a-z')
  [ "$NEW" != "$old" ] || { echo "Error: new name equals current name." >&2; exit 1; }

  if [ "$FORCE" -ne 1 ]; then
    if in_cluster; then echo "Error: node is in a cluster; renaming is not recommended. Use --force to override." >&2; exit 1; fi
    if [ -d /etc/pve/nodes/"$old" ] && [ "$(guest_count "$old")" -gt 0 ]; then
      echo "Error: node has $(guest_count "$old") VM/CT config(s). Wiki says rename on an empty node. Use --force to override." >&2
      exit 1
    fi
  fi

  echo "Will rename node: $old -> $NEW"
  echo "Files: /etc/hostname /etc/hosts /etc/mailname /etc/postfix/main.cf (backups: *.bak-rename)"
  confirm "Proceed?" || { echo "Aborted."; exit 1; }

  local f
  for f in /etc/hostname /etc/hosts /etc/mailname /etc/postfix/main.cf; do
    [ -f "$f" ] || continue
    cp -a "$f" "$f.bak-rename"
    sed -i -E "s/(^|[^A-Za-z0-9-])$old([^A-Za-z0-9-]|\$)/\1$NEW\2/g; s/(^|[^A-Za-z0-9-])$old([^A-Za-z0-9-]|\$)/\1$NEW\2/g" "$f"
    echo "  edited $f"
  done
  # /etc/hostname is a single bare word; make sure of it
  echo "$NEW" >/etc/hostname
  hostnamectl set-hostname "$NEW" 2>/dev/null || hostname "$NEW"

  echo
  echo "Done editing. Re-checking files:"
  grep -n "$NEW" /etc/hosts
  grep -q "$NEW" /etc/hosts || echo "${R}WARNING: /etc/hosts has no entry for $NEW - fix before reboot!${N}"
  echo
  echo "Next steps:"
  echo "  1. reboot"
  echo "  2. bash $0 --cleanup --old $old"
}

# -------------------------------------------------------------- cleanup
do_cleanup() {
  local new cand=()
  new=$(hostname -s)
  if [ -z "$OLD" ]; then
    for d in /etc/pve/nodes/*/; do
      d=$(basename "$d"); [ "$d" != "$new" ] && cand+=("$d")
    done
    if [ "${#cand[@]}" -eq 1 ]; then OLD="${cand[0]}"
    else echo "Error: cannot auto-detect old name (found: ${cand[*]:-none}). Use --old NAME." >&2; exit 1; fi
  fi
  [ "$OLD" != "$new" ] || { echo "Error: old name equals current name." >&2; exit 1; }
  systemctl is-active --quiet pve-cluster || { echo "Error: pve-cluster not active; fix hostname first." >&2; exit 1; }

  echo "Cleanup: move data from '$OLD' to '$new'"
  confirm "Proceed?" || { echo "Aborted."; exit 1; }

  local src=/etc/pve/nodes/$OLD dst=/etc/pve/nodes/$new sub f
  if [ -d "$src" ]; then
    mkdir -p "$dst"
    for sub in qemu-server lxc openvz priv; do
      [ -d "$src/$sub" ] || continue
      mkdir -p "$dst/$sub"
      for f in "$src/$sub"/*; do
        [ -e "$f" ] || continue
        mv "$f" "$dst/$sub/" && echo "  moved $sub/$(basename "$f")" || echo "  ${R}failed to move $f${N}"
      done
      rmdir "$src/$sub" 2>/dev/null || echo "  ${Y}could not remove $src/$sub (not empty)${N}"
    done
    # remaining top-level files
    for f in "$src"/*; do
      [ -f "$f" ] || continue
      [ -e "$dst/$(basename "$f")" ] && rm -f "$f" || mv "$f" "$dst/"
    done
    rmdir "$src" 2>/dev/null && echo "  removed $src" || echo "  ${Y}$src not empty, left in place - check manually${N}"
  else
    echo "  $src not found, skipping node config"
  fi

  local t
  for t in node storage; do
    src=/var/lib/rrdcached/db/pve2-$t/$OLD
    dst=/var/lib/rrdcached/db/pve2-$t/$new
    [ -d "$src" ] || continue
    mkdir -p "$dst"
    cp -an "$src"/. "$dst"/ && rm -rf "$src" && echo "  moved RRD pve2-$t/$OLD -> $new"
  done
  echo
  do_check
}

case "$MODE" in
  check)   do_check ;;
  rename)  do_rename ;;
  cleanup) do_cleanup ;;
esac
