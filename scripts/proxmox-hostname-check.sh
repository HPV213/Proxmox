#!/usr/bin/env bash
#
# Check, fix and rename the hostname / node name of a Proxmox VE node.
# Based on https://pve.proxmox.com/wiki/Renaming_a_PVE_node
#
# Modes (run as root on the PVE node):
#   (no args)           Check only. Read-only. Prints OK / WARN / FAIL.
#   --fix               Fully automatic repair after a manual rename: moves the
#                       stale /etc/pve/nodes/<old> data (VM/CT configs) and RRD
#                       stats to the current node name, fixes postfix if
#                       needed, then re-checks.
#   --rename NEWNAME    Fully automatic rename, NO reboot needed:
#                       backup -> edit /etc/hostname, /etc/hosts, /etc/mailname,
#                       /etc/postfix/main.cf -> hostnamectl -> restart PVE
#                       services -> move guest configs + RRD -> re-check.
#                       NEWNAME may be a short name or an FQDN.
#   --old NAME          With --fix: the old node name (auto-detected if only
#                       one stale directory exists).
#   --force             Allow --rename on a clustered node / node with guests.
#   -y, --yes           Do not ask for confirmation.
#
# On any failure a detailed ERROR REPORT is printed at the end; copy and paste
# it as-is when asking for help.
#
# Examples:
#   curl -fsSL <raw-url>/scripts/proxmox-hostname-check.sh | bash
#   curl -fsSL <raw-url>/scripts/proxmox-hostname-check.sh | bash -s -- --fix
#   curl -fsSL <raw-url>/scripts/proxmox-hostname-check.sh | bash -s -- --rename pve2
#
set -uo pipefail
shopt -s nullglob

MODE=check; NEW=""; OLD=""; FORCE=0; YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --rename)  MODE=rename; NEW="${2:-}"; [ -n "$NEW" ] || { echo "--rename needs a name" >&2; exit 2; }; shift 2 ;;
    --fix|--cleanup) MODE=fix; shift ;;
    --old)     OLD="${2:-}"; [ -n "$OLD" ] || { echo "--old needs a name" >&2; exit 2; }; shift 2 ;;
    --force)   FORCE=1; shift ;;
    -y|--yes)  YES=1; shift ;;
    -h|--help) sed -n '2,26p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

if [ "$(id -u)" -ne 0 ]; then echo "Error: must run as root." >&2; exit 1; fi

R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; N=$'\e[0m'
[ -t 1 ] || { R=""; G=""; Y=""; N=""; }

FAILS=0; WARNS=0
ERRORS=()          # entries for the final report
STEP="init"
RRD_ROOT=/var/lib/rrdcached/db
TS=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR=/root/pve-rename-backup-$TS

ok()   { echo "  ${G}[OK]${N}   $*"; }
warn() { echo "  ${Y}[WARN]${N} $*"; WARNS=$((WARNS+1)); }
fail() { echo "  ${R}[FAIL]${N} $*"; FAILS=$((FAILS+1)); }
info() { echo "  [..]   $*"; }
step() { STEP="$*"; echo; echo "==> $*"; }

add_error() { # add_error <command> <exit> <output>
  ERRORS+=("step   : $STEP"$'\n'"command: $1"$'\n'"exit   : $2"$'\n'"output : $3")
}

# run <cmd...>: run a command, capture output, record a detailed error on failure
run() {
  local out rc
  out=$("$@" 2>&1); rc=$?
  if [ $rc -ne 0 ]; then
    add_error "$*" "$rc" "${out:-<none>}"
    echo "  ${R}[ERR]${N}  $* (exit $rc)"
    [ -n "$out" ] && echo "$out" | sed 's/^/         /'
    return $rc
  fi
  [ -n "$out" ] && echo "$out" | sed 's/^/         /'
  return 0
}

confirm() {
  [ "$YES" -eq 1 ] && return 0
  local a
  if [ -r /dev/tty ]; then read -r -p "$1 [y/N] " a </dev/tty; else echo "$1 (no tty, use -y)"; return 1; fi
  [[ "$a" =~ ^[Yy]$ ]]
}

valid_name() { [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; }
in_cluster() { [ -f /etc/pve/corosync.conf ] || [ -f /etc/corosync/corosync.conf ]; }
short_name() { hostname -s 2>/dev/null || hostname | cut -d. -f1; }

guest_count() {
  local n="$1" c=0 d f
  for d in qemu-server lxc; do
    for f in /etc/pve/nodes/"$n"/$d/*.conf; do c=$((c+1)); done
  done
  echo "$c"
}

stale_nodes() {
  local me d; me=$(short_name)
  for d in /etc/pve/nodes/*/; do
    d=$(basename "$d"); [ "$d" != "$me" ] && echo "$d"
  done
}

# Directories named exactly <name> one level below $RRD_ROOT/* (any PVE version layout)
rrd_dirs_for() {
  local n="$1" d
  for d in "$RRD_ROOT"/*/"$n"; do [ -d "$d" ] && echo "$d"; done
}

print_report() {
  [ "${#ERRORS[@]}" -eq 0 ] && return 0
  local me i e; me=$(short_name)
  echo
  echo "================ ERROR REPORT (copy from here) ================"
  echo "date     : $(date -Is)"
  echo "mode     : $MODE   old='${OLD:-}' new='${NEW:-}'"
  echo "pve      : $(pveversion 2>/dev/null || echo 'pveversion not found')"
  echo "hostname : short=$me  static=$(cat /etc/hostname 2>/dev/null)  fqdn=$(hostname -f 2>&1)"
  echo "cluster  : $(in_cluster && echo yes || echo no)"
  echo "backup   : $([ -d "$BACKUP_DIR" ] && echo "$BACKUP_DIR" || echo none)"
  echo "-------------------------------------------------------------"
  i=1
  for e in "${ERRORS[@]}"; do echo "[$i]"; echo "$e"; echo; i=$((i+1)); done
  echo "-------------------------------------------------------------"
  echo "--- /etc/hosts ---";            grep -v '^[[:space:]]*#' /etc/hosts 2>&1
  echo "--- /etc/pve/nodes ---";        ls -la /etc/pve/nodes 2>&1
  echo "--- guest configs ---";         ls -la /etc/pve/nodes/*/qemu-server /etc/pve/nodes/*/lxc 2>&1
  echo "--- rrd dirs ---";              ls -d "$RRD_ROOT"/*/* 2>&1 | head -n 40
  echo "--- pve-cluster status ---";    systemctl status pve-cluster --no-pager -l 2>&1 | head -n 15
  echo "--- pve-cluster journal ---";   journalctl -u pve-cluster -n 15 --no-pager 2>&1
  if [ -d "$BACKUP_DIR/etc" ]; then
    echo "--- restore command ---"
    echo "cp -a $BACKUP_DIR/etc/. /etc/ && hostnamectl set-hostname \$(cat /etc/hostname) && systemctl restart pve-cluster"
  fi
  echo "================ END OF ERROR REPORT ================"
}
trap print_report EXIT

# ---------------------------------------------------------------- check
do_check() {
  local short fqdn static ip st mn any
  FAILS=0; WARNS=0
  short=$(short_name); fqdn=$(hostname -f 2>/dev/null || true)
  echo "==> Hostname check for node: $short"

  echo "[1] Hostname files"
  if [ -s /etc/hostname ]; then
    static=$(tr -d ' \t\r\n' </etc/hostname)
    if [ "${static%%.*}" = "$short" ]; then
      ok "/etc/hostname = $static, matches running hostname ($short)"
    else
      fail "/etc/hostname ($static) differs from running hostname ($short)"
    fi
    valid_name "${static%%.*}" || fail "'$static' is not a valid hostname (letters, digits, '-')"
    [[ "$static" =~ [A-Z] ]] && warn "hostname has uppercase letters; lowercase is recommended"
    [[ "$static" == *.* ]] && info "/etc/hostname holds an FQDN; works, short name is the usual convention"
  else
    fail "/etc/hostname missing or empty"
  fi

  echo "[2] /etc/hosts"
  ip=$(awk -v h="$short" '!/^[[:space:]]*#/ { for(i=2;i<=NF;i++) if($i==h){print $1; exit} }' /etc/hosts)
  if [ -z "$ip" ]; then
    fail "/etc/hosts has no entry for '$short' (needed: '<node IP> <fqdn> $short')"
  else
    case "$ip" in
      127.*|::1) fail "/etc/hosts maps $short to loopback ($ip); must be the node's real IP" ;;
      *) ok "/etc/hosts maps $short -> $ip"
         if ip -o addr show 2>/dev/null | grep -qE "[[:space:]]${ip//./\\.}/"; then ok "$ip is configured on a local interface"
         else fail "$ip is not assigned to any local interface"; fi ;;
    esac
  fi
  [ -n "$fqdn" ] && ok "hostname -f = $fqdn" || warn "hostname -f returns nothing (no FQDN resolvable)"
  getent hosts "$short" >/dev/null 2>&1 && ok "'$short' resolves: $(getent hosts "$short" | head -n1)" || fail "'$short' does not resolve"

  echo "[3] Mail (optional, not needed by Proxmox itself)"
  if [ -f /etc/mailname ]; then
    grep -q "$short" /etc/mailname && ok "/etc/mailname contains $short" || warn "/etc/mailname ($(cat /etc/mailname)) does not contain $short"
  fi
  if command -v postconf >/dev/null 2>&1; then
    mn=$(postconf -h myhostname 2>/dev/null)
    if [ "$mn" = "$short" ] || [ "$mn" = "$fqdn" ]; then ok "postfix myhostname = $mn"
    else warn "postfix myhostname = '$mn' (expected $fqdn or $short)"; fi
  fi

  echo "[4] Proxmox services / config"
  systemctl is-active --quiet pve-cluster && ok "pve-cluster is active" || fail "pve-cluster is not active (usually a hostname/hosts problem)"
  [ -d /etc/pve/nodes/"$short" ] && ok "/etc/pve/nodes/$short exists" || fail "/etc/pve/nodes/$short missing"
  while read -r st; do
    [ -z "$st" ] && continue
    if in_cluster; then ok "other cluster node: $st"
    else warn "stale node dir: /etc/pve/nodes/$st ($(guest_count "$st") guest config) -> run with --fix"
    fi
  done < <(stale_nodes)
  if in_cluster; then
    warn "cluster config found; renaming nodes in a cluster is not recommended"
    grep -qE "name:[[:space:]]*$short\b" /etc/pve/corosync.conf 2>/dev/null \
      && ok "corosync.conf has node '$short'" || fail "corosync.conf has no node named '$short'"
  fi
  if [ -n "$(rrd_dirs_for "$short")" ]; then
    ok "RRD data present for $short"
  else
    any=0
    if ! in_cluster; then
      while read -r st; do
        [ -n "$st" ] && [ -n "$(rrd_dirs_for "$st")" ] && { warn "RRD data still under old name '$st' -> run with --fix"; any=1; }
      done < <(stale_nodes)
    fi
    [ $any -eq 0 ] && info "no RRD dir for $short yet (created by pvestatd; nothing to migrate)"
  fi

  echo
  echo "Result: $FAILS fail, $WARNS warn"
  [ "$FAILS" -eq 0 ]
}

# ------------------------------------------------- migrate (after rename)
wait_for_node_dir() {
  local n="$1" i
  for i in $(seq 1 30); do
    systemctl is-active --quiet pve-cluster && [ -d /etc/pve/nodes/"$n" ] && return 0
    sleep 2
  done
  return 1
}

migrate_data() {
  local old="$1" new="$2" src dst sub f d t dirs
  step "Move guest configs: $old -> $new"
  src=/etc/pve/nodes/$old; dst=/etc/pve/nodes/$new
  if [ ! -d "$src" ]; then
    info "$src not found, nothing to move"
  else
    run mkdir -p "$dst"
    for sub in qemu-server lxc openvz priv; do
      [ -d "$src/$sub" ] || continue
      run mkdir -p "$dst/$sub"
      for f in "$src/$sub"/*; do
        if [ -e "$dst/$sub/$(basename "$f")" ]; then
          add_error "mv $f $dst/$sub/" "-" "destination already exists, NOT overwritten. Compare: diff $f $dst/$sub/$(basename "$f")"
          echo "  ${R}[ERR]${N}  $dst/$sub/$(basename "$f") already exists - skipped"
        else
          run mv "$f" "$dst/$sub/" && echo "  moved $sub/$(basename "$f")"
        fi
      done
      rmdir "$src/$sub" 2>/dev/null
    done
    for f in "$src"/*; do
      [ -f "$f" ] || continue
      if [ -e "$dst/$(basename "$f")" ]; then rm -f "$f"; else run mv "$f" "$dst/"; fi
    done
    if rmdir "$src" 2>/dev/null; then
      echo "  removed $src"
    else
      add_error "rmdir $src" "1" "directory not empty: $(ls -A "$src" | tr '\n' ' ')"
      echo "  ${R}[ERR]${N}  $src not empty, left in place: $(ls -A "$src" | tr '\n' ' ')"
    fi
  fi

  step "Move RRD statistics: $old -> $new"
  dirs=$(rrd_dirs_for "$old")
  if [ -z "$dirs" ]; then
    info "no RRD data under old name (normal on newer PVE), skipping"
  else
    systemctl stop pvestatd 2>/dev/null
    while read -r d; do
      t="$(dirname "$d")/$new"
      if [ -d "$t" ]; then
        run cp -an "$d"/. "$t"/ && run rm -rf "$d" && echo "  merged $d -> $t"
      else
        run mv "$d" "$t" && echo "  moved $d -> $t"
      fi
    done <<<"$dirs"
    systemctl start pvestatd 2>/dev/null
  fi
}

do_fix() {
  local new cand=() s; new=$(short_name)
  if [ ! -d /etc/pve/nodes ]; then
    add_error "ls /etc/pve/nodes" "1" "/etc/pve not mounted (pve-cluster down?)"
    echo "${R}/etc/pve is not available. Is pve-cluster running?${N}"; return 1
  fi
  if [ -z "$OLD" ]; then
    while read -r s; do [ -n "$s" ] && cand+=("$s"); done < <(stale_nodes)
    case "${#cand[@]}" in
      0) echo "No stale node directory found - nothing to migrate."; do_check; return $? ;;
      1) OLD="${cand[0]}" ;;
      *) echo "Several stale dirs (${cand[*]}). Choose one with --old NAME." >&2; return 1 ;;
    esac
  fi
  [ "$OLD" != "$new" ] || { echo "Old name equals current name." >&2; return 1; }
  if in_cluster && [ "$FORCE" -ne 1 ]; then
    echo "Clustered node: refusing to move data. Use --force if you are sure." >&2; return 1
  fi
  echo "Will move data of '$OLD' to '$new' ($(guest_count "$OLD") guest config(s))."
  confirm "Proceed?" || { echo "Aborted."; return 1; }
  mkdir -p "$BACKUP_DIR" && cp -a /etc/pve/nodes/"$OLD" "$BACKUP_DIR/nodes-$OLD" 2>/dev/null && echo "Backup of old node dir: $BACKUP_DIR/nodes-$OLD"
  migrate_data "$OLD" "$new"
  if command -v postconf >/dev/null 2>&1 && [ "$(postconf -h myhostname 2>/dev/null)" = "$OLD" ]; then
    step "Fix postfix myhostname"
    run postconf -e "myhostname=$(hostname -f 2>/dev/null || echo "$new")" && run systemctl restart postfix
  fi
  step "Final check"; do_check
}

# --------------------------------------------------------------- rename
do_rename() {
  local old newshort f gc s
  old=$(short_name)
  NEW=$(echo "$NEW" | tr 'A-Z' 'a-z'); newshort=${NEW%%.*}
  valid_name "$newshort" || { echo "Error: invalid new name '$NEW'." >&2; return 1; }
  [ "$newshort" != "$old" ] || { echo "Error: new name equals current name ($old)." >&2; return 1; }
  [ -e /etc/pve/nodes/"$newshort" ] && { echo "Error: /etc/pve/nodes/$newshort already exists." >&2; return 1; }
  systemctl is-active --quiet pve-cluster || { echo "Error: pve-cluster is not active; fix that first." >&2; return 1; }

  gc=$(guest_count "$old")
  if [ "$FORCE" -ne 1 ]; then
    in_cluster && { echo "Error: node is in a cluster; renaming is not recommended. Use --force to override." >&2; return 1; }
    [ "$gc" -gt 0 ] && { echo "Error: node has $gc VM/CT config(s). The wiki recommends an empty node. Use --force to override (guest configs are then moved automatically)." >&2; return 1; }
  fi
  if command -v qm >/dev/null 2>&1 && qm list 2>/dev/null | grep -q running; then
    echo "${Y}Note: running VMs detected. They keep running, but do not start/stop/migrate guests during the rename.${N}"
  fi

  echo "Rename node: $old -> $newshort   (/etc/hostname will be: $NEW)"
  echo "Guest configs to move: $gc.  No reboot will be done."
  confirm "Proceed?" || { echo "Aborted."; return 1; }

  step "Backup to $BACKUP_DIR"
  if ! mkdir -p "$BACKUP_DIR/etc/postfix"; then add_error "mkdir -p $BACKUP_DIR" "1" "cannot create backup dir"; return 1; fi
  for f in /etc/hostname /etc/hosts /etc/mailname /etc/postfix/main.cf; do
    [ -f "$f" ] && cp -a "$f" "$BACKUP_DIR$f"
  done
  [ -d /etc/pve/nodes/"$old" ] && cp -a /etc/pve/nodes/"$old" "$BACKUP_DIR/nodes-$old"
  echo "  backup done"

  step "Edit config files"
  for f in /etc/hosts /etc/mailname /etc/postfix/main.cf; do
    [ -f "$f" ] || continue
    # applied twice so adjacent occurrences ("vm vm") are both replaced
    run sed -i -E "s/(^|[^A-Za-z0-9-])$old([^A-Za-z0-9-]|\$)/\1$newshort\2/g; s/(^|[^A-Za-z0-9-])$old([^A-Za-z0-9-]|\$)/\1$newshort\2/g" "$f" && echo "  edited $f"
  done
  echo "$NEW" >/etc/hostname && echo "  wrote /etc/hostname = $NEW"
  if ! awk -v h="$newshort" '!/^[[:space:]]*#/ { for(i=2;i<=NF;i++) if($i==h) f=1 } END{exit !f}' /etc/hosts; then
    add_error "check /etc/hosts" "1" "/etc/hosts has no entry for $newshort after edit. Add a line: '<node IP> $NEW $newshort'"
    echo "${R}/etc/hosts has no entry for $newshort - aborting before touching services.${N}"
    return 1
  fi

  step "Apply hostname"
  run hostnamectl set-hostname "$NEW" || run hostname "$newshort"

  step "Restart PVE services"
  run systemctl restart pve-cluster
  if ! wait_for_node_dir "$newshort"; then
    add_error "wait for /etc/pve/nodes/$newshort" "1" "directory did not appear within 60s"
    echo "${R}/etc/pve/nodes/$newshort did not appear within 60s.${N}"
    return 1
  fi
  for s in pvedaemon pveproxy spiceproxy pvestatd pve-firewall pve-ha-lrm pve-ha-crm; do
    if systemctl list-unit-files "$s.service" 2>/dev/null | grep -q "^$s" && systemctl is-enabled --quiet "$s" 2>/dev/null; then
      run systemctl restart "$s"
    fi
  done
  if systemctl is-active --quiet postfix 2>/dev/null; then run systemctl restart postfix; fi

  migrate_data "$old" "$newshort"
  step "Final check"
  do_check
  echo
  if [ "${#ERRORS[@]}" -eq 0 ] && [ "$FAILS" -eq 0 ]; then
    echo "${G}Rename complete, no reboot needed.${N} Backup kept in $BACKUP_DIR"
    echo "Tip: reload the web UI (Ctrl+F5) to see the new name."
  fi
}

rc=0
case "$MODE" in
  check)  do_check || rc=1 ;;
  fix)    do_fix || rc=1 ;;
  rename) do_rename || rc=1 ;;
esac
[ "${#ERRORS[@]}" -gt 0 ] && rc=1
exit "$rc"
