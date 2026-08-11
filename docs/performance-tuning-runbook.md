# Proxmox host performance tuning runbook (manual — not scripted)

Covers kernel selection, NUMA/CPU pinning, hugepages, and virtio multiqueue.
For sysctl/KSM tuning that's safe to script, see `scripts/proxmox-host-tune.sh`
instead.

## 0. Why these are manual, not scripted

- **Kernel changes need a reboot.** On a node with no console/IPMI access,
  a kernel that fails to boot cleanly has no automated recovery path — the
  only thing that can save you is the bootloader's own fallback mechanism
  (see §1.3), not anything a script running from inside the OS can arrange.
- **NUMA/hugepages/CPU pinning are workload-specific.** Applying them
  blindly on an already-running production host can starve currently-running
  VMs of ordinary memory or CPU. There's no safe generic default to script.

## 1. Kernel selection

### 1.1 Check what's installed / running

```
pveversion -v
proxmox-boot-tool kernel list
uname -r
```

### 1.2 Decision criteria

Stay on the **default/stable kernel** for production unless you have a
specific reason:

- A vendor release note or hardware compatibility list says you need a
  newer kernel for a specific NIC/HBA/GPU.
- You're chasing a fix for a CVE or bug that's only patched in a newer
  kernel.

If neither applies, don't opt in just because a newer kernel exists.
Proxmox's own guidance across recent 6.x/7.x kernel opt-ins has consistently
been "stay on the default for production, test opt-in kernels on similar
non-production hardware first."

### 1.3 Boot-failure safety net — check this BEFORE touching kernel version

This is the only thing that can rescue a hung boot when you have no
console:

```
bootctl status
```

- **systemd-boot**: has boot-counting/fallback built in — a kernel that
  fails to boot a configured number of times automatically falls back to
  the previous entry. Confirm this is actually active before relying on it.
- **GRUB**: has no automatic fallback by default. If this node uses GRUB,
  treat any kernel change as needing physical presence or a maintenance
  window with someone who can reach the console, full stop.

### 1.4 Applying

```
proxmox-boot-tool kernel pin <version>
proxmox-boot-tool refresh
reboot
```

### 1.5 If the new kernel boots but misbehaves

```
proxmox-boot-tool kernel pin <previous-version>
proxmox-boot-tool refresh
reboot
```

### 1.6 Test on spare/non-production hardware first

Same hardware generation if at all possible — kernel/driver issues are
often hardware-specific and won't show up on dissimilar test gear.

## 2. NUMA topology and CPU pinning

### 2.1 Discovery

```
lscpu
numactl --hardware
numastat -m
```

Only worth doing if NUMA node count > 1. On a single-socket/single-NUMA-node
box this is a no-op.

### 2.2 Decision criteria

Worth it for VMs whose CPU/memory footprint approaches or exceeds what a
single NUMA node provides — splitting such a VM across nodes means every
cross-node memory access pays a latency penalty. Not worth the complexity
for small VMs on a host with plenty of headroom per node.

### 2.3 Applying

```
qm set <vmid> --numa0 cpus=0-7,memory=16384,hostnodes=0,policy=bind
```

Check `numastat -m` for free memory **on the target node specifically**
before pinning — pinning without checking can cause the VM to swap instead
of the intended improvement, if that node doesn't actually have the RAM.

## 3. Hugepages

### 3.1 Static reservation at boot

Reserved via kernel cmdline, so it requires a reboot to take effect:

```
hugepagesz=1G hugepages=<N> default_hugepagesz=1G
```

Where to put it depends on the bootloader (check with `bootctl status` /
`efibootmgr`, same as §1.3):

- **systemd-boot**: edit `/etc/kernel/cmdline`, then `proxmox-boot-tool refresh`.
- **GRUB**: edit `/etc/default/grub` (`GRUB_CMDLINE_LINUX_DEFAULT`), then `update-grub`.

### 3.2 Sizing

```
reserved_hugepage_memory <= total_RAM - host_reserve - memory_already_used_by_other_VMs
```

Leave real headroom for the host itself (ZFS ARC if in use, PVE services,
backup jobs) — don't size hugepages against total RAM.

### 3.3 Per-VM enablement

```
qm set <vmid> --hugepages 1024
```

Verify the exact option syntax against `man qm.conf` on the actual
host/PVE version before relying on this from memory.

### 3.4 Danger on an already-running host

Reserving hugepages locks that RAM away from the normal page pool
**immediately** once applied (and it only applies at boot, so this really
means: at the next reboot). Only do this when VMs are already
stopped/migrated off, or after confirming (`free -h`) there's ample free
headroom that isn't currently backing a running VM's memory.

## 4. Virtio multiqueue (per-VM, not host-level)

There's no host-level setting for this — it's configured per network
device, per VM, and only takes effect once the guest also enables it.

### 4.1 Host/VM config side

```
qm set <vmid> -net0 virtio,bridge=vmbr0,queues=N
```

Start at `N = min(vCPU count, 4)`, and never exceed the VM's vCPU count —
more queues than vCPUs just adds overhead with no benefit.

### 4.2 Guest side (required — the host setting alone does nothing)

```
ethtool -L <guest-iface> combined N
```

### 4.3 If also using CPU pinning

Check IRQ affinity / vCPU affinity together — multiqueue's benefit comes
from spreading interrupt handling across cores, which interacts with
whatever pinning is already in place. Verify with `cat /proc/interrupts`
inside the guest that queues are actually landing on distinct vCPUs.

## 5. General cautions

- First-ever change of any kind in this document, on this hardware: do it
  on spare hardware first, not production.
- For the kernel change specifically, be physically present (or have
  someone who can be) for the first attempt on new hardware, regardless of
  what `bootctl status` reports — verify the fallback actually works before
  trusting it unattended.
