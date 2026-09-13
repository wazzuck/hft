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
> - **AMD Ryzen Threadripper PRO 7000WX / 9000WX** (e.g., the latest 9000WX series such as the 9995WX, alongside 7960X, 7975WX with 4/8-channel DDR5 and NPS2/NPS4 NUMA partitioning),
> - **AMD EPYC F-Series (Frequency-Optimized)** (e.g., the upcoming "Turin" architecture chips, as well as current EPYC 9174F, 9374F, 9575F with 12 memory channels and up to 5.0 GHz boost), or
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
- **CFS (Completely Fair Scheduler) Load Balancing** migrates threads between CPU cores and NUMA sockets*, thrashing L1/L2/L3 caches.
- **Kernel Network Stack (`sk_buff`)** copies buffers across kernel/user boundaries and suffers softirq scheduling overhead (~3µs–15µs per round-trip).
- **Background Kernel Workers** (`khugepaged`, `vmstat_update`, `numabalancing`*) freeze trading threads for milliseconds.

This project delivers a **cohesive 3-layer tuning strategy**:
```
┌───────────────────────────────────────────────────────────────────────────┐
│ Layer 1: Hardware & BIOS Firmware (SMT, C-States, Turbo, EPB, NUMA*, ASPM)│
├───────────────────────────────────────────────────────────────────────────┤
│ Layer 2: Kernel Boot Arguments (isolcpus, nohz_full, rcu_nocbs, idle=poll)│
├───────────────────────────────────────────────────────────────────────────┤
│ Layer 3: Runtime Kernel & OS (PM QoS 0µs, sysctl, IRQ Shielding, AF_XDP)  │
└───────────────────────────────────────────────────────────────────────────┘
```
*\*Asterisk Note: Multi-NUMA tuning applies when deploying to multi-socket / multi-node server platforms; it is not required on high-frequency single-NUMA AMD Ryzen architectures.*

### 🎓 Key Concepts for Market Data Engineers

If you come from a market data background (ITCH/OUCH, FIX, multicast, OPRA, CTA/UTP), you already understand the *data side* — instruments, venues, tick-to-trade. This section bridges the gap to the *hardware side*, explaining exactly **why** each kernel setting matters for the packets you process.

#### Concept 1: CPU C-States — Why Your Core Sleeps When You Need It Most

Think of C-States as power-saving sleep modes for each CPU core. When there's a quiet period between market data bursts (e.g., between auction cycles), Linux puts idle cores to sleep to save power:

```text
┌──────────────────────────────────────────────────────────────────────────────┐
│ CPU C-STATES: WHAT HAPPENS WHEN A MARKET DATA PACKET ARRIVES                 │
├──────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│ STATE             POWER USE   WAKE-UP TIME    WHAT'S HAPPENING IN HARDWARE   │
│ ──────            ─────────   ────────────    ─────────────────────────────  │
│ C0  Active        100%        0 ns            Core running your code         │
│ C1  Halt          ~60%        1-2 µs          Clock trees halted             │
│ C1E Enhanced Halt ~40%        2-10 µs         Clock + voltage reduced        │
│ C3  Sleep         ~20%        10-50 µs        L1/L2 caches flushed!          │
│ C6  Deep Sleep    ~5%         50-150 µs       Core fully powered off!        │
│                                                                              │
│ SCENARIO: Nasdaq ITCH feed goes quiet for 5ms between symbol bursts.         │
│ Linux sees the core is idle and drops it into C6 Deep Sleep.                 │
│                                                                              │
│ [Quiet Period] ─────────────> [Core enters C6] ────────────> [Packet Arrives]│
│                                                              │               │
│                                                         150 µs wake penalty! │
│                                                         Your trading algo    │
│                                                         can't start until    │
│                                                         core powers back on. │
│                                                                              │
│ FIX: Set PM QoS /dev/cpu_dma_latency = 0  →  Core stays in C0 always         │
└──────────────────────────────────────────────────────────────────────────────┘
```

#### Concept 2: Page Tables & TLB — Why Memory Translation Costs You Nanoseconds

Your trading application's memory (order books, ring buffers, symbol tables) uses **virtual addresses**. The CPU must translate every virtual address to a physical DRAM location using **Page Tables**. The CPU caches recent translations in a small hardware buffer called the **TLB (Translation Lookaside Buffer)**, which is physically located inside the Memory Management Unit (MMU) directly on the CPU core, adjacent to the L1 cache for ultra-fast access.

When a TLB miss occurs, the hardware memory management unit (MMU) must "walk" the page tables to find the physical address. Modern x86-64 processors use a hierarchical directory structure to do this in four sequential steps:
1. **Step 1: PGD (Page Global Directory - L4)** — The CPU reads the top-level master index.
2. **Step 2: PUD (Page Upper Directory - L3)** — It uses the PGD to find the second-level index.
3. **Step 3: PMD (Page Middle Directory - L2)** — It uses the PUD to find the third-level index.
4. **Step 4: PTE (Page Table Entry - L1)** — It uses the PMD to find the final lookup, which points directly to a standard **4KB** physical memory page in DRAM.

**How they interact:** To find a 4KB page, the CPU reads the PGD to find the PUD, reads the PUD to find the PMD, reads the PMD to find the PTE, and finally reads the PTE to find the physical DRAM address. This is called a "page walk," and every single step requires a slow, independent memory read. 

**The TLB Miss Penalty (Cache vs RAM):** These page tables (PGD, PUD, PMD, PTE) physically live in **main memory (RAM)**. While the CPU tries to cache them in the standard L1/L2/L3 caches, an HFT application traversing massive order books will frequently evict them. When a TLB miss occurs and the page tables are no longer in the cache, the MMU must fetch each directory level directly from RAM. At ~100ns per RAM fetch, a "cold" 4-step page walk inflicts a devastating **~400ns latency penalty** just to calculate the address, *before* it even reads your actual trading data!

**Why Hugepages Skip the PTE Level:** In x86-64 hardware, the PMD (Level 2) directory entries contain a special hardware flag called the "Page Size" (PS) bit. When the Linux kernel allocates a 2MB Hugepage, it sets this PS flag to `1` in the PMD. During a page walk, if the MMU reads a PMD with this flag set, it is hardwired to stop walking immediately. Instead of pointing to a PTE table, the PMD points directly to the physical memory block.

By using **2MB Hugepages**, the final PTE level is bypassed entirely. This not only skips a memory lookup step (saving ~100ns during a cold walk), but crucially, one 2MB page replaces 512 separate 4KB pages, making it vastly easier for the TLB to cache your entire order book!

```text
┌─────────────────────────────────────────────────────────────────────────┐
│ 4KB PAGES vs 2MB HUGEPAGES: TLB MISS COST                               │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│ STANDARD 4KB PAGES (default Linux):                                     │
│ ┌─────────┐    ┌─────┐    ┌─────┐    ┌─────┐    ┌─────┐    ┌────────┐   │
│ │ Virtual │───>│ PGD │───>│ PUD │───>│ PMD │───>│ PTE │───>│Physical│   │
│ │ Address │    │(L4) │    │(L3) │    │(L2) │    │(L1) │    │  DRAM  │   │
│ └─────────┘    └─────┘    └─────┘    └─────┘    └─────┘    └────────┘   │
│                  Each arrow = 1 memory read (~100ns each)               │
│                  Total TLB miss penalty: ~400ns                         │
│                                                                         │
│ A 16MB order book = 4,096 page table entries (PTEs)                     │
│ TLB can only cache ~512-1536 entries → constant TLB misses!             │
│                                                                         │
│ 2MB HUGEPAGES (our tuning):                                             │
│ ┌─────────┐    ┌─────┐    ┌─────┐    ┌─────┐    ┌────────┐              │
│ │ Virtual │───>│ PGD │───>│ PUD │───>│ PMD │───>│Physical│              │
│ │ Address │    │(L4) │    │(L3) │    │(L2) │    │  DRAM  │              │
│ └─────────┘    └─────┘    └─────┘    └─────┘    └────────┘              │
│                  Only 3 levels! And a 16MB order book = only 8 entries  │
│                  All 8 fit permanently in the L1 D-TLB = 0 TLB misses!  │
│                                                                         │
│ MARKET DATA ANALOGY: Imagine your symbol lookup table was spread across │
│ 4,096 filing cabinets (4KB pages) vs 8 filing cabinets (2MB hugepages). │
│ Which is faster to search?                                              │
└─────────────────────────────────────────────────────────────────────────┘
```

#### Concept 3: Kernel Network Stack vs AF_XDP — From recv() to Zero-Copy

When market data arrives at your NIC, the path to your trading application is very different depending on whether you use standard sockets or AF_XDP:

```text
┌─────────────────────────────────────────────────────────────────────────┐
│ PACKET JOURNEY: STANDARD SOCKET vs AF_XDP ZERO-COPY                     │
├───────────────────────────────┬─────────────────────────────────────────┤
│ STANDARD UDP SOCKET           │ AF_XDP ZERO-COPY                        │
│ (recvfrom / recvmsg)          │ (Direct UMEM ring access)               │
├───────────────────────────────┼─────────────────────────────────────────┤
│                               │                                         │
│ ┌──────────────────────┐      │ ┌──────────────────────┐                │
│ │ Your Trading App     │      │ │ Your Trading App     │                │
│ │ char buf[1500];      │      │ │ void* pkt = umem[i]; │                │
│ │ recvfrom(sock, buf); │      │ │ // Already in your   │                │
│ │ // 3-8 µs later...   │      │ │ // memory! ~30 ns    │                │
│ └──────────▲───────────┘      │ └──────────▲───────────┘                │
│            │ copy_to_user()   │            │ (no copy!)                 │
│ ═══════════╪══════════════    │ ═══════════╪════════════════            │
│  KERNEL    │                  │  KERNEL    │ (bypassed!)                │
│ ┌──────────┴───────────┐      │            │                            │
│ │ sk_buff allocation   │      │            │                            │
│ │ Protocol headers     │      │            │                            │
│ │ Checksum validation  │      │            │                            │
│ │ Socket buffer queue  │      │            │                            │
│ │ softirq scheduling   │      │            │                            │
│ └──────────▲───────────┘      │            │                            │
│ ═══════════╪══════════════    │ ═══════════╪════════════════            │
│  HARDWARE  │                  │  HARDWARE  │                            │
│ ┌──────────┴───────────┐      │ ┌──────────┴───────────┐                │
│ │ NIC DMA writes to    │      │ │ NIC DMA writes       │                │
│ │ kernel ring buffer   │      │ │ directly to UMEM     │                │
│ └──────────────────────┘      │ └──────────────────────┘                │
│                               │                                         │
│ Total: ~3,000-8,000 ns        │ Total: ~30 ns                           │
│ (100-250x SLOWER)             │ (ZERO kernel overhead)                  │
├───────────────────────────────┴─────────────────────────────────────────┤
│ MARKET DATA ANALOGY: Standard sockets are like receiving a parcel that  │
│ goes through reception, security scanning, and internal mail before     │
│ reaching your desk. AF_XDP is like having the delivery driver place     │
│ the parcel directly on your desk.                                       │
└─────────────────────────────────────────────────────────────────────────┘
```

#### Concept 4: IRQ Shielding — Protecting Your Trading Core

Hardware devices (NICs, NVMe drives, USB controllers) signal the CPU via **Interrupts (IRQs)**. Each interrupt forces the CPU core to pause what it's doing, save state, run the interrupt handler, then resume:

```text
┌─────────────────────────────────────────────────────────────────────────┐
│ IRQ SHIELDING: WHY INTERRUPTS BREAK DETERMINISM                         │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│ WITHOUT IRQ SHIELDING (irqbalance running):                             │
│                                                                         │
│ Core 0 ─────[IRQ]──────────────[IRQ]──────────────[IRQ]──── (busy)      │
│ Core 1 ─────────[IRQ]────[IRQ]──────────[IRQ]────────────── (your algo) │
│ Core 2 ──[IRQ]────────────────────[IRQ]─────────[IRQ]────── (idle)      │
│                                                                         │
│ irqbalance distributes IRQs "fairly" across all cores.                  │
│ Your trading algo on Core 1 gets interrupted randomly!                  │
│ Each IRQ = 1-5 µs pause + L1/L2 cache pollution.                        │
│                                                                         │
│ WITH IRQ SHIELDING (our tuning):                                        │
│                                                                         │
│ Core 0 ─[IRQ][IRQ][IRQ][IRQ][IRQ][IRQ][IRQ][IRQ]─── (housekeeping)      │
│ Core 1 ──────────────────────────────────────────── (your algo: CLEAN)  │
│ Core 2 ──────────────────────────────────────────── (isolated: CLEAN)   │
│                                                                         │
│ All device IRQs are pinned to Core 0 (the "housekeeping" core).         │
│ Trading cores run with ZERO hardware interruptions.                     │
│                                                                         │
│ MARKET DATA ANALOGY: It's like having a dedicated phone operator        │
│ (Core 0) handle all incoming calls, so the traders on the desk          │
│ (Cores 1-15) are never distracted.                                      │
└─────────────────────────────────────────────────────────────────────────┘
```

#### Concept 5: TCP Autocorking — Why Linux Delays Your Orders

Linux tries to be "smart" about sending small TCP packets. **Autocorking** delays small writes hoping to coalesce them into bigger packets for better throughput. This is catastrophic for order execution:

```text
┌─────────────────────────────────────────────────────────────────────────┐
│ TCP AUTOCORKING: COALESCING vs IMMEDIATE DISPATCH                       │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│ WITH AUTOCORKING (default Linux — optimized for bulk throughput):       │
│                                                                         │
│ t=0µs   Your algo sends 64-byte order ──> [Socket Buffer: HELD]         │
│ t=200µs Another write arrives            ──> [Socket Buffer: HELD]      │
│ t=1ms   Kernel decides to flush          ──> [NIC] ──> Exchange         │
│                                                                         │
│ Your order sat in the socket buffer for 1ms before hitting the wire!    │
│                                                                         │
│ WITHOUT AUTOCORKING (tcp_autocorking=0 — our tuning):                   │
│                                                                         │
│ t=0µs   Your algo sends 64-byte order ──> [NIC] ──> Exchange            │
│                                                                         │
│ Order hits the wire in sub-microsecond. No waiting, no coalescing.      │
│                                                                         │
│ MARKET DATA ANALOGY: Autocorking is like a postal service that waits    │
│ for more letters before dispatching the van. In trading, you want       │
│ every order dispatched the instant it's ready — like a courier on       │
│ a motorcycle waiting at the door.                                       │
└─────────────────────────────────────────────────────────────────────────┘
```

#### Concept 6: Multi-NUMA CPU Topology, Cache Hierarchy & Context Switching

Ultra-low latency HFT servers frequently deploy high-frequency, multi-NUMA enterprise processors—such as the **AMD Ryzen Threadripper PRO 7000WX / 9000WX** (e.g., 7995WX, 7975WX, 9995WX boosting up to 5.1–5.3 GHz) or frequency-optimized **AMD EPYC 9004/9005 F-Series** (e.g., 9174F, 9374F, 9575F boosting to 5.0 GHz) partitioned into **NPS4 (4 NUMA nodes per socket)** mode.

Understanding how L1, L2, and L3 caches attach to cores across NUMA nodes is critical to understanding why context switching and thread migration devastate tick-to-trade latency:

```text
┌─────────────────────────────────────────────────────────────────────────┐
│ MULTI-NUMA CACHE ARCHITECTURE: AMD THREADRIPPER PRO / EPYC (NPS4 MODE)  │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│ ╔═════════════════════════════════════╗ ╔═════════════════════════════╗ │
│ ║       NUMA NODE 0 (Local)           ║ ║       NUMA NODE 1 (Remote)  ║ │
│ ║ ┌─────────────────────────────────┐ ║ ║ ┌─────────────────────────┐ ║ │
│ ║ │ CCD 0 (Core Complex Die)        │ ║ ║ │ CCD 1                   │ ║ │
│ ║ │ ┌─────────────┐ ┌─────────────┐ │ ║ ║ │ ┌─────────┐ ┌─────────┐ │ ║ │
│ ║ │ │   CORE 0    │ │   CORE 1    │ │ ║ ║ │ │ CORE 8  │ │ CORE 9  │ │ ║ │
│ ║ │ │ (Housekeep) │ │ (Trading)   │ │ ║ ║ │ │ ...     │ │ ...     │ │ ║ │
│ ║ │ │ ┌─────────┐ │ │ ┌─────────┐ │ │ ║ ║ │ └─────────┘ └─────────┘ │ ║ │
│ ║ │ │ │ L1i/L1d │ │ │ │ L1i/L1d │ │ │ ║ ║ │   (Private L1 & L2)     │ ║ │
│ ║ │ │ │ 32K+32K │ │ │ │ 32K+32K │ │ │ ║ ║ └────────────┬────────────┘ ║ │
│ ║ │ │ │  ~1 ns  │ │ │ │  ~1 ns  │ │ │ ║ ║              │              ║ │
│ ║ │ │ └────┬────┘ │ │ └────┬────┘ │ │ ║ ║    ┌─────────┴──────────┐   ║ │
│ ║ │ │ ┌────┴────┐ │ │ ┌────┴────┐ │ │ ║ ║    │ L3 Cache (32MB)    │   ║ │
│ ║ │ │ │   L2    │ │ │ │   L2    │ │ │ ║ ║    └─────────┬──────────┘   ║ │
│ ║ │ │ │  1 MB   │ │ │ │  1 MB   │ │ │ ║ ║              │              ║ │
│ ║ │ │ │  ~3 ns  │ │ │ │  ~3 ns  │ │ │ ║ ║ ┌────────────┴────────────┐ ║ │
│ ║ │ │ └────┬────┘ │ │ └────┬────┘ │ │ ║ ║ │ Memory Controller (DDR5)│ ║ │
│ ║ │ └──────┼──────┴───────┼───────┘ │ ║ ║ └────────────┬────────────┘ ║ │
│ ║ │        └───────┬──────┘         │ ║ ║              │              ║ │
│ ║ │   ┌────────────┴────────────┐   │ ║ ║    ┌─────────┴──────────┐   ║ │
│ ║ │   │ L3 Cache (32MB Unified) │   │ ║ ║    │ Remote DRAM (~160ns) │ ║ │
│ ║ │   │ ~10-12 ns (Shared CCD)  │   │ ║ ║    └────────────────────┘ ║ ║ │
│ ║ │   └────────────┬────────────┘   │ ║ ║                           ║ ║ │
│ ║ └────────────────┼────────────────┘ ║ ╚══════════════▲════════════╝ ║ │
│ ║                  │                  ║                │                │
│ ║   ┌──────────────┴──────────────┐   ║   AMD Infinity │ Fabric / xGMI  │
│ ║   │ Memory Controller (2-Ch)    │   ║   Central I/O Die (IOD) Bus     │
│ ║   └──────────────┬──────────────┘   ║   (~140-180 ns Inter-NUMA)      │
│ ║                  │                  ║                │                │
│ ║   ┌──────────────┴──────────────┐   ║                │                │
│ ║   │ Local DDR5 DRAM (~75 ns)    ├───╫────────────────┘                │
│ ║   └─────────────────────────────┘   ║                                 │
│ ╚═════════════════════════════════════╝                                 │
│                                                                         │
│ CACHE TOPOLOGY BREAKDOWN:                                               │
│ • L1i / L1d (~1 ns / ~4-5 cycles): Private to each individual core.     │
│ • L2 Cache (~3-4 ns / ~14 cycles): Private 1MB per core.                │
│ • L3 Cache (~10-12 ns / ~45 cycles): Shared across 8 cores in the CCD.  │
│ • Local DDR5 Memory (~75 ns): Routed via local NUMA memory channels.    │
│ • Remote NUMA Memory (~160+ ns): Crosses Infinity Fabric / UPI bus.     │
└─────────────────────────────────────────────────────────────────────────┘
```

##### ⚠️ Does Context Switching "Flush" the Cache? The Technical Reality

In low-latency engineering, you will frequently hear that *"context switching flushes your CPU caches."* 

**Technically**, the CPU hardware does **not** execute an explicit cache-invalidation instruction (such as `wbinvd` or `clflush`) during an OS process context switch. **Practically**, however, context switching inflicts the exact same devastating latency penalty through **cache eviction, cache pollution, and TLB displacement**:

1. **L1/L2 Cache Eviction & Working-Set Pollution**:
   - L1 Data (32–48 KB) and L2 (1 MB) caches are small, high-speed set-associative hardware buffers.
   - When the Linux scheduler switches out your trading thread to service an interrupt, kernel worker (`khugepaged`, `ksoftirqd`), or background daemon, that foreign task immediately loads its own instruction pages, stack frames, and variables into cache lines.
   - This **evicts (displaces)** your hot order book structures, circular ring buffers, and network descriptors from the private L1/L2 caches.
2. **TLB Invalidation (`CR3` Page Directory Base Register Reload)**:
   - When switching between processes, the CPU must reload the `CR3` control register with the incoming process's Page Global Directory.
   - Although modern x86 processors support PCID (Process Context Identifiers) to preserve tagged entries, TLB capacity is strictly limited. The foreign process quickly displaces translation entries, forcing costly 4-level page table walks (~400 ns) when your trading thread resumes.
3. **The Pipeline Stall Penalty (1 ns vs 160 ns)**:
   - When your trading loop gets CPU time again, its next memory reads face a **cold cache penalty**.
   - Instead of reading the order book at **~1 ns** from L1, the CPU stalls for **~10–12 ns** (L3 hit) or **~75–160 ns** (DRAM fetch). On a 5.0 GHz processor, a 160 ns stall burns **800 CPU clock cycles** during which your execution engine cannot process incoming market ticks.
4. **Thread Migration Disaster (Cross-Core & Cross-NUMA)**:
   - If CFS migrates your trading thread to another core on the same CCD: private L1 and L2 caches are completely cold.
   - If CFS migrates your thread to a **different NUMA node**: even L3 is cold, and all existing heap allocations now incur the **~160 ns remote NUMA memory penalty** over the Infinity Fabric / UPI bus.

```text
┌─────────────────────────────────────────────────────────────────────────┐
│ CONTEXT SWITCHING LATENCY CLIFF: CACHE HIT vs CACHE MISS PENALTY        │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│ STEADY STATE (Core Isolated, Zero Context Switches):                    │
│ Tick arrives ──> L1d Hit (~1 ns / 4 cycles) ──> Order Executed!         │
│                                                                         │
│ AFTER CONTEXT SWITCH / MIGRATION (Caches Polluted):                     │
│ Tick arrives ──> L1 Miss (~1 ns)                                        │
│               └──> L2 Miss (~4 ns)                                      │
│                     └──> L3 Miss (~12 ns)                               │
│                           └──> Remote DRAM Fetch (~160 ns / 800 cycles!)│
│                                 └──> Order Arrives Late (TICK MISSED)   │
│                                                                         │
│ SUITE MITIGATIONS:                                                      │
│ 1. isolcpus=domain,nohz,1-15  → Eliminates CFS context switches         │
│ 2. nohz_full=1-15             → Disables timer ticks on trading cores   │
│ 3. IRQ Shielding              → Moves hardware interrupts to Core 0     │
│ 4. migration_cost_ns=5000000  → Penalizes cross-core thread migration   │
└─────────────────────────────────────────────────────────────────────────┘
```

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

### 1. Modern CPU Architecture: Ryzen vs. EPYC for HFT

Understanding the physical layout of modern processors is essential for writing deterministic, low-latency code. In the AMD ecosystem, processors are built using a "chiplet" design, where multiple smaller silicon dies are connected together rather than fabricating one massive monolithic chip.

The two main architectures you will encounter are **Ryzen (Desktop/Workstation)** and **EPYC (Enterprise Server)**. While they share the same underlying core technology (e.g., Zen 4 / Zen 5), their physical topologies are designed for entirely different workloads.

#### The Core Components
Regardless of whether you use Ryzen or EPYC, the architecture consists of these fundamental building blocks:
- **Core Complex (CCX):** A cluster of up to 8 processing cores that share a single, unified L3 cache. 
- **Core Complex Die (CCD):** The physical piece of silicon ("chiplet") that contains one or two CCXs.
- **I/O Die (IOD):** A central piece of silicon that handles all communication with the outside world. It contains the Memory Controllers (DDR5) and PCIe lanes (for your network cards).
- **Infinity Fabric:** The high-speed interconnect bus that links the CCDs to the I/O Die. 

#### The Cache Hierarchy
HFT is a battle against the speed of light. The closer data is to the execution pipeline, the faster the trade.
- **L1 Cache (Instruction & Data):** ~32-48KB per core. Extremely fast (~1ns / 4 cycles). Private to each core.
- **L2 Cache:** ~1MB per core. Fast (~3ns / 14 cycles). Private to each core. Holds data evicted from L1.
- **L3 Cache:** ~32-64MB per CCX. Slower (~10-12ns / 45 cycles). **Shared** across all 8 cores in the CCX. 
- **Main Memory (DRAM):** Massive, but extremely slow (~75-100ns). 

#### Ryzen vs. EPYC Topology

**Ryzen (e.g., Ryzen 9 9950X):** Designed for extreme clock speeds (up to 5.7 GHz) and low-latency desktop workloads. All CCDs connect to a single, central I/O Die. From a memory perspective, it acts as a single **UMA (Uniform Memory Access)** node. Any core can access any memory channel with the exact same latency. 

**EPYC / Threadripper PRO (e.g., EPYC 9374F):** Designed for massive core counts and aggregate memory bandwidth (up to 12 memory channels). Because a single I/O die bottleneck would choke 128 cores, the CPU is partitioned into quadrants. It acts as a **NUMA (Non-Uniform Memory Access)** architecture. If a core in Quadrant 1 needs data from memory physically wired to Quadrant 3, it suffers a massive latency penalty traversing the inter-chip interconnect.

```text
┌──────────────────────────────────────────────────────────────────────────────┐
│ ARCHITECTURE COMPARISON: RYZEN (UMA) vs EPYC (NUMA)                          │
├──────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│    RYZEN 9 9950X (Single NUMA Node)        EPYC 9000 SERIES (NPS4 Mode)      │
│    ────────────────────────────────        ────────────────────────────      │
│                                                                              │
│   ┌───────┐ ┌───────┐                     ╔══════════╗          ╔══════════╗ │
│   │ CCD 0 │ │ CCD 1 │                     ║  NUMA 0  ║          ║  NUMA 1  ║ │
│   │8 Cores│ │8 Cores│                     ║ ┌──────┐ ║          ║ ┌──────┐ ║ │
│   │32MB L3│ │32MB L3│                     ║ │CCD 0 │ ║          ║ │CCD 2 │ ║ │
│   └───┬───┘ └───┬───┘                     ║ └──┬───┘ ║          ║ └──┬───┘ ║ │
│       │         │                         ║    │     ║          ║    │     ║ │
│  ═════╪═════════╪══════ (Infinity)      ══╬════╪═════╬══════════╬════╪═════╬═│
│       │         │       (Fabric)          ║    │     ║ (Fabric) ║    │     ║ │
│   ┌───┴─────────┴───┐                     ║ ┌──┴───┐ ║          ║ ┌──┴───┐ ║ │
│   │ CENTRAL I/O DIE │                     ║ │I/O 0 │ ║          ║ │I/O 1 │ ║ │
│   │  (2-Ch DDR5)    │                     ║ └──┬───┘ ║          ║ └──┬───┘ ║ │
│   └────────┬────────┘                     ╚════╪═════╝          ╚════╪═════╝ │
│            │                                   │                     │       │
│        [ Memory ]                          [ Memory ]            [ Memory ]  │
│                                                                              │
│   HFT IMPLICATIONS:                       HFT IMPLICATIONS:                  │
│   All memory access is equal.             Pinning threads to the correct     │
│   Maximum single-thread speed.            NUMA node is absolutely critical.  │
│   Ideal for critical-path execution.      Ideal for massive parallel scale.  │
└──────────────────────────────────────────────────────────────────────────────┘
```

### 2. Multi-NUMA Memory Architecture*
In a dual-socket or multi-die architecture (e.g., Intel Xeon Scalable or AMD EPYC), each CPU socket contains its own integrated memory controller:
- **Local Memory Access**: ~35–45 ns
- **Remote NUMA Access (QPI/UPI Interconnect)**: ~85–120 ns (a 2.5x latency penalty!)

Trading processes must be strictly pinned to the **specific NUMA node** where the trading NIC resides on the PCIe bus.*

> [!NOTE]
> **\*Ryzen / Single-NUMA Architecture Note:** Hardware multi-NUMA memory partitioning and cross-interconnect penalties apply to multi-socket or multi-channel enterprise server platforms (e.g., Threadripper PRO, EPYC, Xeon). On high-frequency AMD Ryzen architectures (and single-NUMA Threadripper), memory is routed through a single I/O die with uniform memory access (UMA); multi-NUMA binding is therefore not required.

### 3. Network Interface Architecture (Intel 10Gbps & FPGA Precursor)
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

### 1. Accessing Supermicro H13SRD-F UEFI / AMI Aptio Setup
1. Reboot the server or connect via IPMI KVM / Serial-over-LAN (SOL).
2. During the early Power-On Self-Test (POST) screen, press `<DEL>` or `<F2>` to launch the **American Megatrends (AMI) Aptio Setup Utility (Version 2.22.1294)**.
3. Supermicro enterprise motherboards default directly to text-mode Advanced Setup.

---

### 2. Supermicro H13SRD-F Aptio Setup Navigation Tree & Menu Structure

The Supermicro H13SRD-F organizes AMD Ryzen AM5 server options cleanly into dedicated sub-menus under the top-level **`Advanced`** tab:

```text
┌─────────────────────────────────────────────────────────────────────────────────────────────────────────┐
│                           Aptio Setup - American Megatrends International, LLC.                         │
│   Main       Advanced       Event Logs       IPMI       Security       Boot       Save & Exit           │
└───┬─────────────┬──────────────┬──────────────┬────────────┬─────────────┬─────────────┬────────────────┘
    │             │              │              │            │             │             │
    │             ▼              ▼              ▼            ▼             ▼             ▼
    │     ┌─────────────────────────────────────────────────────────────────┐
    │     │ ► CPU Configuration                                             │ ──> C-States, PSS, SMT, CPB
    │     │ ► North Bridge Configuration                                    │ ──> Above 4GB MMIO, IOMMU
    │     │ ► South Bridge Configuration                                    │
    │     │ ► Super IO Configuration                                        │ ──> AST2600 BMC / COM Port
    │     │ ► Serial Port Console Redirection                               │
    │     │ ► PCIe/PCI/PnP Configuration                                    │ ──> Above 4G, BAR, ASPM, Relaxed Ord
    │     │ ► AMD fTPM configuration                                        │
    │     │ ► Network Configuration                                         │ ──> Intel 82599 Dual 10GbE
    │     │ ► Supermicro KMS Server Configuration                           │
    │     └─────────────────────────────────────────────────────────────────┘
```

#### Universal Keyboard Controls in Aptio Setup
| Key(s) | Action |
| :--- | :--- |
| `[←]` / `[→]` | **Select Screen**: Switch between top-level tabs (`Main`, `Advanced`, `Event Logs`, `IPMI`, etc.). |
| `[↑]` / `[↓]` | **Select Item**: Move cursor up/down through settings and sub-menus. |
| `[Enter]` | **Select / Open**: Enter sub-menu (denoted by `►`) or open selection popup dialog. |
| `[+]` / `[-]` | **Change Value**: Cycle values directly for the highlighted setting. |
| `[Esc]` | **Exit / Back**: Return to parent menu or close popup dialog. |
| `[F1]` | **General Help**: Display help dialog. |
| `[F4]` | **Save & Exit**: Save changes and reboot system. |

---

### 3. Step-by-Step Keystroke Walkthrough for Supermicro H13SRD-F

Follow these exact keystroke sequences mapped directly to the Supermicro H13SRD-F firmware menus:

#### Menu 1: Advanced → CPU Configuration (C-States, Frequency Determinism, SMT)
*Navigates to the core processor architecture controls for the AMD Ryzen 9 9900X (12-core, Zen 5).*

1. At the top navigation bar, press `[→]` to highlight **`Advanced`**.
2. Press `[↓]` to select **`CPU Configuration`**, then press `[Enter]`.
3. Configure the following settings:
   - **Global C-state Control** → Select **`[Disabled]`**  
     *Prevents Zen 5 cores and Data Fabric (DF) from entering low-power idle states (C1/C2). Cores remain permanently active in C0 with 0ns wake latency.*
   - **PSS Support** → Select **`[Disabled]`**  
     *Disables ACPI `_PSS` dynamic performance state tables. Eliminates opportunistic frequency/voltage scaling, enforcing deterministic execution frequency.*
   - **SMT Control** → Select **`[Disabled]`**  
     *Disables Simultaneous Multi-Threading (Hyper-Threading). Eliminates L1/L2 cache and execution pipeline thrashing from sibling threads. Yields 12 dedicated physical cores.*
   - **Core Performance Boost** → Select **`[Disabled]`**  
     *Disables dynamic Core Performance Boost (CPB/Turbo). Eliminates phase-locked loop (PLL) relocking latency and thermal frequency throttling across cores.*
   - **NX Mode** → Keep **`[Enabled]`** *(No-Execute memory protection)*
   - **SVM Mode** → Keep **`[Enabled]`** *(Secure Virtual Machine)*
4. Press `[Esc]` to return to the **`Advanced`** menu.

#### Menu 2: Advanced → North Bridge Configuration (Memory & IOMMU)
*Configures DDR5 memory mapping and DMA virtualization translation.*

1. From the **`Advanced`** menu, press `[↓]` to select **`North Bridge Configuration`**, then press `[Enter]`.
2. Configure the following settings:
   - **Above 4GB MMIO Limit** → Select **`[40bit (1TB)]`** (or default matching physical memory)  
     *Extends memory-mapped I/O decoding range above 4GB.*
   - **IOMMU** → Select **`[Disabled]`**  
     *Disables AMD-Vi hardware IOMMU translation at the hardware level. Eliminates IOTLB page-table translation overhead and DMA latency spikes on high-throughput NIC packet bursts.*
   - **PPT Control** → Keep **`[Auto]`** *(Package Power Tracking)*
3. Press `[Esc]` to return to the **`Advanced`** menu.

#### Menu 3: Advanced → PCIe/PCI/PnP Configuration (Bus States & BAR)
*Optimizes the PCIe interconnect for low-latency network cards and NVMe storage.*

1. From the **`Advanced`** menu, press `[↓]` to select **`PCIe/PCI/PnP Configuration`**, then press `[Enter]`.
2. Under **PCI Devices Common Settings**, configure:
   - **Above 4G Decoding** → Select **`[Enabled]`**  
     *Enables 64-bit memory space decoding for PCIe devices.*
   - **Re-Size BAR** → Select **`[Enabled]`**  
     *Enables PCIe Resizable Base Address Registers (Re-Size BAR), allowing the CPU direct full-aperture access to NIC and GPU memory buffers.*
   - **SR-IOV Support** → Select **`[Enabled]`**  
     *Enables Single Root I/O Virtualization hardware support.*
   - **BME DMA Mitigation** → Select **`[Disabled]`**  
     *Prevents firmware from disabling Bus Master Enable attributes after SMM lock, avoiding unexpected DMA stalls.*
   - **ASPM Support** → Select **`[Disabled]`**  
     *Disables Active State Power Management. Keeps PCIe Gen 4/Gen 5 lanes locked in full-power L0 active state, eliminating link wakeup delay.*
   - **Relaxed Ordering** → Select **`[Enabled]`**  
     *Allows PCIe packet transactions that do not depend on each other to bypass stalls, accelerating descriptor delivery.*
   - **No Snoop** → Select **`[Enabled]`**  
     *Allows cache-coherent DMA masters to bypass CPU cache snooping when writing to uncached packet buffers.*
   - **NVMe Firmware Source** → Keep **`[AMI Native Support]`**
   - **NVMe RAID Mode** → Keep **`[Disabled]`** *(AHCI / Native NVMe)*
3. Press `[Esc]` to return to the **`Advanced`** menu.

#### Menu 4: Advanced → Network Configuration (Intel 82599 Dual 10GbE)
*Displays physical MAC addresses and PXE boot configurations for onboard dual 10GbE SFP+ controllers (`MAC:90:5A:08:3E:00:E6` and `MAC:90:5A:08:3E:00:E7`). Verify network interfaces are detected and healthy.*

#### Menu 5: Save & Exit
1. Press `[F4]` (or press `[→]` to highlight the **`Save & Exit`** tab and select **`Save Changes and Reset`**).
2. Select **`[Yes]`** to confirm and reboot.

---

### 4. Post-Boot Linux Verification Commands

After booting into Linux, execute these commands to verify that BIOS settings applied successfully:

```bash
# 1. Verify SMT is Disabled (12 physical cores, 1 thread per core)
lscpu | grep -E "Thread\(s\) per core|Core\(s\) per socket|Socket\(s\)"
# Expected:
# Thread(s) per core:  1
# Core(s) per socket:  12
# Socket(s):           1

# 2. Verify C-States are Disabled in Hardware (only C0 active)
cat /sys/devices/system/cpu/cpu0/cpuidle/state*/name 2>/dev/null || echo "cpuidle: disabled"

# 3. Verify PCIe ASPM is Disabled
cat /sys/module/pcie_aspm/parameters/policy 2>/dev/null

# 4. Verify IOMMU is Disabled
dmesg | grep -i -E "AMD-Vi|IOMMU" | grep -i "disabled"

# 5. Run the Automated HFT 4-Tier Verification Suite
sudo ./hft_tuning.sh --verify
```

---

## 🚀 GRUB / Kernel Boot Parameters (Production & Deterministic)

### Safe, Production-Grade Master Boot String (Cores 1–N Isolated)
For modern Linux distributions (AlmaLinux 10 / RHEL 10 / Ubuntu 24.04, kernel 6.12+), apply this safe, deterministic boot parameter string:

```text
isolcpus=domain,nohz,1-15 nohz=on nohz_full=1-15 rcu_nocbs=1-15 rcupdate.rcu_normal_after_boot=1 skew_tick=1 preempt=full nosmt audit=0 mce=ignore_ce transparent_hugepage=never default_hugepagesz=2M hugepages=2048 pcie_aspm=off mitigations=off
```

### Parameter Breakdown & Architectural Rationale

| Category | Boot Parameter | Functional Goal / Low-Latency Rationale |
| :--- | :--- | :--- |
| **Core Shielding** | `isolcpus=domain,nohz,1-15` | Isolates Cores 1–15 from the CFS scheduler balancing domain and timer ticks without disrupting hardware managed queues. |
| **Core Shielding** | `nohz=on` | Enables generic dynamic tick subsystem infrastructure. |
| **Core Shielding** | `nohz_full=1-15` | Disables the 1000 Hz kernel scheduler tick on cores with 1 runnable task (adaptive tickless mode). |
| **Core Shielding** | `rcu_nocbs=1-15` | Offloads RCU garbage collection callbacks away from trading cores to housekeeping Core 0. |
| **Core Shielding** | `rcupdate.rcu_normal_after_boot=1` | Accelerates boot via expedited grace periods, then restores non-disruptive normal RCU at runtime. |
| **Core Shielding** | `skew_tick=1` | Desynchronizes timer interrupts across CPU cores to prevent simultaneous memory bus stampedes. |
| **Kernel Preemption** | `preempt=full` | Forces full preemption across all non-atomic kernel execution paths, slashing timer dispatch latency tail. |
| **Hardware Determinism** | `nosmt` | Disables hyperthreading / SMT at the kernel entry point. |
| **Hardware Determinism** | `audit=0` | Strips kernel system call audit logging (~30ns saved per syscall). |
| **Hardware Determinism** | `mce=ignore_ce` | Prevents CPU execution stalls when hardware correctable memory/bus errors occur. |
| **Hardware Determinism** | `transparent_hugepage=never` | Prevents memory allocation freezing during runtime compaction. |
| **Memory Architecture** | `default_hugepagesz=2M` | Enforces 2MB hugepage default architecture (3-level page tables). |
| **Memory Architecture** | `hugepages=2048` | Pre-allocates 4GB contiguous 2MB hugepages at early boot before memory fragments. |
| **Hardware Determinism** | `pcie_aspm=off` | Forces all PCIe interconnects to stay locked in L0 active power mode. |
| **Hardware Determinism** | `mitigations=off` | Disables speculative execution barriers (Meltdown, Spectre, MDS, L1TF). |

---

### ⚠️ Post-Mortem: Dangerous Parameters to AVOID on Production Bare-Metal

Previous iterations and common internet tuning guides often recommend parameters that are catastrophic on modern multi-queue NVMe / enterprise server hardware. **DO NOT USE** the following parameters:

1. ❌ **`isolcpus=managed_irq`**:  
   *Failure Mode*: Instructs the kernel to forbid assigning managed IRQs to isolated cores. On servers with multi-queue NVMe SSDs (e.g., Micron 7500 PRO with 12+ queues) or multi-queue 10GbE NICs, the `blk-mq` storage driver attempts to assign all queues to Core 0. When vector exhaustion or probe failures occur during early initramfs boot, the root NVMe array (e.g., `md127` Software RAID) fails to assemble, dropping the server into a hung state before pivoting to the root filesystem.
2. ❌ **`systemd.cpu_affinity=0` + `rcu_nocb_poll` + `idle=poll`**:  
   *Failure Mode*: `idle=poll` forces the CPU idle loop to busy-spin in C0 at 100% duty cycle. `rcu_nocb_poll` spawns 11 polling kthreads on Core 0 that continuously spin checking RCU queues. Clamping `systemd.cpu_affinity=0` pins PID 1, udevd, dbus, and all system daemons to that exact same core. Core 0 instantly hits 100% saturation during boot, triggering scheduler starvation, udev timeout panics, and watchdog soft lockups.
3. ❌ **`default_hugepagesz=1G`**:  
   *Failure Mode*: Changing the default system page size to 1GB breaks user-space tools that call `mmap(MAP_HUGETLB)` expecting standard 2MB pages. Allocate 1GB hugepages dynamically or via sysctl post-boot, leaving the system default intact.
4. ❌ **`tsc=reliable` / `clocksource=tsc`**:  
   *Failure Mode*: Modern AMD Zen 5 CPUs natively detect invariant TSC. Forcing `tsc=reliable` bypasses early clocksource stability verification, risking early boot time freezes if platform timers are still synchronizing.

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
   - Locks in `swappiness=0`, `vm.min_free_kbytes=1048576` (1GB emergency pool against direct reclaim freezes), `numa_balancing=0`, `stat_interval=120`, socket `busy_poll=50`, `busy_read=50`, `default_qdisc=pfifo_fast`, `tcp_autocorking=0` (immediate packet serialization), `tcp_no_metrics_save=1`, `tcp_moderate_rcvbuf=0`, UDP buffer mins, and 128MB network buffers.
2. **/usr/local/bin/hft-boot-tune.sh & /etc/systemd/system/hft-tuning.service**:
   - Executes during early boot prior to trading applications.
   - Forces CPU governor to `performance` across all cores and pins min frequency to max frequency.
   - Sets scheduler migration cost to 5,000,000ns (5ms).
   - Hard-disables Transparent Huge Pages (`never`).
   - Masks and stops `irqbalance`, pinning all device IRQs to Core 0 (Housekeeping).
   - Programs physical NICs to 1024/4096 descriptor rings, `rx-usecs 0`, disables GRO/LRO/TSO offloads, and replaces root qdisc with lockless `pfifo_fast`.
   - Sets PCIe network controllers to MaxReadReq 4096B and switches kernel preemption to `full`.
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

# One-shot provision AND immediately lock in golden production low-latency tunings:
./setup_remote_server.sh trading-srv01 --production
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
8. **Optional Zero-Touch Production Lock-In (`--production`)**: Automatically runs `sudo ./hft_tuning.sh --production` on the remote server, applying all 13 tunings, configuring reboot persistence, and running the 4-tier audit check.

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

## ⚡ The Top 13 Runtime Kernel & OS Tunings

These 13 configurations are applied at runtime by [`hft_tuning.sh`](file:///home/neville/hft/hft_tuning.sh) without requiring a system reboot:

| # | Tuning Subsystem | Runtime Command | HFT Latency Impact |
| :--- | :--- | :--- | :--- |
| **1** | **CPU Scaling Governor** | `cpupower frequency-set -g performance`<br>`scaling_min_freq = scaling_max_freq` | Eliminates frequency transition delays |
| **2** | **PM QoS C-State Elimination** | `/dev/cpu_dma_latency = 0` (Background Lock) | Locks core in C0 (0µs exit latency) |
| **3** | **CFS Task Migration Cost** | `/sys/kernel/debug/sched/migration_cost_ns = 5,000,000 ns` (5ms) | Prevents thread thrashing / cache pollution |
| **4** | **Automatic NUMA Balancing\*** | `sysctl kernel.numa_balancing = 0` | Stops background page scanning thread |
| **5** | **VM Swappiness & Emergency Reserve** | `sysctl vm.swappiness = 0`<br>`sysctl vm.min_free_kbytes = 1048576` | Forbids swapping & reserves 1GB pool to prevent direct reclaim stalls |
| **6** | **VM Stat Timer Interruption** | `sysctl vm.stat_interval = 120` | Suppresses 1 Hz timer tick interrupts |
| **7** | **Transparent Hugepages (THP)** | `transparent_hugepage/enabled = never`<br>`transparent_hugepage/defrag = never` | Eliminates runtime compaction stalls |
| **8** | **Socket Busy-Polling, Ring & Qdisc**| `sysctl net.core.busy_poll = 50`<br>`sysctl net.core.default_qdisc = pfifo_fast`<br>`ethtool -G rx 1024 tx 1024` | Eliminates interrupt sleep; replaces fq_codel with lockless O(1) FIFO |
| **9** | **TCP Serialization & Metrics** | `sysctl net.ipv4.tcp_slow_start_after_idle = 0`<br>`sysctl net.ipv4.tcp_autocorking = 0`<br>`sysctl net.ipv4.tcp_no_metrics_save = 1` | Immediate packet serialization; disables coalescing delay & route cache stalls |
| **10**| **IRQ Shielding & Core Pinning** | `systemctl stop irqbalance`<br>`default_smp_affinity = 1` (Core 0) | Shields trading core from hardware IRQs |
| **11**| **Static 2MB Hugepages (4GB)** | `sysctl vm.nr_hugepages = 2048`<br>`mount -t hugetlbfs nodev /dev/hugepages` | Pre-allocates 4GB static pages; 3-level page tables; 0 TLB stalls |
| **12**| **POSIX Real-Time & Memlock Limits** | `/etc/security/limits.d/99-hft.conf`<br>`systemd DefaultLimitMEMLOCK=infinity` | Enables `mlockall` & `SCHED_FIFO` 99 for trading daemons |
| **13**| **PCIe Network MaxReadReq (4096B)** | `setpci -s <bdf> CAP_EXP+8.w=5000:7000`<br>`echo full > /sys/kernel/debug/sched/preempt` | Maximizes PCIe DMA burst efficiency; forces full kernel preemption |

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
