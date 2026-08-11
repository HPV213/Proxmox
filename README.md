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

## OVS migration

`scripts/proxmox-ovs-migrate.sh` migrates a node's **management bridge**
(the one carrying your current SSH session's IP, normally also the
corosync ring) from a Linux bridge to Open vSwitch. This is a high-risk,
hard-to-reverse-if-wrong change, so the script:

- only ever touches that one bridge, never other VM-only vmbr's
- refuses to run unless it can confidently classify the current setup
  (single NIC or a Linux bond in a supported mode, static IP, no existing
  VLAN tagging, no SDN zones)
- stages the change via the Proxmox API and shows a real diff before
  applying anything (`--dry-run`, the default)
- when applying, backs up the current config and arms an **unattended
  rollback timer** before touching the network, which only gets cancelled
  once you explicitly confirm from a separate session

**Do not `curl | bash` this one.** Download it, read it, then run it from a
local copy:

```sh
curl -fsSLo proxmox-ovs-migrate.sh https://raw.githubusercontent.com/HPV213/Proxmox/main/scripts/proxmox-ovs-migrate.sh
chmod +x proxmox-ovs-migrate.sh
./proxmox-ovs-migrate.sh --dry-run
```

Read **`docs/ovs-migration-runbook.md`** before your first `--apply` — it
covers the pre-flight checklist, the cases the script deliberately refuses
to touch, and the multi-node cluster rollout sequence.

## OVS / cluster health check

`scripts/proxmox-ovs-verify.sh` is read-only: prints `ovs-vsctl show`
output, cluster quorum status, and current IP config. Safe to run anytime,
including as a healthcheck before/after a migration.

```sh
curl -fsSL https://raw.githubusercontent.com/HPV213/Proxmox/main/scripts/proxmox-ovs-verify.sh | bash
```

## Host performance tuning

`scripts/proxmox-host-tune.sh` applies safe, fully-reversible sysctl
tuning (network throughput, memory/VM-density) and enables KSM. It never
touches anything that can affect network reachability, so unlike the OVS
migration script it needs no rollback timer.

```sh
curl -fsSL https://raw.githubusercontent.com/HPV213/Proxmox/main/scripts/proxmox-host-tune.sh | bash
```

Undo with `./proxmox-host-tune.sh --revert` (run from a local copy, or
just re-download and run with the flag).

For kernel selection, NUMA/CPU pinning, hugepages, and virtio multiqueue —
which need a reboot or are too workload-specific to script safely — see
**`docs/performance-tuning-runbook.md`** instead.
