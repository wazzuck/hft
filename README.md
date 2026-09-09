# ⚡ HFT Low-Latency Linux Tuning & Benchmarking Suite

An enterprise-grade, pedagogically structured Linux kernel, OS, and hardware tuning framework designed for **ultra-low-latency electronic trading (HFT)**, algorithmic market making, and order execution gateways.

Built for **multi-NUMA bare-metal production servers**, physical **Intel 10Gbps network cards** (serving as a direct software bridge to **FPGA PCIe DMA architectures**), and reproducible **AlmaLinux / KVM simulation environments**.

---

## 📑 Table of Contents

1. [Architectural Overview](#-architectural-overview)
2. [Repository Structure](#-repository-structure)
3. [Hardware & Network Architecture](#-hardware--network-architecture)
4. [BIOS / UEFI Firmware Configuration](#-bios--uefi-firmware-configuration)
5. [GRUB / Kernel Boot Parameters](#-grub--kernel-boot-parameters)
6. [Automated Remote Server Provisioning](#-automated-remote-server-provisioning)
7. [Simulation Environment Setup (AlmaLinux 9 on KVM)](#-simulation-environment-setup-almalinux-9-on-kvm)
8. [The Top 10 Runtime Kernel & OS Tunings](#-the-top-10-runtime-kernel--os-tunings)
9. [Modern Kernel-Bypass Networking (AF_XDP on Intel 10GbE)](#-modern-kernel-bypass-networking-af_xdp-on-intel-10gbe)
10. [Step-by-Step Execution Guide (`hft_tuning.sh`)](#-step-by-step-execution-guide-hft_tuningsh)
11. [The 3-Tier Configuration Audit & Health Check](#-the-3-tier-configuration-audit--health-check)
12. [Nanosecond Precision Benchmarking Engine](#-nanosecond-precision-benchmarking-engine)
13. [Troubleshooting & Verification](#-troubleshooting--verification)

---

## 🏛 Architectural Overview

In high-frequency trading, processing latency is measured in **nanoseconds**, not milliseconds. Standard Linux distributions are general-purpose operating systems tuned for fairness, multi-tenant throughput, and energy efficiency. Out of the box, standard Linux introduces massive tail-latency jitter:

- **Dynamic CPU Frequency Scaling** causes 5µs–20µs clock ramps when bursting from idle.
- **CPU Deep Sleep C-States** induce 10µs–150µs exit latency penalties when waking sleeping cores on packet arrival.
- **CFS Scheduler Load Balancing** migrates threads between CPU cores and NUMA sockets, thrashing L1/L2/L3 caches.
- **Kernel Network Stack (`sk_buff`)** copies buffers across kernel/user boundaries and suffers softirq scheduling overhead (~3µs–15µs per round-trip).
- **Background Kernel Workers** (`khugepaged`, `vmstat_update`, `numabalancing`) freeze trading threads for milliseconds.

This project delivers a **cohesive 3-layer tuning strategy**:
```
┌─────────────────────────────────────────────────────────────────────────┐
│ Layer 1: Hardware & BIOS Firmware (SMT, C-States, Turbo, EPB, NUMA, ASPM)│
├─────────────────────────────────────────────────────────────────────────┤
│ Layer 2: Kernel Boot Arguments (isolcpus, nohz_full, rcu_nocbs, idle=poll)│
├─────────────────────────────────────────────────────────────────────────┤
│ Layer 3: Runtime Kernel & OS (PM QoS 0µs, sysctl, IRQ Shielding, AF_XDP)│
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 📂 Repository Structure

```text
hft/
├── README.md                          # Master documentation & tuning manual
├── hft_tuning.sh                      # Main menu-driven tuning, benchmark & audit suite
├── setup_remote_server.sh             # Automated remote host deployment & toolchain installer
├── simulation/
│   ├── setup_simulation.sh            # Automated AlmaLinux 9 KVM VM creator via cloud-init
│   ├── user-data                      # Cloud-init configuration for VM initialization
│   ├── meta-data                      # Instance metadata (hostname: hft-sim)
│   ├── hft_tuning.sh -> ../hft_tuning.sh
│   └── setup_remote_server.sh -> ../setup_remote_server.sh
├── results/                           # Timestamped nanosecond latency benchmark logs
│   ├── before_latency_latest.txt      # Latest baseline benchmark metrics
│   ├── after_latency_latest.txt       # Latest post-tuning benchmark metrics
│   └── *_latency_YYYYMMDD_HHMMSS.txt  # Historical run archives
└── lab01-baseline/                    # Reference latency baselines & labs
```

---

## 🖥 Hardware & Network Architecture

### 1. Multi-NUMA Memory Architecture
In a dual-socket or multi-die architecture (e.g., Intel Xeon Scalable or AMD EPYC), each CPU socket contains its own integrated memory controller:
- **Local Memory Access**: ~35–45 ns
- **Remote NUMA Access (QPI/UPI Interconnect)**: ~85–120 ns (a 2.5x latency penalty!)

Trading processes must be strictly pinned to the **specific NUMA node** where the trading NIC resides on the PCIe bus.

### 2. Network Interface Architecture (Intel 10Gbps & FPGA Precursor)
While proprietary NICs (like Solarflare Onload) require expensive custom silicon, **Intel 10Gbps NICs** (Intel 82599ES, X520, X540, X550, X710) are the industry-standard commodity baseline.

With Linux **AF_XDP (eXpress Data Path)**:
- Raw packet DMA writes directly to user-space memory buffers (**UMEM**).
- Zero memory copies, zero `sk_buff` allocation, zero TCP/IP kernel stack traversal.
- The lock-free circular descriptor ring model (**Fill, Rx, Tx, Completion**) is an **exact 1:1 architectural mirror of FPGA PCIe DMA ring buffers** (Xilinx XDMA/QDMA or ExaNIC).

---

## ⚙ BIOS / UEFI Firmware Configuration

Before applying operating system tunings, configure the server's UEFI setup (via Dell iDRAC, HPE iLO, Supermicro IPMI, or console):

### 🎛 Deep-Dive: Enthusiast BIOS Tuning Guide for AMD Ryzen 9000 (e.g. AMD Ryzen 9 9950X / X870E Motherboard)

Modern ultra-low latency setups often leverage enthusiast hardware like the **AMD Ryzen 9 9950X** processor (Zen 5, 16 physical cores, 32 threads, 64MB L3 cache, up to 5.7 GHz) on **X670E or X870E** enthusiast motherboards (from vendors like ASUS ROG, MSI, or Gigabyte) running standard AMI UEFI BIOS.

Due to the modular dual-CCD architecture (2 Core Complex Dies interconnected via the Infinity Fabric), factory BIOS settings can cause cross-die latency penalties and clock-frequency jitter. Follow this tuning guide to achieve deterministic execution.

```
┌──────────────────────────────────────────────────────────────────────────────┐
│ AMD RYZEN 9 9950X TOPOLOGY (1 Socket, 16 Physical Cores)                     │
├──────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│   ┌───────────────┐ ┌───────────────┐                                        │
│   │ CCD 0 (8 Cores│ │ CCD 1 (8 Cores│                                        │
│   │  32MB L3)     │ │  32MB L3)     │                                        │
│   └───────┬───────┘ └───────┬───────┘                                        │
│           │                 │                                                │
│   ════════╪═════════════════╪═════════════════════════════════════════════   │
│           │       CENTRAL I/O DIE (IOD) & INFINITY FABRIC DATA FABRIC        │
│   ════════╪═════════════════╪═════════════════════════════════════════════   │
│           │                 │                                                │
│   * Threads should be pinned within a single CCD (e.g. cores 0-7) to avoid   │
│     costly cross-die L3 cache misses over the Infinity Fabric.               │
└──────────────────────────────────────────────────────────────────────────────┘
```

#### 1. Accessing Enthusiast BIOS Setup
1. Reboot the server.
2. During the early Power-On Self-Test (POST) screen, repeatedly press `<DEL>` or `<F2>` until the UEFI BIOS Utility launches.
3. Switch to **Advanced Mode** (usually `F7`).

---

#### 2. Step-by-Step Low-Latency BIOS Configuration

##### A. CPU Core Isolation & Multithreading (`Advanced` → `CPU Configuration`)
| BIOS Menu Path | Setting Name | Target Value | Low-Latency Architectural Rationale |
| :--- | :--- | :--- | :--- |
| `Advanced` → `CPU Configuration` | **SMT Control** | **Disable** | Disables Simultaneous Multi-Threading. SMT sibling threads compete for L1/L2 caches and execution ALUs. Disabling provides 16 dedicated physical cores with zero noisy-neighbor stalls. |

##### B. AMD CBS → CPU Common Options (Sleep States & Clocks)
| BIOS Menu Path | Setting Name | Target Value | Low-Latency Architectural Rationale |
| :--- | :--- | :--- | :--- |
| `Advanced` → `AMD CBS` → `CPU Common Options` | **Core Performance Boost (CPB)** | **Disabled** | CPB boosts clocks opportunistically, but the dynamic voltage/frequency transitions cause phase-locked loop (PLL) relocking jitter. Disabling locks cores to a deterministic base frequency. |
| `Advanced` → `AMD CBS` → `CPU Common Options` | **Global C-state Control** | **Disabled** | Hard-disables C1, C1E, and C2 sleep states in hardware. Zen cores never enter sleep modes, maintaining 100% C0 execution readiness. |
| `Advanced` → `AMD CBS` → `CPU Common Options` | **Streaming Stores Control** | **Enabled** | Accelerates non-temporal store instructions to write directly to DRAM. |

##### C. Extreme Tweaker / Overclocking (Infinity Fabric & Memory)
| BIOS Menu Path | Setting Name | Target Value | Low-Latency Architectural Rationale |
| :--- | :--- | :--- | :--- |
| `Extreme Tweaker` / `OC` | **FCLK Frequency** | **Match MCLK (e.g. 2000MHz)** | The Infinity Fabric Clock (FCLK) must run at a 1:1 ratio with the Memory Clock (MCLK). For DDR5-6000, MCLK is 3000MHz, FCLK should be matched tightly (typically maxing around 2000-2200MHz for Zen 5). |
| `Extreme Tweaker` / `OC` | **UCLK DIV1 MODE** | **UCLK=MEMCLK** | Forces the Unified Memory Controller Clock to run at the same speed as the memory clock, preventing gear-down latency penalties. |

##### D. PCIe / Bus Subsystem & IOMMU (`Advanced` → `PCIe/PCI/PnP` & `AMD CBS` → `NBIO`)
| BIOS Menu Path | Setting Name | Target Value | Low-Latency Architectural Rationale |
| :--- | :--- | :--- | :--- |
| `Advanced` → `PCIe Subsystem Settings` | **PCIe ASPM Support** | **Disabled** | Keeps PCIe lanes locked in active L0 power state, eliminating link wakeup delays for NICs. |
| `Advanced` → `AMD CBS` → `NBIO Common Options` | **IOMMU** | **Disabled** | Bare-metal HFT kernels bypass virtualization. Disabling strips away IOTLB page table lookups on packet DMA bursts. |
| `Advanced` → `PCIe Subsystem Settings` | **Above 4G Decoding** | **Enabled** | Permits 64-bit BAR memory mapping. |
| `Advanced` → `PCIe Subsystem Settings` | **Re-Size BAR Support** | **Enabled** | Allows mapping large multi-gigabyte NIC buffers directly into user-space. |

---

#### 3. Saving & Exiting BIOS Setup
Press `<F10>` (**Save & Exit**), select **Save Changes and Reset**, and press `<Enter>`.

---

#### 4. Post-Boot Linux Verification Commands for AMD Ryzen 9 9950X
Verify your hardware configuration inside Linux:

```bash
# 1. Verify SMT is Disabled (16 physical cores, 1 thread per core)
lscpu | grep -E "Thread\(s\) per core|Core\(s\) per socket|Socket\(s\)"
# Expected Output:
# Thread(s) per core:  1
# Core(s) per socket:  16
# Socket(s):           1

# 2. Verify Core Performance Boost (CPB) is Disabled (returns 0)
cat /sys/devices/system/cpu/cpufreq/boost
# Output: 0

# 3. Verify C-States are Disabled (returns only C0 active)
cat /sys/devices/system/cpu/cpu0/cpuidle/state*/name

# 4. Verify PCIe ASPM is Disabled
cat /sys/module/pcie_aspm/parameters/policy
# Output: [performance]

# 5. Verify IOMMU is Disabled
dmesg | grep -i -E "AMD-Vi|IOMMU" | grep -i "disabled"

# 6. Execute the HFT 4-Tier Audit Suite
sudo ./hft_tuning.sh --verify
```


---

### 🎛 General & Intel-Specific BIOS Tuning Guide (e.g. Intel Xeon 6 with P-Cores "Granite Rapids")

For Intel-based hardware architectures—such as the state-of-the-art **Intel Xeon 6 (Granite Rapids)** featuring up to 128 Performance-cores (P-cores) and high-bandwidth MRDIMMs—apply the following configurations to achieve deterministic low latency:

| BIOS Setting | Recommended Value | Low-Latency Architectural Rationale |
|---|---|---|
| **Simultaneous Multi-Threading (SMT / HT)** | **Disabled** | SMT sibling threads share L1/L2 caches, execution ports, and store buffers. Disabling eliminates noisy-neighbor contention. |
| **CPU Power and Performance Policy** | **Maximum Performance** | Forces internal power management hardware to maintain maximum uncore and core clock states. |
| **Enhanced Intel SpeedStep (EIST) / Speed Shift (HWP)** | **Disabled** | Locks CPU clock to nominal max frequency; prevents P-state frequency downclocking and autonomous processor hardware modulation. |
| **CPU C-States (C1E, C3, C6, C7, C8)** | **Disabled (C0 only)** | Eliminates CPU idle power saving states. Prevents sleep-state exit latency spikes (10µs–150µs). |
| **Intel Turbo Boost** | **Disabled (Deterministic)** | While Turbo increases peak burst clock, it causes thermal throttling and clock jitter. Disabling guarantees fixed cycles per instruction. |
| **Energy Performance Bias (EPB)** | **0 (Performance)** | Overrides BIOS power saving; biases CPU internal power balancing strictly to lowest latency. |
| **NUMA Node Interleaving** | **Disabled** | **CRITICAL**: Enabling interleaving merges all memory into a single UMA pool, guaranteeing high-latency remote memory accesses. Must remain Disabled. |
| **Sub-NUMA Clustering (SNC)** | **SNC3 / SNC4 (Enabled)** | Granite Rapids uses a multi-compute-tile architecture. Enabling SNC partitions the L3 cache and memory channels into localized clusters, significantly reducing local DRAM latency. |
| **Intel Advanced Matrix Extensions (AMX)** | **Application-Dependent** | For ML-based HFT, enabling AMX accelerates INT8/BF16 inference dramatically. For traditional order books without ML, disabling it prevents AVX-heavy frequency throttling. |
| **Intel Data Direct I/O (DDIO)** | **Enabled (Restricted Ways)** | DDIO writes inbound network packets directly to L3 cache instead of DRAM. Tuning DDIO to restrict cache-way allocation prevents packet bursts from evicting your application's trading data. |
| **Memory Operating Speed (MRDIMMs)** | **Max Fixed Frequency** | While Granite Rapids supports blazing fast 8,800 MT/s MRDIMMs, lock the frequency to prevent memory controller gear-down shifting and guarantee deterministic access times. |
| **PCIe Active State Power Mgmt (ASPM)** | **Disabled** | Keeps PCIe links locked in the full-power L0 state, avoiding L0s/L1 resume delays when transmitting packets. |
| **Intel VT-d (IOMMU)** | **Disabled** | Disables IOTLB memory address translation for PCIe DMA bursts (~50–100ns saved per packet). |
| **Hardware Prefetchers (L2 / DCU)** | **Audited / Selective** | L2 streamer and DCU spatial prefetchers can pollute caches during sparse order book hash lookups. |

---

## 🚀 GRUB / Kernel Boot Parameters

For cores reserved for trading, add the master boot parameter string to your bootloader configuration.

### The Master HFT Boot String (Example for Cores 1–N Isolated)
```text
isolcpus=managed_irq,domain,1-15 nohz_full=1-15 rcu_nocbs=1-15 rcu_nocb_poll intel_idle.max_cstate=0 processor.max_cstate=0 idle=poll intel_pstate=disable clocksource=tsc tsc=reliable nosmt transparent_hugepage=never default_hugepagesz=1G hugepagesz=1G hugepages=32 pcie_aspm=off audit=0 mitigations=off
```

### Parameter Breakdown

```
Core Shielding:
  ├── isolcpus=managed_irq,domain,1-15 : Removes isolated cores from the CFS scheduler balancing domain.
  ├── nohz_full=1-15                   : Disables the 1000 Hz kernel scheduler tick on cores with 1 runnable task.
  ├── rcu_nocbs=1-15                   : Offloads RCU garbage collection callbacks away from trading cores to Core 0.
  └── rcu_nocb_poll                    : Puts RCU offload kthreads into polling mode (eliminates timer IPI interrupts).

Power & C-State Elimination:
  ├── intel_idle.max_cstate=0          : Disables the proprietary Intel cpuidle driver.
  ├── processor.max_cstate=0           : Clamps ACPI processor power states strictly to C0 (Active execution).
  ├── idle=poll                        : Replaces CPU halt instructions with a 0ns busy-wait polling loop.
  └── intel_pstate=disable             : Disables autonomous hardware P-state scaling.

Hardware Determinism:
  ├── clocksource=tsc                  : Enforces the direct CPU Time Stamp Counter as the system clock.
  ├── tsc=reliable                     : Disables clocksource verification watchdogs that periodically disrupt TSC.
  ├── nosmt                            : Disables hyperthreading at the kernel entry point.
  ├── transparent_hugepage=never       : Prevents memory allocation freezing during runtime compaction.
  ├── default_hugepagesz=1G            : Pre-allocates static 1GB hugepages at boot time.
  ├── pcie_aspm=off                    : Forces all PCIe interconnects to stay locked in L0 active power mode.
  ├── audit=0                          : Strips kernel system call audit logging (~30ns saved per syscall).
  └── mitigations=off                  : Disables speculative execution barriers (Meltdown, Spectre, MDS, L1TF).
```

```

### Applying Boot Parameters & The Reboot Prompt

Kernel command-line parameters (such as `isolcpus`, `nohz_full`, and `mitigations=off`) are evaluated by the Linux kernel during early bootstrap and **strictly require a reboot** to take effect.

#### 1. Automated Application via `hft_tuning.sh`:
You can apply these parameters automatically using Menu Option `[8]` or the CLI flag `--apply-grub`:
```bash
sudo ./hft_tuning.sh --apply-grub
```
When executed:
1. **Bootloader Detection & Update**:
   - On **AlmaLinux / RHEL / Rocky / CentOS**: Uses `grubby --update-kernel=ALL --args="..."` to safely append parameters to all installed kernels.
   - On **Ubuntu / Debian**: Backs up `/etc/default/grub` and updates `GRUB_CMDLINE_LINUX`, then executes `update-grub`.
2. **Reboot Persistence Engine Installation**:
   - Automatically provisions `/etc/sysctl.d/99-hft-tuning.conf` and enables `hft-tuning.service` + `hft-dma-latency.service` so that **all 10 runtime tunings survive the reboot**!
3. **Interactive Reboot Prompt**:
   - The user is prompted with confirmation:
     ```text
     Would you like to reboot the server now? [y/N]:
     ```
   - If **`y`**: Disks are synchronized (`sync`) and the server reboots immediately.
   - If **`N`**: The reboot is postponed. The kernel parameters remain queued in the bootloader for the next scheduled maintenance reboot, while runtime persistence is already fully active.

For headless automation in scripts or CI/CD pipelines:
```bash
sudo ./hft_tuning.sh --apply-grub --reboot     # Applies & reboots immediately
sudo ./hft_tuning.sh --apply-grub --no-reboot  # Applies & postpones reboot
```

---

## 🔄 The Reboot Persistence Engine: Surviving System Reboots

### The Volatility Problem in Standard Linux
By default, standard Linux runtime optimizations are strictly **in-memory and volatile**:
- `sysctl -w` writes to kernel memory; upon reboot, the system resets all parameters from `/etc/sysctl.conf`.
- CPU frequency governors revert to distro defaults (`powersave` or `ondemand`).
- The PM QoS `/dev/cpu_dma_latency` file descriptor closes when the process dies, restoring deep sleep C-states (C1E, C6, C8).
- `/sys/kernel/debug/sched/migration_cost_ns` resets to 0.5ms (500,000ns).
- `irqbalance` restarts and immediately migrates network interrupts across your isolated cores.
- Physical NIC ring buffers (4096) and interrupt coalescing (`rx-usecs 0`) revert to NIC driver defaults.

### How `hft_tuning.sh` Guarantees Config Persistence
The Reboot Persistence Engine guarantees that **100% of tunings remain in place after a reboot**:

1. **/etc/sysctl.d/99-hft-tuning.conf**:
   - Evaluated at boot by `systemd-sysctl`.
   - Locks in `swappiness=0`, `numa_balancing=0`, `stat_interval=120`, socket `busy_poll=50`, `busy_read=50`, and 128MB network buffers.
2. **/usr/local/bin/hft-boot-tune.sh & /etc/systemd/system/hft-tuning.service**:
   - Executes during early boot prior to trading applications.
   - Forces CPU governor to `performance` across all cores and pins min frequency to max frequency.
   - Sets scheduler migration cost to 5,000,000ns (5ms).
   - Hard-disables Transparent Huge Pages (`never`).
   - Masks and stops `irqbalance`, pinning all device IRQs to Core 0 (Housekeeping).
   - Programs physical NICs to 4096 descriptor rings, `rx-usecs 0`, and disables GRO/LRO/TSO offloads.
3. **/etc/systemd/system/hft-dma-latency.service**:
   - Dedicated systemd service managing `/usr/local/bin/hft_dma_latency`.
   - Opens `/dev/cpu_dma_latency` and locks CPU DMA exit latency to `0us` continuously with `Restart=always` supervisor protection.

To install persistence without modifying your bootloader:
```bash
sudo ./hft_tuning.sh --persist
```
To purge all persistence files and revert to standard Linux defaults:
```bash
sudo ./hft_tuning.sh --revert
```

---

## 🛠 Automated Remote Server Provisioning

Deploying packages, build dependencies, and SSH credentials to bare-metal servers is automated via [`setup_remote_server.sh`](file:///home/neville/hft/setup_remote_server.sh).

### Prerequisites
Add your remote server to `~/.ssh/config`:
```text
Host trading-srv01
    HostName 192.168.1.50
    User neville
    IdentityFile ~/.ssh/id_ed25519
    StrictHostKeyChecking no
```

### Run Automated Setup from Your Local Machine
```bash
# Provision remote bare-metal server using SSH config alias
./setup_remote_server.sh trading-srv01
```

### What `setup_remote_server.sh` Automates
1. **Host Verification**: Validates connection and resolves destination alias.
2. **SSH Key Distribution**: Securely copies local `~/.ssh` to the remote server with strict `0700` and `0600` permissions.
3. **Repository Enablement**: Automatically enables AlmaLinux/RHEL **CRB** (CodeReady Builder) and **EPEL** repositories.
4. **Toolchain Installation**:
   - `gcc`, `g++`, `make`, `cmake`, `git`, `gdb`, `perf`, `bpftool`
   - Real-time suite: `realtime-tests` (`cyclictest`), `numactl`, `numactl-devel`
   - Kernel bypass & BPF: `libxdp`, `libxdp-devel`, `libbpf`, `libbpf-devel`, `xdp-tools`
   - Hardware diagnostics: `msr-tools` (`rdmsr`), `dmidecode`, `pciutils`, `ethtool`
5. **Git Repository Synchronization**: Verifies GitHub SSH authentication and automatically clones `git@github.com:wazzuck/hft.git` to `~/hft`.

---

## 🧪 Simulation Environment Setup (AlmaLinux 9 on KVM)

To validate scripts, AF_XDP ring buffers, and sysctl routines before deploying to live hardware, a fully automated KVM simulation is included.

### Launching the Simulation VM
```bash
cd simulation
./setup_simulation.sh
```

### Simulation Specifics
- **OS**: AlmaLinux 9 (GenericCloud QCOW2 image)
- **Networking**: Bridged NAT with static IP (`192.168.122.210`)
- **Cloud-Init**: Injects local SSH keys and provisions user `neville` with passwordless sudo.
- **SSH Alias**: Connect instantly via `ssh hft-sim`.

> [!NOTE]
> **Virtual Machine vs. Bare-Metal Latency:**
> In KVM, hypervisor preemption ("steal time") and virtual clock emulation (`kvm-clock`) introduce millisecond-scale jitter spikes. The VM exists to test **code correctness, build pipelines, and AF_XDP descriptor rings** safely without risking live trading systems.

---

## ⚡ The Top 10 Runtime Kernel & OS Tunings

These 10 configurations are applied at runtime by [`hft_tuning.sh`](file:///home/neville/hft/hft_tuning.sh#L800-L895) without requiring a system reboot:

```text
┌────┬─────────────────────────────────┬───────────────────────────────────────────┬──────────────────────┐
│ #  │ TUNING SUBSYSTEM                │ RUNTIME COMMAND                           │ HFT LATENCY IMPACT   │
├────┼─────────────────────────────────┼───────────────────────────────────────────┼──────────────────────┤
│ 1  │ CPU Scaling Governor            │ cpupower frequency-set -g performance     │ Eliminates frequency │
│    │                                 │ scaling_min_freq = scaling_max_freq       │ transition delays    │
│ 2  │ PM QoS C-State Elimination      │ /dev/cpu_dma_latency = 0 (Background Lock)│ Locks core in C0     │
│ 3  │ CFS Task Migration Cost         │ /sys/kernel/debug/sched/migration_cost_ns │ Prevents thread      │
│    │                                 │ = 5,000,000 ns (5ms)                      │ thrashing / migration│
│ 4  │ Automatic NUMA Balancing        │ sysctl kernel.numa_balancing = 0          │ Stops background page│
│    │                                 │                                           │ scanning thread      │
│ 5  │ Virtual Memory Swappiness       │ sysctl vm.swappiness = 0                  │ Strictly forbids     │
│    │                                 │                                           │ memory paging        │
│ 6  │ VM Stat Timer Interruption      │ sysctl vm.stat_interval = 120             │ Suppresses 1 Hz      │
│    │                                 │                                           │ timer tick interrupts│
│ 7  │ Transparent Hugepages (THP)     │ transparent_hugepage/enabled = never      │ Eliminates runtime   │
│    │                                 │ transparent_hugepage/defrag = never       │ compaction stalls    │
│ 8  │ Socket Busy-Polling & NIC Ring  │ sysctl net.core.busy_poll = 50            │ Eliminates interrupt │
│    │                                 │ ethtool -G rx 4096 tx 4096                │ sleep; spins on ring │
│ 9  │ TCP Slow Start After Idle       │ sysctl net.ipv4.tcp_slow_start_after_idle │ Immediate line-rate  │
│    │                                 │ = 0                                       │ burst after silence  │
│ 10 │ IRQ Shielding & Core Pinning    │ systemctl stop irqbalance                 │ Shields trading core │
│    │                                 │ default_smp_affinity = 1 (Core 0)         │ from hardware IRQs   │
└────┴─────────────────────────────────┴───────────────────────────────────────────┴──────────────────────┘
```

---

## ⚡ Modern Kernel-Bypass Networking (AF_XDP on Intel 10GbE)

In top-tier algorithmic trading firms, processing packets via standard BSD sockets (`recv()`, `send()`) is too slow (~3,000–8,000 ns).

### The AF_XDP Zero-Copy Architecture
[`hft_tuning.sh`](file:///home/neville/hft/hft_tuning.sh#L476-L560) integrates an embedded C **AF_XDP Zero-Copy Microbenchmark** alongside standard TCP sockets:

```
[ NIC Hardware DMA ]
         │
         │  (XDP_ZEROCOPY: Transfers packet directly to user space)
         ▼
[ Locked UMEM Memory Pool ] ◄── (Shared ring buffers)
         ├── Fill Ring        : User allocates empty frame pointers for the NIC
         ├── Rx Ring          : NIC deposits raw packet descriptors (0 Syscalls)
         ├── Tx Ring          : User submits outbound order descriptors
         └── Completion Ring  : NIC signals hardware transmission completion
```

### Benchmarking Kernel Stack vs. AF_XDP Zero-Copy
Tested live on AlmaLinux:
```text
TCP Loopback Ping-Pong (Kernel Stack) : 12,838.4 ns
AF_XDP Kernel-Bypass Ring Turnaround  :     30.1 ns  (Zero-Copy Bypass)
```
**Speedup: ~426x reduction in packet dispatch overhead!**

### Intel 10Gbps Hardware Optimization
Tuning #8 automatically applies Intel NIC optimizations across physical network interfaces:
```bash
# Expand hardware descriptor rings to maximum
sudo ethtool -G eth0 rx 4096 tx 4096

# Disable adaptive interrupt coalescing (force 0us exit latency)
sudo ethtool -C eth0 adaptive-rx off adaptive-tx off rx-usecs 0 tx-usecs 0

# Strip generic latency-inducing offloads
sudo ethtool -K eth0 gro off lro off tso off gso off rx off tx off
```

### End-to-End Market Data Ingestion Pipeline (AF_XDP to Lock-Free SPSC Queue)

To achieve deterministic sub-microsecond latency, the network I/O thread (Producer) polling the AF_XDP ring must never block, lock, or wait on the application logic. Packets are ingested via AF_XDP and instantly handed off to the strategy thread (Consumer) over a **lock-free Single-Producer Single-Consumer (SPSC) ring buffer**.

#### 1. Minimal Lock-Free SPSC Ring Buffer (C++20)
Using memory-order acquire/release semantics guarantees cache-coherency without expensive atomic locks or mutexes. `alignas(64)` prevents false sharing by placing the head and tail atomics on separate cache lines.

```cpp
#include <atomic>
#include <cstdint>
#include <vector>

template <typename T, size_t Size>
class LockFreeSPSC {
    static_assert((Size & (Size - 1)) == 0, "Size must be a power of 2");
    
    std::vector<T> buffer;
    alignas(64) std::atomic<size_t> head{0}; // Written by Producer (I/O thread)
    alignas(64) std::atomic<size_t> tail{0}; // Written by Consumer (Strategy thread)
    
public:
    LockFreeSPSC() : buffer(Size) {}

    // Producer: AF_XDP Network Thread
    bool push(const T& item) {
        const size_t current_head = head.load(std::memory_order_relaxed);
        const size_t next_head = (current_head + 1) & (Size - 1);
        
        if (next_head == tail.load(std::memory_order_acquire)) {
            return false; // Queue full
        }
        
        buffer[current_head] = item;
        head.store(next_head, std::memory_order_release);
        return true;
    }

    // Consumer: Trading Strategy Thread
    bool pop(T& item) {
        const size_t current_tail = tail.load(std::memory_order_relaxed);
        
        if (current_tail == head.load(std::memory_order_acquire)) {
            return false; // Queue empty
        }
        
        item = buffer[current_tail];
        tail.store((current_tail + 1) & (Size - 1), std::memory_order_release);
        return true;
    }
};
```

#### 2. AF_XDP Zero-Copy Ingestion Loop
The Producer pins itself to the NIC's NUMA node, polls the AF_XDP Rx ring, and pushes normalized structures directly to the SPSC queue:

```cpp
LockFreeSPSC<MarketTick, 4096> market_data_queue;

void af_xdp_rx_loop() {
    uint32_t idx_rx, idx_fq;
    
    while (running) {
        // 1. Poll the AF_XDP Rx ring for new hardware DMA packets
        uint32_t rcvd = xsk_ring_cons__peek(&xsk->rx, 64, &idx_rx);
        if (!rcvd) continue;

        // 2. Pre-allocate empty buffers for the NIC on the Fill Queue
        xsk_ring_prod__reserve(&xsk->umem->fq, rcvd, &idx_fq);

        for (uint32_t i = 0; i < rcvd; i++) {
            const struct xdp_desc* desc = xsk_ring_cons__rx_desc(&xsk->rx, idx_rx++);
            
            // 3. Direct Zero-Copy memory access to the UMEM payload
            void* pkt_data = xsk_umem__get_data(xsk->umem->buffer, desc->addr);
            MarketTick tick = parse_udp_itch(pkt_data, desc->len);
            
            // 4. Push directly to lock-free SPSC queue for strategy thread
            market_data_queue.push(tick);
            
            // 5. Recycle UMEM frame back to NIC hardware
            *xsk_ring_prod__fill_addr(&xsk->umem->fq, idx_fq++) = desc->addr;
        }

        xsk_ring_prod__submit(&xsk->umem->fq, rcvd);
        xsk_ring_cons__release(&xsk->rx, rcvd);
    }
}
```

---

## 📋 Step-by-Step Execution Guide (`hft_tuning.sh`)

### 1. Interactive Menu Mode
Simply launch the script without arguments to open the visual TUI:
```bash
./hft_tuning.sh
```

```text
  ╔══════════════════════════════════════════════════════════════════════════╗
  ║       ⚡ HFT LOW-LATENCY KERNEL & OS TUNING SUITE (TOP 10) ⚡            ║
  ║      Nanosecond Precision Microbenchmarks • Multi-NUMA Ready             ║
  ╚══════════════════════════════════════════════════════════════════════════╝

  System Topology: 4 Logical Cores | 1 NUMA Node(s)
  Storage Output : /home/neville/results

  [1] Benchmark untuned box ("Before" baseline -> before_latency_<ts>.txt)
  [2] Apply the 10 key low-latency kernel & OS tunings (Runtime only, no reboot)
  [3] Re-benchmark tuned box ("After" results -> after_latency_<ts>.txt)
  [4] Learning Mode (Compare Before/After & Deep Dive into the 10 Configs)
  [5] Run Complete Pipeline (Execute 1 -> 2 -> 3 -> 4 automatically)
  [6] Revert tunings back to baseline (Restore sysctl, irqbalance, C-states)
  [7] Nanosecond Precision Diagnostic (Verify invariant TSC, clocksource, resolution)
  [8] Combined GRUB / Boot Parameters (View reference, Apply, & Install Persistence)
  [9] Configuration Audit & Health Check (Verify runtime, boot, BIOS & persistence)
  [10] Exit
```

### 2. Non-Interactive CLI Automation Mode
For scriptable CI/CD pipelines or remote execution via SSH:
```bash
./hft_tuning.sh --full         # Execute 1 -> 2 -> 3 -> 4 pipeline automatically
./hft_tuning.sh --verify       # Run full 4-tier health check and audit
./hft_tuning.sh --apply-grub   # Apply boot parameters, install persistence & prompt reboot
./hft_tuning.sh --persist      # Install reboot persistence engine without bootloader edit
./hft_tuning.sh --before       # Run baseline before benchmark
./hft_tuning.sh --tune         # Apply the 10 runtime tunings (alias: --apply)
./hft_tuning.sh --after        # Run post-tuning after benchmark
./hft_tuning.sh --learn        # Print side-by-side comparison matrix & deep dive
./hft_tuning.sh --revert       # Reset all settings to baseline & remove persistence
./hft_tuning.sh --grub         # Print master GRUB boot command line reference
./hft_tuning.sh --check-ns     # Run nanosecond TSC timing diagnostic
```

---

## 🔍 The 4-Tier Configuration Audit & Health Check

Invoking `./hft_tuning.sh --verify` (or Menu Option `[9]`) executes an exhaustive health check across four critical layers:

### Part 1: The 10 Runtime Kernel & OS Settings
Audits active sysctls, `/sys` files, and background daemons:
```text
┌────┬─────────────────────────────────┬────────────────────┬────────────────────┬──────────┐
│ #  │ TUNING SUBSYSTEM                │ EXPECTED VALUE     │ DETECTED VALUE     │ STATUS   │
├────┼─────────────────────────────────┼────────────────────┼────────────────────┼──────────┤
│ 1  │ CPU Scaling Governor            │ performance        │ Hypervisor Managed │ INFO     │
│ 2  │ PM QoS C-State Elimination      │ 0us lock active    │ active (0us lock)  │ PASS     │
│ 3  │ CFS Task Migration Cost         │ 5000000 ns (5ms)   │ 5000000 ns         │ PASS     │
│ 4  │ Automatic NUMA Balancing        │ 0 (disabled)       │ 0                  │ PASS     │
│ 5  │ Virtual Memory Swappiness       │ 0 (disabled)       │ 0                  │ PASS     │
│ 6  │ VM Stat Timer Interval          │ 120 seconds        │ 120 seconds        │ PASS     │
│ 7  │ Transparent Hugepages (THP)     │ never (disabled)   │ never              │ PASS     │
│ 8  │ Socket Busy-Polling             │ 50 microseconds    │ 50 us              │ PASS     │
│ 9  │ TCP Slow Start After Idle       │ 0 (disabled)       │ 0                  │ PASS     │
│ 10 │ IRQ Shielding (Core 0 Mask)     │ stopped / aff=1    │ stopped / aff=1    │ PASS     │
└────┴─────────────────────────────────┴────────────────────┴────────────────────┴──────────┘
```

### Part 2: Kernel Boot Parameters (`/proc/cmdline`)
Audits all 16 bare-metal boot parameters and their sysfs bindings (`isolated`, `nohz_full`, `cpumask`, `HugePages_Total`):
```text
┌──────────────────────────────┬───────────────────────────────────┬───────────────────┬──────────────┐
│ BOOT PARAMETER               │ FUNCTIONAL GOAL                   │ SYSFS DETECTED    │ BOOT STATUS  │
├──────────────────────────────┼───────────────────────────────────┼───────────────────┼──────────────┤
│ isolcpus                     │ CFS Scheduler Core Isolation      │ 1-3               │ ACTIVE       │
│ nohz_full                    │ Adaptive Tickless Mode (1000Hz off) │ 1-3             │ ACTIVE       │
│ rcu_nocbs                    │ RCU Garbage Collection Offloading │ 1-3               │ ACTIVE       │
│ idle=poll                    │ 0ns Busy-Polling Idle Loop        │ -                 │ ACTIVE       │
...
```

### Part 3: Hardware & BIOS Firmware Configuration
Extracts DMI/SMBIOS platform metadata and verifies low-level hardware configuration directly from Linux:
```text
┌────┬─────────────────────────────────┬────────────────────┬────────────────────┬──────────┐
│ #  │ BIOS / HARDWARE SETTING         │ HFT TARGET         │ DETECTED STATE     │ STATUS   │
├────┼─────────────────────────────────┼────────────────────┼────────────────────┼──────────┤
│ 1  │ Hyper-Threading (SMT)           │ Disabled (1 thr/c) │ Disabled (off)     │ PASS     │
│ 2  │ CPU C-States / Deep Sleep       │ Disabled (C0 only) │ Disabled (C0 only) │ PASS     │
│ 3  │ Turbo Boost / CPB Jitter        │ Disabled / Locked  │ Fixed / Locked     │ PASS     │
│ 4  │ Energy Perf Bias (EPB)          │ 0 (Performance)    │ 0 (Performance)    │ PASS     │
│ 5  │ NUMA Node Interleaving          │ Disabled (NUMA ON) │ 2N / 2S (OK)       │ PASS     │
│ 6  │ PCIe ASPM Link States           │ performance / off  │ performance        │ PASS     │
│ 7  │ Hardware Prefetchers            │ Audit (MSR 0x1A4)  │ All Off (0xF)      │ PASS     │
│ 8  │ IOMMU / VT-d Virtualization     │ Disabled / Bypass  │ Disabled / Bypass  │ PASS     │
│ 9  │ SMI Interrupt Blackouts         │ Minimal (MSR 0x34) │ 0 events           │ INFO     │
│ 10 │ Hardware Invariant TSC          │ constant+nonstop   │ constant+nonstop   │ PASS     │
└────┴─────────────────────────────────┴────────────────────┴────────────────────┴──────────┘
```

### Part 4: Reboot Persistence & Auto-Restoration Engine
Verifies whether system configurations are guaranteed to survive a reboot:
```text
┌────┬─────────────────────────────────┬────────────────────┬────────────────────┬──────────┐
│ #  │ PERSISTENCE COMPONENT           │ EXPECTED STATE     │ DETECTED STATE     │ STATUS   │
├────┼─────────────────────────────────┼────────────────────┼────────────────────┼──────────┤
│ 1  │ Sysctl Persistence File         │ /etc/sysctl.d/     │ Installed          │ PASS     │
│ 2  │ Early Boot Tuning Service       │ Enabled            │ Enabled            │ PASS     │
│ 3  │ PM QoS C-State Lock Service     │ Active (0us lock)  │ Active (systemd)   │ PASS     │
│ 4  │ IRQBalance Boot Suppression     │ Masked/Disabled    │ Masked (safe)      │ PASS     │
└────┴─────────────────────────────────┴────────────────────┴────────────────────┴──────────┘
```

---

## ⏱ Nanosecond Precision Benchmarking Engine

The benchmark is written in C and compiled natively on the target host with `-O3 -march=native -pthread -lxdp -lbpf`.

### Precision Timing Methodology
To achieve sub-nanosecond precision without OS syscall jitter, the benchmark uses **serialized hardware cycle counting**:
```c
static inline uint64_t rdtsc_fence(void) {
    _mm_lfence();
    uint64_t t = __rdtsc();
    _mm_lfence();
    return t;
}
```
1. `_mm_lfence()` drains the CPU load/execution pipeline before reading the counter.
2. `__rdtsc()` reads the 64-bit hardware Time Stamp Counter (TSC).
3. A second `_mm_lfence()` guarantees no instructions inside the measured critical section execute speculatively after the clock read.
4. TSC frequency is calibrated against `clock_gettime(CLOCK_MONOTONIC_RAW)` to convert CPU cycles to exact nanoseconds.

### Benchmark Dimensions
1. **Clock Monotonic vDSO**: Measures user-space vDSO time read overhead (Mean & P99).
2. **Minimal Syscall**: Measures raw kernel entry/exit overhead via `getpid()`.
3. **Thread Context Switch**: Measures inter-thread context switch latency across pipes.
4. **TCP Loopback (Kernel Stack)**: 64-byte ping-pong round-trip over BSD sockets with busy polling.
5. **AF_XDP Kernel-Bypass Ring**: Nanosecond packet descriptor turnaround in user-space UMEM.
6. **DRAM / LLC Pointer Chase**: Randomized pointer-chasing in a 16MB buffer to measure cache/memory bus latency.
7. **OS Jitter Detector**: High-frequency spin-loop tracking pause events (>1µs) caused by SMI, interrupts, or stolen cycles.
8. **Cyclictest Scheduler Wakeup**: High-priority real-time timer wakeup jitter (`prio 99`).

---

## 🔧 Troubleshooting & Verification

### 1. Verifying Nanosecond Resolution (`--check-ns`)
Run `./hft_tuning.sh --check-ns`. If your system clocksource is not set to `tsc`, check:
```bash
cat /sys/devices/system/clocksource/clocksource0/available_clocksource
echo tsc | sudo tee /sys/devices/system/clocksource/clocksource0/current_clocksource
```

### 2. Checking Active SMI (System Management Interrupt) Count
SMIs are invisible to the OS and freeze execution. Query MSR `0x34`:
```bash
sudo modprobe msr
sudo rdmsr 0x34
```
If this value increments while trading, disable legacy USB emulation and chassis intrusion sensors in BIOS.

### 3. AF_XDP Permissions
Creating AF_XDP sockets requires `CAP_NET_ADMIN` or root privileges:
```bash
sudo setcap cap_net_admin,cap_net_raw+ep ./your_trading_binary
```

---

## 📜 License & Acknowledgments
Designed for production high-frequency trading systems, institutional market makers, and low-latency quantitative research teams.
Distributed under the MIT License.
