# OVS migration runbook

Companion to `scripts/proxmox-ovs-migrate.sh`. Read this before running that
script — it migrates the bridge carrying your current SSH session's IP
(usually also the corosync ring) from a Linux bridge to Open vSwitch, on a
node that in your case has **no console/IPMI fallback**. The script has its
own safety net (backup + auto-rollback timer), but the checklist below is
what keeps you from needing it.

## Before you start

- [ ] Read `scripts/proxmox-ovs-migrate.sh` itself once, end to end. It is
      intentionally not a `curl | bash` one-liner for this reason.
- [ ] Confirm you have a **second, independent way to reach this node** for
      the confirm step — ideally a different machine on a different uplink,
      not just a second terminal tab on the same laptop/network path.
- [ ] If this node runs HA-managed VMs, consider `ha-manager` maintenance
      mode or migrating VMs off first, so a transient blip during the
      unconfirmed window can't trigger fencing/relocation elsewhere in the
      cluster. Verify the exact `ha-manager` syntax against your installed
      PVE version — check `ha-manager help` on the node first.
- [ ] Know your rollback window tolerance: default is 15 minutes
      (`--rollback-after=N`, 5-60 allowed). Long enough to actually verify
      things, short enough that a broken node doesn't sit mid-migration for
      hours before self-healing.

## The one time to skip straight to production: never

Run the entire flow below, **including a deliberate un-confirmed
`--apply`**, against a spare node or a nested-virtualization PVE test VM
first. You are not just testing the migration — you are testing that the
rollback mechanism itself actually works on your hardware/network before
you bet a production node on it.

1. `./proxmox-ovs-migrate.sh --dry-run` — read the diff carefully.
2. `./proxmox-ovs-migrate.sh --apply --rollback-after=5` — then **do
   nothing**. Let the timer fire. Confirm the node comes back on its own:
   original bridge/IP restored, SSH still reachable throughout.
3. Only once that's boring and predictable, move to production.

## Production rollout (one node at a time)

For each node, in order, never two nodes "armed" at once:

1. `./proxmox-ovs-migrate.sh --dry-run`
   - Review the printed diff against `/etc/network/interfaces`.
   - If it bails out (VLAN-aware bridge, DHCP mgmt IP, unsupported bond
     mode, SDN zones, etc.) — see the table below, don't fight the script,
     handle that case manually instead.
2. `./proxmox-ovs-migrate.sh --apply --rollback-after=15`
   - You'll be prompted to confirm once more before anything is written
     (skip with `--yes` only once you fully trust the diff).
3. From a **separate** session/machine (not this one):
   - Fresh SSH connects.
   - `pvesh get /nodes/<node>/status` responds.
   - Proxmox web GUI shows the node green/online.
   - `ovs-vsctl show` (via `proxmox-ovs-verify.sh`) lists the expected
     bridge/port/bond/intport.
   - `pvecm status` — quorate, no ring faults, node count matches.
   - Ping/SSH into at least one VM on this node, both from outside and to
     another VM — OVS can behave subtly differently from a Linux bridge for
     guest traffic, don't just check host reachability.
4. Only after all of the above: `./proxmox-ovs-migrate.sh --confirm --backup-dir=<path>`.
5. Soak before touching the next node:
   `journalctl -u corosync -f` and `-u openvswitch-switch -f` for a few
   hours, watching for flapping or errors that only show up under load/time.
6. Repeat for the next node.

If anything looks wrong at step 3, don't wait out the timer —
`./proxmox-ovs-migrate.sh --abort-now --backup-dir=<path>` immediately.

## 2-node cluster with a QDevice

Extra caution: quorum arithmetic is different from a 3+ node majority
cluster. Longer soak time, and explicitly check QDevice connectivity in
`pvecm status` after each node.

## Cases the script refuses to touch (do these manually)

| Situation | Why it bails | What to do |
|---|---|---|
| Management bridge uses DHCP | Corosync/SSH need a stable IP through the cutover | Convert to static first, reboot/verify, then re-run |
| Bridge is already VLAN-aware | Different migration shape | Migrate by hand, following the same OVSBridge+OVSIntPort pattern |
| SDN zones configured (`/etc/pve/sdn/*`) | Out of scope | Handle manually, or consult Proxmox SDN + OVS docs together |
| Bond mode isn't 802.3ad / active-backup / balance-xor | No clean 1:1 OVS bond mode | Reconfigure the bond to a supported mode first, or map manually |
| `bridge_ports` lists 2+ NICs with no bond in between | Ambiguous intent | Define a real Linux bond first, or build the OVSBond by hand |
| VLAN sub-interfaces already on the mgmt path | Tagged trunking already in play | Migrate by hand, mapping each tag to an `ovs_options tag=N` intport |
| Dual-ring corosync (`ring1_addr` set) | Too complex for v1 | Migrate manually, double-check both rings survive the cutover |
| A previous migration is still armed/unconfirmed | Never stack two in-flight changes | `--status`, then `--confirm` or `--abort-now` it first |

## Non-management vmbr's (pure VM traffic, no host IP)

Out of scope for this script by design — see the plan rationale in the
script's header comment. Since they don't carry the SSH/corosync path,
they're much lower risk to convert; once you trust the rollback mechanism
from the exercises above, migrating those can follow the same manual
pattern (`OVSBridge` + `OVSPort`/`OVSBond`, no `OVSIntPort` needed since
there's no host IP) without needing the dead-man's-switch machinery at all
— just verify VM connectivity afterward instead of SSH/corosync.

## Quick reference

```
./proxmox-ovs-migrate.sh --dry-run
./proxmox-ovs-migrate.sh --apply [--rollback-after=15] [--simple] [--mgmt-vlan=N]
./proxmox-ovs-migrate.sh --status
./proxmox-ovs-migrate.sh --confirm --backup-dir=<path>
./proxmox-ovs-migrate.sh --abort-now --backup-dir=<path>
```
