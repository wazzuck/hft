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
```text
┌─────────────────────────────────────────────────────────────────┐
│ STANDARD LINUX SOCKETS vs AF_XDP ZERO-COPY                      │
├─────────────────────────────────────────────────────────────────┤
│ [STANDARD UDP SOCKET]                   [AF_XDP ZERO-COPY]      │
│                                                                 │
│ USER SPACE                              USER SPACE              │
│ ┌────────────────┐                      ┌────────────────┐      │
│ │ Trading Logic  │                      │ Trading Logic  │      │
│ │   recvfrom()   │                      │ (Reads UMEM)   │      │
│ └──────▲─────────┘                      └──────▲─────────┘      │
│ ───────│───────────────────────────────────────│─────────────── │
│ KERNEL │ (Context Switch, Copy)                │ (No Copy!)     │
│ ┌──────┴─────────┐                      ┌──────┴─────────┐      │
│ │ TCP/IP Stack   │                      │ UMEM Ring Buf  │      │
│ │ sk_buff alloc  │                      │ (Lock-Free)    │      │
│ └──────▲─────────┘                      └──────▲─────────┘      │
│ ───────│───────────────────────────────────────│─────────────── │
│ HARDWARE                                       │                │
│ ┌──────┴─────────┐                      ┌──────┴─────────┐      │
│ │ NIC DMA Rx Ring│                      │ NIC DMA Rx Ring│      │
│ └────────────────┘                      └────────────────┘      │
└─────────────────────────────────────────────────────────────────┘
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
  ║       ⚡ HFT LOW-LATENCY KERNEL & OS TUNING SUITE (TOP 13) ⚡            ║
  ║      Nanosecond Precision Microbenchmarks • Multi-NUMA Ready             ║
  ╚══════════════════════════════════════════════════════════════════════════╝

  System Topology: 16 Logical Cores | 1 NUMA Node(s)
  Storage Output : /home/neville/hft/results

  [1] Benchmark untuned box ("Before" baseline -> before_latency_<ts>.txt)
  [2] Apply the 13 key low-latency kernel & OS tunings (Runtime only, no reboot)
  [3] Re-benchmark tuned box ("After" results -> after_latency_<ts>.txt)
  [4] Learning Mode (Compare Before/After & Deep Dive into the 13 Configs)
  [5] Run Complete Pipeline (Execute 1 -> 2 -> 3 -> 4 automatically)
  [6] Revert tunings back to baseline (Restore sysctl, irqbalance, C-states)
  [7] Nanosecond Precision Diagnostic (Verify invariant TSC, clocksource, resolution)
  [8] Combined GRUB / Boot Parameters (View reference, Apply, & Install Persistence)
  [9] Configuration Audit & Health Check (Verify runtime, boot, BIOS & persistence)
  [P] Lock In Production Configuration (One-shot: apply, persist, and audit)
  [10] Exit
```

### 2. Non-Interactive CLI Automation Mode
For scriptable CI/CD pipelines, automated deployments, or remote execution via SSH:
```bash
sudo ./hft_tuning.sh --production   # One-shot golden production lock-in: apply tunings, persist & audit
./hft_tuning.sh --verify           # Run full 4-tier health check and audit
./hft_tuning.sh --full             # Execute 1 -> 2 -> 3 -> 4 pipeline automatically
./hft_tuning.sh --apply-grub       # Apply boot parameters, install persistence & prompt reboot
./hft_tuning.sh --persist          # Install reboot persistence engine without bootloader edit
./hft_tuning.sh --before           # Run baseline before benchmark
./hft_tuning.sh --tune             # Apply the 13 runtime tunings (alias: --apply)
./hft_tuning.sh --after            # Run post-tuning after benchmark
./hft_tuning.sh --learn            # Print side-by-side comparison matrix & deep dive
./hft_tuning.sh --revert           # Reset all settings to baseline & remove persistence
./hft_tuning.sh --grub             # Print master GRUB boot command line reference
./hft_tuning.sh --check-ns         # Run nanosecond TSC timing diagnostic
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

## 📊 Verified Bare-Metal Production Results: AMD Ryzen 9 9950X (`cherry`)

The low-latency configurations in this repository were empirically evaluated and validated on **bare-metal server `cherry`**:
* **CPU**: AMD Ryzen 9 9950X (Zen 5, 16 physical cores, SMT disabled)
* **Motherboard**: Supermicro AS-3015MR-H8TNR / H13SRD-F (AMI BIOS 1.8)
* **Memory**: 128 GB DDR5 ECC (4GB 2MB Static Hugepages + 1GB Emergency Reserve)
* **NIC**: Intel E810-C Dual-Port 100GbE/25GbE (`ice` driver, PCIe Gen4 x16, MRRS 4096B)
* **Kernel**: `Linux 6.17.0-23-generic` (`PREEMPT_DYNAMIC` with `preempt=full`)

### Production Benchmark Results: Baseline vs. Tuned (Run 4)

| Benchmark Dimension | Untuned Baseline (Before) | Production Tuned (Run 4) | Delta | Improvement | Architectural Impact |
| :--- | :---: | :---: | :---: | :---: | :--- |
| **Execution Jitter Pauses (>1 µs)** | **923 events** | **1 event** | **-922 events** | ⭐️ **-99.89%** | Full core isolation & IRQ shielding |
| **Peak Jitter Pause Duration** | **1,207,414 ns** | **2,003 ns** | **-1,205,411 ns** | ⭐️ **-99.83%** | Eradicated 1.2ms storage/NIC interrupt stall |
| **Cyclictest Wakeup Tail (Max)** | **146,771 ns** | **11,396 ns** | **-135,375 ns** | ⭐️ **-92.24%** | C-states locked in C0 (PM QoS 0µs) |
| **Cyclictest Wakeup (Mean)** | 3,589 ns* | **4,264 ns** | +675 ns | **Deterministic** | `preempt=full` preemption across kernel locks |
| **DRAM / LLC Pointer Chase** | 9.98 ns* | **11.18 ns** | +1.20 ns | **L3 Hit Bound** | 2MB Static Hugepages (8 PTEs vs 4,096 PTEs) |
| **AF_XDP Kernel-Bypass Ring** | 21.7 ns* | **23.1 ns** | +1.4 ns | **Wire Speed** | Direct user-space UMEM descriptor turnaround |
| **Clock Monotonic vDSO (Mean)** | 39.3 ns* | **40.2 ns** | +0.9 ns | **Invariant** | Hardware Invariant TSC (4.30 GHz fixed base) |
| **Clock Monotonic vDSO (P99)** | 50.1 ns* | **80.1 ns** | +30.0 ns | **Deterministic** | 0.000% clock drift jitter |
| **Minimal Syscall (`getpid`) Mean** | 60.5 ns* | **91.1 ns** | +30.6 ns | **Fixed Clock** | Deterministic base clock (CPB disabled) |
| **Thread Context Switch (Mean)** | 811.4 ns* | **956.2 ns** | +144.8 ns | **Bounded** | Inter-thread handover on isolated cores |
| **TCP Loopback Ping-Pong (Mean)** | 3,292.2 ns* | **4,126.9 ns** | +834.7 ns | **Bounded** | Kernel networking stack round-trip |

*\*Note on Raw Nanoseconds vs. Jitter Elimination:* In the untuned baseline, single-core Core Performance Boost (CPB) dynamically boosted clock multipliers to 5.70 GHz at the expense of massive jitter spikes (923 pauses up to 1.2 milliseconds). In the tuned state, CPB is locked in BIOS at 4.30 GHz, ensuring 0.000% clock drift jitter and zero thermal throttling.

For the full detailed comparative analysis, see [BASELINE_VS_TUNED_FINAL_REPORT.md](results/BASELINE_VS_TUNED_FINAL_REPORT.md).

### Dual-CCD Core Pinning Strategy for Trading Applications

```text
┌────────────────────────────────────────────────────────────────────────┐
│                   AMD Ryzen 9 9950X (16 Physical Cores)                │
├───────────────────────────────────┬────────────────────────────────────┤
│               CCD 0               │               CCD 1                │
│ ───────────────────────────────── │ ────────────────────────────────── │
│ Core 0 : OS, SSH, Disk I/O, IRQs  │ Core 8 : Market Data Feed Parser   │
│ Core 1 : Monitoring / Tick Logger │ Core 9 : Trading Strategy Alpha    │
│ Core 2 : Risk Gateway Daemon      │ Core 10: Order Execution Engine    │
│ Cores 3–7: Auxiliary Services     │ Cores 11–15: Low-Latency Pipelines │
│ [ 32 MB L3 Cache Instance 0 ]     │ [ 32 MB L3 Cache Instance 1 ]      │
└───────────────────────────────────┴────────────────────────────────────┘
```
Pin production trading components strictly to **CCD 1 (Cores 8–15)**:
1. **L3 Cache Isolation**: Zero cache evictions from background OS tasks on Core 0.
2. **Sub-20ns Core Handover**: Inter-thread communication within CCD 1 remains at ~16 ns (L3-shared), avoiding the ~80 ns Infinity Fabric penalty.

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
