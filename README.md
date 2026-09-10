# ⚡ HFT Low-Latency Linux Tuning & Benchmarking Suite

An enterprise-grade, pedagogically structured Linux kernel, OS, and hardware tuning framework designed for **ultra-low-latency electronic trading (HFT)**, algorithmic market making, and order execution gateways.

Built for **multi-NUMA bare-metal production servers**, physical **Intel 10Gbps network cards** (serving as a direct software bridge to **FPGA PCIe DMA architectures**), and reproducible **AlmaLinux / KVM simulation environments**.

> [!NOTE]
> **Why Intel NICs instead of FPGAs?** While tier-1 quantitative firms rely heavily on custom FPGAs (Field Programmable Gate Arrays) for sub-microsecond wire-to-wire execution, acquiring and licensing FPGA hardware requires massive institutional capital that is often inaccessible to independent developers or small prop shops. Therefore, this framework leverages **commodity Intel 10GbE NICs paired with Linux AF_XDP Zero-Copy**. This provides an affordable, software-defined architecture that perfectly mirrors the lock-free ring-buffer paradigms of an FPGA PCIe DMA engine, allowing you to develop and test ultra-low latency data pipelines on standard hardware.

> [!NOTE]
> **Hardware Testing Baseline & Production Deployment Architecture:**
> All benchmarking, kernel isolation routines, and tuning validations in this repository were tested and verified on a **single-NUMA node AMD Threadripper platform**, selected specifically because it provides the **highest sustained clock frequencies available** for deterministic tick-to-trade execution.
>
> In institutional production colocation, large-scale multi-exchange trading and market data systems frequently deploy **high-frequency, multi-NUMA node server platforms**—such as:
> - **AMD Ryzen Threadripper PRO 7000WX / 9000WX** (e.g., 7960X, 7975WX, 7985WX with 4/8-channel DDR5 and NPS2/NPS4 NUMA partitioning),
> - **AMD EPYC F-Series (Frequency-Optimized)** (e.g., EPYC 9174F, 9374F, 9575F with 12 memory channels and up to 5.0 GHz boost), or
> - **Intel Xeon 6 with P-Cores (Granite Rapids)** (utilizing Sub-NUMA Clustering SNC3/SNC4 with MRDIMMs).
>
> *\*Asterisk Notation on NUMA:* Throughout this document, any mention of multi-NUMA controls (such as `kernel.numa_balancing`, memory interleaving, or cross-socket NUMA node binding) marked with an asterisk (\*) is provided for enterprise multi-NUMA production servers and is **not required on high-frequency AMD Ryzen (or single-NUMA node Threadripper) architectures**, where all memory is routed uniformly through a single I/O Die (UMA).

---

## 📑 Table of Contents

1. [Architectural Overview](#-architectural-overview)
2. [Repository Structure](#-repository-structure)
3. [Hardware & Network Architecture](#-hardware--network-architecture)
4. [BIOS / UEFI Firmware Configuration](#-bios--uefi-firmware-configuration-amd-ryzen-9-9950x--x870e)
5. [GRUB / Kernel Boot Parameters](#-grub--kernel-boot-parameters)
6. [Automated Remote Server Provisioning](#-automated-remote-server-provisioning)
7. [Simulation Environment Setup (AlmaLinux 10 on KVM)](#-simulation-environment-setup-almalinux-10-on-kvm)
8. [The Top 10 Runtime Kernel & OS Tunings](#-the-top-10-runtime-kernel--os-tunings)
9. [Modern Kernel-Bypass Networking (AF_XDP on Intel 10GbE)](#-modern-kernel-bypass-networking-af_xdp-on-intel-10gbe)
10. [Step-by-Step Execution Guide (`hft_tuning.sh`)](#-step-by-step-execution-guide-hft_tuningsh)
11. [The 4-Tier Configuration Audit & Health Check](#-the-4-tier-configuration-audit--health-check)
12. [Nanosecond Precision Benchmarking Engine](#-nanosecond-precision-benchmarking-engine)
13. [Troubleshooting & Verification](#-troubleshooting--verification)

---

## 🏛 Architectural Overview

In high-frequency trading, processing latency is measured in **nanoseconds**, not milliseconds. Standard Linux distributions are general-purpose operating systems tuned for fairness, multi-tenant throughput, and energy efficiency. Out of the box, standard Linux introduces massive tail-latency jitter:

- **Dynamic CPU Frequency Scaling** causes 5µs–20µs clock ramps when bursting from idle.
- **CPU Deep Sleep C-States** induce 10µs–150µs exit latency penalties when waking sleeping cores on packet arrival.
- **CFS Scheduler Load Balancing** migrates threads between CPU cores and NUMA sockets*, thrashing L1/L2/L3 caches.
- **Kernel Network Stack (`sk_buff`)** copies buffers across kernel/user boundaries and suffers softirq scheduling overhead (~3µs–15µs per round-trip).
- **Background Kernel Workers** (`khugepaged`, `vmstat_update`, `numabalancing`*) freeze trading threads for milliseconds.

This project delivers a **cohesive 3-layer tuning strategy**:
```
┌─────────────────────────────────────────────────────────────────────────┐
│ Layer 1: Hardware & BIOS Firmware (SMT, C-States, Turbo, EPB, NUMA*, ASPM)│
├─────────────────────────────────────────────────────────────────────────┤
│ Layer 2: Kernel Boot Arguments (isolcpus, nohz_full, rcu_nocbs, idle=poll)│
├─────────────────────────────────────────────────────────────────────────┤
│ Layer 3: Runtime Kernel & OS (PM QoS 0µs, sysctl, IRQ Shielding, AF_XDP)│
└─────────────────────────────────────────────────────────────────────────┘
```
*\*Asterisk Note: Multi-NUMA tuning applies when deploying to multi-socket / multi-node server platforms; it is not required on high-frequency single-NUMA AMD Ryzen architectures.*

---

## 📂 Repository Structure

```text
hft/
├── README.md                          # Master documentation & tuning manual
├── hft_tuning.sh                      # Main menu-driven tuning, benchmark & audit suite
├── install.sh                         # Base installer for tmux, git, and Antigravity CLI (agy)
├── recreate_simulation.sh             # One-shot script to destroy, rebuild, provision VM & run install.sh
├── setup_remote_server.sh             # Automated remote host deployment & toolchain installer
├── simulation/
│   ├── setup_simulation.sh            # Automated AlmaLinux 10 KVM VM creator via cloud-init
│   ├── recreate_simulation.sh -> ../recreate_simulation.sh
│   ├── user-data                      # Cloud-init configuration for VM initialization
│   ├── meta-data                      # Instance metadata (hostname: hft-sim)
│   ├── hft_tuning.sh -> ../hft_tuning.sh
│   └── setup_remote_server.sh -> ../setup_remote_server.sh
├── results/                           # Timestamped nanosecond latency benchmark logs
│   ├── <CPU_MODEL>_<DATE>_<TIME>/     # Automated run sessions (e.g. AMD_Ryzen_9_9900X_20260910_005443/)
│   │   ├── BENCHMARK_REPORT.md        # Comprehensive platform benchmark & tuning report
│   │   ├── before_latency_latest.txt  # Session baseline benchmark metrics
│   │   ├── after_latency_latest.txt   # Session post-tuning benchmark metrics
│   │   └── *_latency_*.txt            # Timestamped latency archives
│   ├── <CPU_MODEL>_latest -> ...      # Convenience symlink to latest session for this CPU
│   └── hft_grub_parameters_reference.txt # Master kernel boot parameter reference
├── lab01-baseline/                    # Reference latency baselines & labs
└── lab02-cpp-rust-toolchain/          # Low-latency C++20 & Rust compiler development setup
```

---

## 🖥 Hardware & Network Architecture

### 1. Multi-NUMA Memory Architecture*
In a dual-socket or multi-die architecture (e.g., Intel Xeon Scalable or AMD EPYC), each CPU socket contains its own integrated memory controller:
- **Local Memory Access**: ~35–45 ns
- **Remote NUMA Access (QPI/UPI Interconnect)**: ~85–120 ns (a 2.5x latency penalty!)

Trading processes must be strictly pinned to the **specific NUMA node** where the trading NIC resides on the PCIe bus.*

> [!NOTE]
> **\*Ryzen / Single-NUMA Architecture Note:** Hardware multi-NUMA memory partitioning and cross-interconnect penalties apply to multi-socket or multi-channel enterprise server platforms (e.g., Threadripper PRO, EPYC, Xeon). On high-frequency AMD Ryzen architectures (and single-NUMA Threadripper), memory is routed through a single I/O die with uniform memory access (UMA); multi-NUMA binding is therefore not required.

### 2. Network Interface Architecture (Intel 10Gbps & FPGA Precursor)
While proprietary NICs (like Solarflare Onload) require expensive custom silicon, **Intel 10Gbps NICs** (Intel 82599ES, X520, X540, X550, X710) are the industry-standard commodity baseline.

With Linux **AF_XDP (eXpress Data Path)**:
- Raw packet DMA writes directly to user-space memory buffers (**UMEM**).
- Zero memory copies, zero `sk_buff` allocation, zero TCP/IP kernel stack traversal.
- The lock-free circular descriptor ring model (**Fill, Rx, Tx, Completion**) is an **exact 1:1 architectural mirror of FPGA PCIe DMA ring buffers** (Xilinx XDMA/QDMA or ExaNIC).

---

## ⚙ BIOS / UEFI Firmware Configuration (AMD Ryzen 9 9950X / X870E)

Before applying operating system tunings, configure the system's UEFI setup (via physical console or remote management). Modern low latency high frequency trading setups deploy dedicated execution platforms powered by the **AMD Ryzen 9 9950X** processor (Zen 5, 16 physical cores, 32 threads, 64MB L3 cache, up to 5.7 GHz) on **X670E or X870E** low-jitter motherboards (from vendors like ASUS ROG, MSI, or Gigabyte) running standard AMI UEFI BIOS.

> [!TIP]
> **Architectural Rationale:** The deliberate deployment of a dedicated execution processor like the 9950X for low latency high frequency trading over a massive 128-core server processor is driven by its **superior single-thread clock scaling (up to 5.7 GHz)**. In quantitative trading and market making, maximizing **single-thread tick-to-trade determinism** for the critical-path order execution gateway is exponentially more valuable than having massive core counts designed for aggregate multi-tenant throughput.

> [!NOTE]
> **\*BIOS NUMA Note:** Dedicated multi-NUMA BIOS options (such as NUMA Nodes Per Socket `NPS1/NPS2/NPS4` or Sub-NUMA Clustering `SNC`) are only present on multi-node enterprise platforms (AMD EPYC, Threadripper PRO, Intel Xeon). On high-frequency AMD Ryzen platforms, memory operates as a single uniform access domain (UMA), so no NUMA partitioning configuration is required in BIOS.

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

### 1. Accessing Low Latency High Frequency Trading Platform UEFI / BIOS Setup
1. Reboot the server.
2. During the early Power-On Self-Test (POST) screen, repeatedly press `<DEL>` or `<F2>` until the **Aptio Setup Utility (AMI BIOS)** launches.
3. If running in graphical/EZ mode, press `<F7>` to switch to **Advanced Mode** (most IPMI/serial console Aptio installations default directly to classic text-mode Advanced Mode).

---

### 2. Aptio Setup: AMD Ryzen vs. Enterprise EPYC BIOS Comparison

If you have previously configured enterprise AMD EPYC servers, the **AMI Aptio Setup** on an AMD Ryzen platform will appear significantly simpler and less cluttered. Here is why:

| Architecture Domain | AMD EPYC Aptio Setup (Enterprise Multi-Node) | AMD Ryzen Aptio Setup (AM5 / Single-Socket HFT) | Adjustment for Ryzen HFT |
| :--- | :--- | :--- | :--- |
| **NUMA Topology** | Configurable: `NPS0`, `NPS1`, `NPS2`, `NPS4` across 4–12 memory channels | Fixed: 1 NUMA Node / UMA across 2 DDR5 channels | **Omitted**: Do not look for `NPS` or `SRAT` options. |
| **Sub-NUMA Clustering** | `SNC` / `L3 Cache as NUMA` options | Single unified L3 per 8-core CCD | **Omitted**: Unnecessary on Ryzen. |
| **Clock Determinism** | Determinism Slider (`Performance` vs `Power`) | Core Performance Boost (CPB) toggle or manual clock multiplier | **Keep Disabled**: Turn CPB/PBO off or lock all-core multiplier. |
| **Socket Interconnect** | Multi-socket xGMI / UPI link frequency & width | Single AM5 socket | **Omitted**: No inter-socket fabric to tune. |
| **Idle Power Phases** | C-states / Determinism | `Power Supply Idle Control` | **Set to `Typical Current Idle`**: Prevents VRM voltage drops during trading lulls. |
| **Core Isolation** | `SMT Control` (Disable) | `SMT Control` (Disable) | **Identical**: Must disable SMT for 1 thread per physical core. |
| **PCIe Subsystem** | 128 lanes, bifurcation per slot/MCIO | 24–28 lanes, direct CPU PCIe Gen 5 | **Identical**: Disable PCIe ASPM, enable Above 4G & Re-Size BAR. |
| **DMA Virtualization** | IOMMU (Disable for bare metal) | IOMMU (Disable for bare metal) | **Identical**: Disable to bypass IOTLB overhead. |

---

### 3. AMI Aptio Setup (Aptio V) Navigation Tree & Controls

On modern AM5 motherboards (e.g. ASRock Rack, Supermicro, ASUS, MSI) running AMI Aptio Setup, use the standard keyboard controls to navigate:

#### Universal Aptio Keyboard Controls
| Key(s) | Action in Aptio Setup |
| :--- | :--- |
| `[←]` / `[→]` | **Select Screen**: Switch horizontally between top-level tabs (`Main`, `Advanced`, `Chipset/OC`, `Boot`, etc.). |
| `[↑]` / `[↓]` | **Select Item**: Move the selection cursor up and down through menu lines. |
| `[Enter]` | **Select / Open**: Enters a sub-menu (denoted by `►` or `>`), or opens a popup selection list for an option. |
| `[+]` / `[-]` or `[PgUp]` / `[PgDn]` | **Change Option**: Cycles through available values for the highlighted setting without opening a popup dialog. |
| `[Esc]` | **Exit / Back**: Steps backward to the parent menu or exits the current dialog. |
| `[F1]` | **General Help**: Displays basic keyboard control help. |
| `[F7]` | **Advanced / EZ Mode Toggle**: On consumer boards (ASUS/MSI/ASRock), toggles between graphical EZ Mode and classic Advanced text mode. |
| `[F9]` | **Optimized Defaults**: Loads factory optimized default settings. |
| `[F10]` | **Save & Exit**: Opens the confirmation prompt to save all modifications and reboot. |

```text
┌─────────────────────────────────────────────────────────────────────────────┐
│                    Aptio Setup - American Megatrends                        │
│   Main     Advanced     Chipset / OC     Security     Boot     Save & Exit  │
└──────┬─────────┬──────────────┬──────────────┬──────────┬───────────┬───────┘
       │         │              │              │          │           │
       │         ▼              ▼              │          │           │
       │  ┌──────────────┐ ┌──────────────┐    │          │           │
       │  │ AMD CBS      │ │ PCIe / OC    │    │          │           │
       │  └──────┬───────┘ └──────┬───────┘    │          │           │
       │         │                │            │          │           │
       ▼         ▼                ▼            ▼          ▼           ▼
  [Platform]  [Core Clocks]  [Fabric & Bus] [Passwords] [Boot Order] [Save & Reset]
```

---

### 4. Step-by-Step Keystroke Walkthrough for Each Low-Latency Setting

Follow these exact keystroke sequences to navigate directly to each critical HFT configuration inside AMI Aptio Setup:

#### 1. Disable Simultaneous Multi-Threading (SMT)
1. At the top navigation bar, press `[→]` to highlight **`Advanced`**.
2. Press `[↓]` until **`CPU Configuration`** (or `AMD CBS` → `CPU Common Options`) is highlighted, then press `[Enter]`.
3. Press `[↓]` to navigate to **`SMT Control`** (or `SMT Mode`).
4. Press `[Enter]`. A small selection dialog will pop up with options (`Auto`, `Enable`, `Disable`).
5. Press `[↓]` to highlight **`Disable`** (or `Disabled`), then press `[Enter]`.
6. Press `[Esc]` to return to the **`Advanced`** menu screen.

#### 2. Disable Sleep States, Clock Jitter & Stabilize VRM Voltages
1. From the **`Advanced`** menu, press `[↓]` to highlight **`AMD CBS`**, then press `[Enter]`.
2. Press `[↓]` to highlight **`CPU Common Options`**, then press `[Enter]`.
3. In this sub-menu:
   - **Core Performance Boost**: Press `[↓]` to highlight **`Core Performance Boost`** → press `[Enter]` → use `[↓]` to select **`Disabled`** → press `[Enter]`.
   - **Global C-state Control**: Press `[↓]` to highlight **`Global C-state Control`** → press `[Enter]` → use `[↓]` to select **`Disabled`** → press `[Enter]`.
   - **Power Supply Idle Control**: Press `[↓]` to highlight **`Power Supply Idle Control`** → press `[Enter]` → use `[↓]` to select **`Typical Current Idle`** → press `[Enter]`.
   - **Streaming Stores Control**: Press `[↓]` to highlight **`Streaming Stores Control`** → press `[Enter]` → use `[↓]` to select **`Enabled`** → press `[Enter]`.
4. Press `[Esc]` to back out to the **`AMD CBS`** menu.

#### 3. Disable IOMMU (Strip Out DMA Translation Latency)
1. While still inside the **`AMD CBS`** menu, press `[↓]` to highlight **`NBIO Common Options`**, then press `[Enter]`.
2. Press `[↓]` to highlight **`IOMMU`**, then press `[Enter]`.
3. Use `[↓]` to select **`Disabled`**, then press `[Enter]`.
4. Press `[Esc]` twice to back out to the top-level **`Advanced`** menu.

#### 4. Configure PCIe Link States & 64-Bit Memory Mapping
1. From the **`Advanced`** menu, press `[↓]` to highlight **`PCI Subsystem Settings`** (or `PCIe / PCI Configuration`), then press `[Enter]`.
2. In this sub-menu:
   - **Above 4G Decoding**: Press `[↓]` to highlight **`Above 4G Decoding`** → press `[Enter]` → select **`Enabled`** → press `[Enter]`.
   - **Re-Size BAR Support**: Press `[↓]` to highlight **`Re-Size BAR Support`** → press `[Enter]` → select **`Enabled`** (or `Auto`) → press `[Enter]`.
   - **PCIe ASPM Support**: Press `[↓]` to highlight **`PCIe ASPM Support`** → press `[Enter]` → select **`Disabled`** → press `[Enter]`.
3. Press `[Esc]` to return to the **`Advanced`** menu.

#### 5. Lock Infinity Fabric & Memory Clocks to 1:1 (Zero-Gear Penalty)
1. Press `[→]` to navigate to the **`OC Tweaker`** / **`Ai Tweaker`** / **`Extreme Tweaker`** top tab (on server boards without an OC tab, go to `Advanced` → `AMD CBS` → `DF Common Options`).
2. Highlight **`FCLK Frequency`** → press `[Enter]` → select **`2000 MHz`** (or match memory clock MCLK) → press `[Enter]`.
3. Highlight **`UCLK DIV1 MODE`** → press `[Enter]` → select **`UCLK=MEMCLK`** → press `[Enter]`.

#### 6. Save Configuration & Reboot
1. Press the **`[F10]`** hotkey from any screen (or press `[→]` until the **`Save & Exit`** tab is highlighted, then press `[Enter]` on **`Save Changes and Reset`**).
2. A confirmation prompt will appear:
   ```text
   Save configuration and reset?
             [Yes]       [No]
   ```
3. Ensure **`[Yes]`** is selected and press **`[Enter]`**. The server will reboot with all low-latency hardware parameters active.

---

### 5. Aptio Low-Latency Settings Summary Reference Table

#### A. CPU Core Isolation & Multithreading (`Advanced` → `CPU Configuration`)
| Aptio Menu Path | Setting Name | Target Value | Low-Latency Architectural Rationale |
| :--- | :--- | :--- | :--- |
| `Advanced` → `CPU Configuration` | **SMT Control** | **Disable** | Disables Simultaneous Multi-Threading. SMT sibling threads compete for L1/L2 caches and execution ALUs. Disabling provides dedicated physical cores with zero noisy-neighbor stalls. |

#### B. AMD CBS → CPU Common Options (Sleep States & Clocks)
| Aptio Menu Path | Setting Name | Target Value | Low-Latency Architectural Rationale |
| :--- | :--- | :--- | :--- |
| `Advanced` → `AMD CBS` → `CPU Common Options` | **Core Performance Boost (CPB)** | **Disabled** | CPB boosts clocks opportunistically, but the dynamic voltage/frequency transitions cause phase-locked loop (PLL) relocking jitter. Disabling locks cores to a deterministic base frequency. |
| `Advanced` → `AMD CBS` → `CPU Common Options` | **Global C-state Control** | **Disabled** | Hard-disables C1, C1E, and C2 sleep states in hardware. Zen cores never enter sleep modes, maintaining 100% C0 execution readiness. |
| `Advanced` → `AMD CBS` → `CPU Common Options` | **Power Supply Idle Control** | **Typical Current Idle** | Prevents motherboard VRMs and CPU power planes from dropping down into low-current sleep states during market lulls. Eliminates power-rail wake-up latency when high-volume packet bursts hit the NIC. |
| `Advanced` → `AMD CBS` → `CPU Common Options` | **Streaming Stores Control** | **Enabled** | Accelerates non-temporal store instructions to write directly to DRAM. |

#### C. Extreme Tweaker / OC / Memory (`OC Tweaker` or `Advanced` → `AMD CBS` → `DF Common Options`)
| Aptio Menu Path | Setting Name | Target Value | Low-Latency Architectural Rationale |
| :--- | :--- | :--- | :--- |
| `OC Tweaker` / `AMD CBS` | **FCLK Frequency** | **Match MCLK (e.g. 2000MHz)** | The Infinity Fabric Clock (FCLK) should match the Memory Clock (MCLK) tightly (typically 2000–2200MHz for Zen 5 DDR5-6000) to minimize inter-die transfer jitter. |
| `OC Tweaker` / `AMD CBS` | **UCLK DIV1 MODE** | **UCLK=MEMCLK** | Forces the Unified Memory Controller Clock to run 1:1 with the memory clock, avoiding gear-down latency penalties. |

#### D. PCIe Subsystem & IOMMU (`Advanced` → `PCI Subsystem Settings` & `AMD CBS` → `NBIO`)
| Aptio Menu Path | Setting Name | Target Value | Low-Latency Architectural Rationale |
| :--- | :--- | :--- | :--- |
| `Advanced` → `PCI Subsystem Settings` | **PCIe ASPM Support** | **Disabled** | Keeps PCIe lanes locked in active L0 power state, eliminating link wakeup delays for NICs. |
| `Advanced` → `AMD CBS` → `NBIO Common Options` | **IOMMU** | **Disabled** | Bare-metal HFT kernels bypass virtualization. Disabling strips away IOTLB page table lookups on packet DMA bursts. |
| `Advanced` → `PCI Subsystem Settings` | **Above 4G Decoding** | **Enabled** | Permits 64-bit BAR memory mapping. |
| `Advanced` → `PCI Subsystem Settings` | **Re-Size BAR Support** | **Enabled** | Allows mapping large multi-gigabyte NIC ring buffers directly into user-space. |

---

### 6. Post-Boot Linux Verification Commands for AMD Ryzen 9 9950X
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

## 🚀 GRUB / Kernel Boot Parameters

For cores reserved for trading, add the master boot parameter string to your bootloader configuration.

### The Master HFT Boot String (Example for Cores 1–N Isolated)
```text
isolcpus=managed_irq,domain,1-15 nohz=on nohz_full=1-15 rcu_nocbs=1-15 rcu_nocb_poll rcupdate.rcu_normal_after_boot=1 skew_tick=1 cpuidle.off=1 processor.max_cstate=0 idle=poll amd_pstate=disable clocksource=tsc tsc=reliable nosmt audit=0 mce=ignore_ce transparent_hugepage=never default_hugepagesz=1G hugepagesz=1G hugepages=16 pcie_aspm=off mitigations=off
```

### Parameter Breakdown

| Category | Boot Parameter | Functional Goal / Description |
| :--- | :--- | :--- |
| **Core Shielding** | `isolcpus=managed_irq,domain,1-15` | Removes isolated cores from the CFS scheduler balancing domain and migrates managed device interrupts. |
| **Core Shielding** | `nohz=on` | Enables generic dynamic tick subsystem infrastructure. |
| **Core Shielding** | `nohz_full=1-15` | Disables the 1000 Hz kernel scheduler tick on cores with 1 runnable task (adaptive tickless mode). |
| **Core Shielding** | `rcu_nocbs=1-15` | Offloads RCU garbage collection callbacks away from trading cores to housekeeping Core 0. |
| **Core Shielding** | `rcu_nocb_poll` | Puts RCU offload kthreads into continuous polling mode (eliminates timer IPI interrupts). |
| **Core Shielding** | `rcupdate.rcu_normal_after_boot=1` | Accelerates boot via expedited grace periods, then restores non-disruptive normal RCU at runtime. |
| **Core Shielding** | `skew_tick=1` | Desynchronizes timer interrupts across CPU cores to prevent simultaneous memory bus stampedes. |
| **Power & C-State** | `cpuidle.off=1` | Hard-disables the Linux generic cpuidle framework across all cores. |
| **Power & C-State** | `processor.max_cstate=0` | Clamps ACPI processor power states strictly to C0 (Active execution). |
| **Power & C-State** | `idle=poll` | Replaces CPU halt/mwait instructions with a 0ns busy-wait polling loop. |
| **Power & C-State** | `amd_pstate=disable` | Disables autonomous hardware P-state scaling, falling back to deterministic `acpi-cpufreq`. |
| **Hardware Determinism** | `clocksource=tsc` | Enforces the direct CPU Time Stamp Counter as the system clock. |
| **Hardware Determinism** | `tsc=reliable` | Disables clocksource verification watchdogs that periodically disrupt TSC. |
| **Hardware Determinism** | `nosmt` | Disables hyperthreading / SMT at the kernel entry point. |
| **Hardware Determinism** | `audit=0` | Strips kernel system call audit logging (~30ns saved per syscall). |
| **Hardware Determinism** | `mce=ignore_ce` | Prevents CPU execution stalls when hardware correctable memory/bus errors occur. |
| **Hardware Determinism** | `transparent_hugepage=never` | Prevents memory allocation freezing during runtime compaction. |
| **Hardware Determinism** | `default_hugepagesz=1G` | Configures 1GB page size as the system hugepage default. |
| **Hardware Determinism** | `hugepagesz=1G hugepages=16` | Pre-allocates static 1GB hugepages at boot time (16GB reserved pool). |
| **Hardware Determinism** | `pcie_aspm=off` | Forces all PCIe interconnects to stay locked in L0 active power mode. |
| **Hardware Determinism** | `mitigations=off` | Disables speculative execution barriers (Meltdown, Spectre, MDS, L1TF). |

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
6. **Vunderland Environment Deployment**: Clones `git@github.com:wazzuck/vunderland.git` to `~/vunderland` and executes `vunderland/settings/setup.sh` to provision micromamba, Python base environment, Rust toolchain, and dotfiles.
7. **Master Latency Engine Configuration**: Ensures `hft_tuning.sh` is configured and executable exclusively in `~/hft/hft_tuning.sh`.

---

## 🧪 Simulation Environment Setup (AlmaLinux 10 on KVM)

To validate scripts, AF_XDP ring buffers, and sysctl routines before deploying to live hardware, a fully automated KVM simulation is included.

### Launching and Managing the Simulation VM
```bash
cd simulation
./setup_simulation.sh create   # Spin up fresh AlmaLinux 10 VM (~10s)
./setup_simulation.sh status   # Check VM run state and assigned IP
./setup_simulation.sh ssh      # Log directly into the running VM
./setup_simulation.sh sync     # Pull benchmark results into local ./results/
./setup_simulation.sh destroy  # Tear down VM and erase temporary disk
```

### ⚡ One-Shot Simulation Recreation & Automated Provisioning (`recreate_simulation.sh`)

For a completely automated, zero-touch tear-down and rebuild of the AlmaLinux simulation environment, use [`recreate_simulation.sh`](file:///home/neville/hft/recreate_simulation.sh). It chains the entire lifecycle into a single pipeline:

```bash
# Interactive mode (prompts for confirmation before destroying):
./recreate_simulation.sh

# Headless / Unattended mode (auto-confirms teardown):
./recreate_simulation.sh -y
```

#### What the Recreate Pipeline Automates:
1. **VM Teardown**: Calls `setup_simulation.sh destroy` to terminate `hft-alma`, undefine the domain, and erase the temporary copy-on-write disk overlay.
2. **Pristine Rebuild**: Calls `setup_simulation.sh create` to spin up a fresh AlmaLinux 10 VM from base image with host CPU/cache passthrough and cloud-init SSH injection.
3. **Remote Server Toolchain Provisioning**: Runs [`setup_remote_server.sh`](file:///home/neville/hft/setup_remote_server.sh) to:
   - Synchronize local SSH credentials so the VM can pull from private Git repositories.
   - Enable AlmaLinux CRB (CodeReady Linux Builder) and EPEL package repositories.
   - Install C/C++ compiler toolchains (`gcc`, `g++`, `make`, `cmake`), low-latency kernel bypass packages (`libxdp`, `libbpf`), profiling tools (`perf`, `numactl`, `cyclictest`), and download utilities (`wget`, `curl`).
   - Authenticate with GitHub and clone `git@github.com:wazzuck/hft.git` to `~/hft`.
   - Clone `git@github.com:wazzuck/vunderland.git` to `~/vunderland` and execute `vunderland/settings/setup.sh` (provisions micromamba, Python base environment, Rust toolchain, and developer dotfiles).
   - Configure master latency tuning engine strictly in `~/hft/hft_tuning.sh`.
4. **Environment Setup & AGY CLI Installation**: Connects to the VM over SSH and executes [`install.sh`](file:///home/neville/hft/install.sh):
   - Installs `tmux`, `git`, `curl`, and `ca-certificates`.
   - Downloads and installs the **Google Antigravity CLI (`agy`)** via its official bootstrapper.
   - Configures `PATH` persistence in `~/.bashrc`.
5. **Post-Setup Health Verification**: Validates operating system version, `git`, `tmux`, `agy`, `hft` repo, `vunderland` repo, micromamba, and Rust toolchain on the VM, confirming it is fully ready for low-latency tuning experiments.

---

### Simulation Specifics
- **OS**: AlmaLinux 10 (GenericCloud QCOW2 image)
- **Networking**: Bridged NAT with static IP (`192.168.122.210`)
- **Cloud-Init**: Injects local SSH keys and provisions user `neville` with passwordless sudo.
- **SSH Alias**: Connect instantly via `ssh hft-sim`.

> [!NOTE]
> **Virtual Machine vs. Bare-Metal Latency:**
> In KVM, hypervisor preemption ("steal time") and virtual clock emulation (`kvm-clock`) introduce millisecond-scale jitter spikes. The VM exists to test **code correctness, build pipelines, and AF_XDP descriptor rings** safely without risking live trading systems.

---

## ⚡ The Top 10 Runtime Kernel & OS Tunings

These 10 configurations are applied at runtime by [`hft_tuning.sh`](file:///home/neville/hft/hft_tuning.sh#L800-L895) without requiring a system reboot:

| # | Tuning Subsystem | Runtime Command | HFT Latency Impact |
| :--- | :--- | :--- | :--- |
| **1** | **CPU Scaling Governor** | `cpupower frequency-set -g performance`<br>`scaling_min_freq = scaling_max_freq` | Eliminates frequency transition delays |
| **2** | **PM QoS C-State Elimination** | `/dev/cpu_dma_latency = 0` (Background Lock) | Locks core in C0 |
| **3** | **CFS Task Migration Cost** | `/sys/kernel/debug/sched/migration_cost_ns = 5,000,000 ns` (5ms) | Prevents thread thrashing / migration |
| **4** | **Automatic NUMA Balancing\*** | `sysctl kernel.numa_balancing = 0` | Stops background page scanning thread |
| **5** | **Virtual Memory Swappiness** | `sysctl vm.swappiness = 0` | Strictly forbids memory paging |
| **6** | **VM Stat Timer Interruption** | `sysctl vm.stat_interval = 120` | Suppresses 1 Hz timer tick interrupts |
| **7** | **Transparent Hugepages (THP)** | `transparent_hugepage/enabled = never`<br>`transparent_hugepage/defrag = never` | Eliminates runtime compaction stalls |
| **8** | **Socket Busy-Polling & NIC Ring**| `sysctl net.core.busy_poll = 50`<br>`ethtool -G rx 4096 tx 4096` | Eliminates interrupt sleep; spins on ring |
| **9** | **TCP Slow Start After Idle** | `sysctl net.ipv4.tcp_slow_start_after_idle = 0` | Immediate line-rate burst after silence |
| **10**| **IRQ Shielding & Core Pinning** | `systemctl stop irqbalance`<br>`default_smp_affinity = 1` (Core 0) | Shields trading core from hardware IRQs |

> [!NOTE]
> **\*Note on Automatic NUMA Balancing:** On enterprise multi-NUMA server platforms, disabling NUMA balancing stops background thread page migration stalls across sockets. On high-frequency single-NUMA AMD Ryzen architectures, this is not strictly required as memory access is already uniform (UMA), though retaining the setting remains recommended practice to eliminate background kernel scanning threads.

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
The Producer pins itself to the NIC's NUMA node*, polls the AF_XDP Rx ring, and pushes normalized structures directly to the SPSC queue (*on multi-NUMA server platforms; on single-NUMA Ryzen architectures, any isolated core on the local CCD is used):

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
│ 4  │ Automatic NUMA Balancing*       │ 0 (disabled)       │ 0                  │ PASS     │
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
│ 5  │ NUMA Node Interleaving*         │ Disabled (NUMA ON) │ 2N / 2S (OK)       │ PASS     │
│ 6  │ PCIe ASPM Link States           │ performance / off  │ performance        │ PASS     │
│ 7  │ Hardware Prefetchers            │ Audit (MSR 0x1A4)  │ All Off (0xF)      │ PASS     │
│ 8  │ IOMMU / VT-d Virtualization     │ Disabled / Bypass  │ Disabled / Bypass  │ PASS     │
│ 9  │ SMI Interrupt Blackouts         │ Minimal (MSR 0x34) │ 0 events           │ INFO     │
│ 10 │ Hardware Invariant TSC          │ constant+nonstop   │ constant+nonstop   │ PASS     │
└────┴─────────────────────────────────┴────────────────────┴────────────────────┴──────────┘
```
*\*Asterisk Note: Multi-NUMA checks apply to multi-node server platforms (e.g. Threadripper PRO, EPYC, Xeon). On high-frequency single-NUMA AMD Ryzen architectures (which report 1 Node / UMA), multi-NUMA controls and interleaving checks are not required.*

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
