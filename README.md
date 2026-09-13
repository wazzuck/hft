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
5. [GRUB / Kernel Boot Parameters](#-grub--kernel-boot-parameters-production--deterministic)
6. [Automated Remote Server Provisioning](#-automated-remote-server-provisioning)
7. [Runtime Kernel & OS Tunings](#-runtime-kernel--os-tunings)
8. [Modern Kernel-Bypass Networking (AF_XDP on Intel 10GbE)](#-modern-kernel-bypass-networking-af_xdp-on-intel-10gbe)
9. [Simulation Environment Setup (AlmaLinux 10 on KVM)](#-simulation-environment-setup-almalinux-10-on-kvm)
10. [Step-by-Step Execution Guide (`hft_tuning.sh`)](#-step-by-step-execution-guide-hft_tuningsh)
11. [The 4-Tier Configuration Audit & Health Check](#-the-4-tier-configuration-audit--health-check)
12. [Nanosecond Precision Benchmarking Engine](#-nanosecond-precision-benchmarking-engine)
13. [Verified Bare-Metal Production Results (`cherry`)](#-verified-bare-metal-production-results-amd-ryzen-9-9950x-cherry)
14. [Troubleshooting & Verification](#-troubleshooting--verification)

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
│ (Housekeeping Core 0) handle all incoming calls, so the traders on desk │
│ (the isolated trading cores) are never distracted.                      │
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
│ ║ │   │ L3 Cache (32MB Unified) │   │ ║ ║    │ Remote DRAM (~160ns)   ║ │
│ ║ │   │ ~10-12 ns (Shared CCD)  │   │ ║ ║    └────────────────────┘   ║ │
│ ║ │   └────────────┬────────────┘   │ ║ ║                             ║ │
│ ║ └────────────────┼────────────────┘ ║ ╚══════════════▲══════════════╝ │
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
│ CACHE TOPOLOGY BREAKDOWN (Physical Core vs. SMT Sibling Threads):       │
│ • L1i/L1d (~1 ns): Private per core (Zen 5: 48KB L1d; Zen 4: 32KB L1d). │
│   [!] SHARED between SMT sibling threads on the same physical core!     │
│ • L2 Cache (~3-4 ns / ~14 cycles): Private 1MB per physical core.       │
│   [!] SHARED between SMT sibling threads on the same physical core!     │
│ • L3 Cache (~10-12 ns): Shared across all cores in CCD (32MB / 96MB).   │
│ • Local DDR5 Memory (~75 ns): Routed via local NUMA memory channels.    │
│ • Remote NUMA Memory (~160+ ns): Crosses Infinity Fabric / UPI bus.     │
└─────────────────────────────────────────────────────────────────────────┘
```

##### 🧵 Simultaneous Multithreading (SMT): Which Caches Are Shared vs. Totally Private?

On modern multi-core processors (such as AMD Zen 5 / Zen 4 or Intel Xeon), **Simultaneous Multithreading (SMT)**—often referred to as Hyper-Threading—exposes **two logical threads (virtual cores) per physical core**.

A widespread and dangerous misconception in latency engineering is assuming that each logical thread has its own dedicated L1 or L2 cache. **They do not.**

> [!CAUTION]
> **No CPU caches are private between threads running on the same physical core.**  
> When SMT is enabled, **every single level of the cache hierarchy (L1i, L1d, L2, and L3) is shared** between sibling threads. The only hardware resources that are totally private to an individual thread are architectural CPU registers.

---

#### Detailed Hardware & Cache Sharing Matrix

| CPU Hardware Resource | Between SMT Siblings *(Same Physical Core)* | Between Different Physical Cores *(Same CCD)* | Between Different CCDs / Sockets *(Cross-NUMA)* |
| :--- | :--- | :--- | :--- |
| **Architectural Registers** (`RAX`, `RIP`, `RSP`, Vector `AVX-512`/`ZMM`) | **TOTALLY PRIVATE** | **TOTALLY PRIVATE** | **TOTALLY PRIVATE** |
| **L1 Instruction Cache (L1i)** *(32 KB)* | **SHARED** *(Competitively partitioned)* | **TOTALLY PRIVATE** | **TOTALLY PRIVATE** |
| **L1 Data Cache (L1d)** *(48 KB Zen 5 / 32 KB Zen 4)* | **SHARED** *(Competitively shared — evicts lines!)* | **TOTALLY PRIVATE** | **TOTALLY PRIVATE** |
| **L2 Cache** *(1 MB 16-way per core)* | **SHARED** *(Both threads contend for 1 MB)* | **TOTALLY PRIVATE** | **TOTALLY PRIVATE** |
| **L3 Cache** *(32 MB per CCD / 96 MB on X3D)* | **SHARED** | **SHARED** *(Across all 8 cores in CCD)* | **TOTALLY PRIVATE** *(Isolated per CCD)* |
| **Execution Units** *(ALUs, FPUs, Branch Predictor)* | **SHARED** *(Dynamically multiplexed)* | **TOTALLY PRIVATE** | **TOTALLY PRIVATE** |
| **TLB & Load/Store Queues** | **SHARED** *(Partitioned or tagged)* | **TOTALLY PRIVATE** | **TOTALLY PRIVATE** |

---

#### Why SMT Is Fatal to Deterministic HFT Latency

1. **Cache Crosstalk & Eviction**:
   - If Thread 0 (your critical trading engine) and Thread 1 (a sibling thread, such as a background logger, garbage collection worker, or kernel task) run on the same physical core, they read and write to the **exact same 48 KB L1 Data SRAM and 1 MB L2 cache**.
   - Sibling thread memory accesses continuously displace your warm order book structures, market data ring buffers, and network packet headers from L1 and L2.
2. **Real-Time Thrashing (Zero Context Switches Needed)**:
   - Unlike process context switching—where cache eviction occurs sequentially when the OS pauses one process to schedule another—**SMT sibling threads run simultaneously in hardware**. Thread 1 continuously displaces L1/L2 cache lines and steals execution pipeline issue slots *in real time while your trading loop is attempting to process incoming market ticks*.
3. **The HFT Fix: Disable SMT (`nosmt`)**:
   - Our tuning suite disables SMT at the kernel boot level (`nosmt` in GRUB) and firmware level (`SMT Control: Disabled` in BIOS).
   - With SMT disabled, **100% of the 48 KB L1d, 32 KB L1i, 1 MB L2 cache, all TLBs, and all execution ports become TOTALLY PRIVATE** and exclusively dedicated to your isolated trading algorithm.

##### ⚠️ Does Context Switching "Flush" the Cache? The Technical Reality

In low-latency engineering, you will frequently hear that *"context switching flushes your CPU caches."* 

**Technically**, the CPU hardware does **not** execute an explicit cache-invalidation instruction (such as `wbinvd` or `clflush`) during an OS process context switch. **Practically**, however, context switching inflicts the exact same devastating latency penalty through **cache eviction, cache pollution, and TLB displacement**:

1. **L1, L2, & L3 Cache Eviction & Working-Set Pollution**:
   - Modern state-of-the-art AMD Ryzen processors (Zen 5 architectures like the Ryzen 9 9950X / 9900X, as well as Zen 4 and X3D variants) employ a multi-tier cache hierarchy:
     - **L1 Data Cache (48 KB 12-way per core on Zen 5; 32 KB 8-way on Zen 4)**: The fastest buffer (~1 ns / ~4–5 cycles) per physical core. *(Shared between SMT sibling threads if SMT is enabled).* (L1 Instruction is 32 KB 8-way per core).
     - **L2 Cache (1 MB 16-way per physical core)**: Dedicated hardware cache per physical core (~3–4 ns / ~14 cycles). *(Shared between SMT sibling threads if SMT is enabled).*
     - **L3 Cache (32 MB 16-way shared per 8-core CCD; 96 MB on 3D V-Cache / X3D chips)**: Shared pool across the cores of a Core Complex Die (~10–12 ns / ~45–55 cycles). On dual-CCD flagships like the 16-core Ryzen 9 9950X, this totals 64 MB of L3 (2x 32 MB), or up to 128 MB on dual-CCD X3D chips.
   - When the Linux scheduler switches out your trading thread to service an interrupt, kernel worker (`khugepaged`, `ksoftirqd`), or background daemon, that foreign task immediately loads its own instruction pages, stack frames, and variables into cache lines.
   - This **evicts (displaces)** your hot order book structures, circular ring buffers, and network descriptors from private L1/L2 caches. Furthermore, memory-heavy kernel routines and background tasks pollute the shared L3 cache sets, evicting warm market data across the entire CCD.
2. **TLB Invalidation (`CR3` Page Directory Base Register Reload)**:
   - When switching between processes, the CPU must reload the `CR3` control register with the incoming process's Page Global Directory.
   - Although modern x86 processors support PCID (Process Context Identifiers) to preserve tagged entries, TLB capacity is strictly limited. The foreign process quickly displaces translation entries, forcing costly 4-level page table walks (~400 ns) when your trading thread resumes.
3. **The Pipeline Stall Penalty (1 ns vs 160 ns)**:
   - When your trading loop gets CPU time again, its next memory reads face a **cold cache penalty**.
   - Instead of reading the order book at **~1 ns** from L1d or **~3–4 ns** from L2, an L3 hit stalls for **~10–12 ns**, while an L3 miss stalls for **~75 ns** (local DDR5 DRAM) or **~140–180 ns** (remote NUMA / cross-CCD fetch across the AMD Infinity Fabric). On a 5.7 GHz Ryzen 9 9950X, a 160 ns stall burns over **900 CPU clock cycles** during which your execution engine cannot process incoming market ticks.
4. **Thread Migration Disaster (Cross-Core, Cross-CCD & Cross-NUMA)**:
   - State-of-the-art Ryzen processors feature a chiplet architecture with Core Complex Dies (CCDs) connected via the AMD Infinity Fabric to an I/O Die (IOD):
     - **Migration to a Sibling Core on the SAME CCD**: Private L1 (48 KB) and L2 (1 MB) caches are completely cold. The thread can only fall back to the shared 32 MB (or 96 MB on X3D) L3 cache slice (~10–12 ns).
     - **Cross-CCD Migration (Core on CCD0 $\rightarrow$ Core on CCD1)**: The ultimate cache disaster. Because each CCD possesses its own distinct L3 cache pool, **L1, L2, and L3 caches are all completely cold**. The thread loses its entire warm cache footprint. Every memory access must traverse the AMD Infinity Fabric interconnect to the memory controller, incurring severe latency penalties (~75–140+ ns).
     - **Cross-NUMA Migration**: On multi-socket or multi-NUMA server platforms, thread migration forces all heap allocations to cross external UPI / Infinity Fabric links, adding a **~160+ ns remote NUMA memory penalty**.

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
│                           └──> Remote DRAM Fetch (~160 ns / 900 cycles!)│
│                                 └──> Order Arrives Late (TICK MISSED)   │
│                                                                         │
│ SUITE MITIGATIONS:                                                      │
│ 1. isolcpus=domain,nohz,<trading_cores> → Eliminates CFS switches       │
│ 2. nohz_full=<trading_cores>            → Disables timer ticks          │
│ 3. Dynamic IRQ Shielding                → Moves IRQs to HK core(s)      │
│ 4. migration_cost_ns=5000000            → Penalizes thread migration    │
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

### 3. Step-by-Step Keystroke Walkthrough & Engineering Rationale

Follow these exact keystroke sequences mapped directly to the Supermicro H13SRD-F firmware menus. Every setting pairs its exact BIOS menu location and keystroke sequence with its low-level hardware mechanism, default failure mode, and low-latency HFT rationale, with all hardware acronyms fully defined.

#### Menu 1: Advanced → CPU Configuration (C-States, Frequency Determinism, SMT)
*Navigates to the core processor architecture controls for the AMD Ryzen 9 9900X / 9950X (Zen 5 microarchitecture).*

1. At the top navigation bar, press `[→]` to highlight **`Advanced`**.
2. Press `[↓]` to select **`CPU Configuration`**, then press `[Enter]`.
3. Configure the following settings:

   ##### • Global C-state Control (CPU Core Power States) → Select `[Disabled]` *(Default: `[Enabled]` / `[Auto]`)*
   * **Acronym Meaning:** In the ACPI (Advanced Configuration and Power Interface) specification, the **"C" in C-State stands for CPU Core Power State** (or Processor Idle Sleep State), contrasting with P-States (Performance States) and S-States (System Sleep States). $C_0$ is the operational state (CPU executing instructions), while $C_1$ through $C_6$ represent progressively deeper power-saving sleep modes.
   * **What it's doing:** Controls autonomous hardware power-saving idle states ($C_1$ Halt, $C_{1E}$ Enhanced Halt, $C_6$ Deep Power Down). When execution pipelines stall or the operating system issues an `MWAIT`/`HLT` instruction during quiet market periods, the CPU power control unit drops core voltage ($V_{core}$) near 0V, gates the high-frequency clock generator, and flushes pipeline execution state.
   * **Why the default is bad (The Latency Killer):** In quantitative trading, market events arrive in stochastic, bursty cascades. A symbol can experience silence for hundreds of microseconds, followed by an immediate quote sweep. If the core dropped into deep sleep ($C_6$) during that lull, waking up back to $C_0$ requires ramping voltage regulators and relocking the Phase-Locked Loop (PLL). This incurs a **50 µs to 150 µs wakeup penalty ($t_{wake}$)** during which your algorithm cannot process incoming market data.
   * **Why the new value is good (The Fix):** Forces all Zen 5 cores and the Data Fabric (DF) to remain permanently locked in the **$C_0$ active state 100% of the time**. Voltage rails stay energized, clocks never gate, and wakeup latency is eliminated (**0 ns wake penalty**). When packet DMA arrives, the core begins instruction execution on the very next CPU clock cycle.

   ##### • PSS Support (Performance Supported States / ACPI P-States) → Select `[Disabled]` *(Default: `[Enabled]`)*
   * **Acronym Meaning:** **PSS** stands for **Performance Supported States** (ACPI `_PSS`), which defines the operating frequency and voltage scaling tables (P-States, where $P_0$ is maximum frequency and $P_1 \dots P_n$ are downclocked power-saving states).
   * **What it's doing:** Directs UEFI (Unified Extensible Firmware Interface) firmware to construct and export ACPI `_PSS` and `_PCT` (Performance Control) description tables to the operating system. These tables inform the Linux kernel CPU frequency governor (`schedutil`, `ondemand`) of valid voltage/frequency operational points.
   * **Why the default is bad (The Latency Killer):** Under default settings, the OS dynamically lowers core clock speeds (e.g., dropping from 4.3 GHz down to 2.2 GHz) during periods of lower perceived utilization. When trading volume surges, the OS governor requires multiple sampling windows (10–20 ms) to detect the load and request a frequency ramp. In that window, your order execution logic processes packets at half speed. Furthermore, frequency scaling causes clock phase drift and variable instruction execution timing.
   * **Why the new value is good (The Fix):** Strips dynamic scaling tables from the ACPI interface. The kernel is physically barred from requesting lower frequency states, locking the processor at its maximum deterministic base frequency. Every instruction cycle takes a fixed, predictable time, eliminating clock drift jitter.

   ##### • SMT Control (Simultaneous Multi-Threading) → Select `[Disabled]` *(Default: `[Auto]` / `[Enabled]`)*
   * **Acronym Meaning:** **SMT** stands for **Simultaneous Multi-Threading** (AMD's implementation of hardware multithreading, analogous to Intel's Hyper-Threading).
   * **What it's doing:** Exposes two logical execution contexts (hardware threads) per physical Zen 5 core by duplicating architectural register files while sharing the single physical execution engine, execution ports, and cache hierarchy.
   * **Why the default is bad (The Latency Killer):**
     1. **L1d & L2 Cache Eviction:** Both threads share the identical physical **48 KB L1 Data (L1d) cache and 1 MB L2 cache**. A non-trading thread (e.g. OS background worker, logging task) running on the sibling thread actively evicts your trading loop's hot order book lines and ring buffer pointers from L1 and L2 in real time.
     2. **Pipeline Resource Starvation:** SMT dynamically multiplexes execution ports and ALUs (Arithmetic Logic Units). If the sibling thread issues instructions, the trading loop's execution is stalled at the issue queue, causing unpredictable microsecond latency spikes.
   * **Why the new value is good (The Fix):** Disabling SMT ensures that **100% of the 48 KB L1d cache, 32 KB L1i (L1 Instruction) cache, 1 MB L2 cache, all TLBs (Translation Lookaside Buffers), and all execution units are TOTALLY PRIVATE** and exclusively dedicated to your pinned trading algorithm. Cache thrashing and pipeline resource contention between sibling threads are physically eliminated. Yields 12 dedicated physical cores on the 9900X (or 16 on the 9950X).

   ##### • Core Performance Boost (CPB / AMD Precision Boost) → Select `[Disabled]` *(Default: `[Auto]` / `[Enabled]`)*
   * **Acronym Meaning:** **CPB** stands for **Core Performance Boost** (AMD's commercial implementation of opportunistic dynamic turbo overclocking, also known as Precision Boost).
   * **What it's doing:** AMD's autonomous dynamic overclocking algorithm. Precision Boost constantly monitors thermal headroom, VRM (Voltage Regulator Module) currents (TDC: Thermal Design Current / EDC: Electrical Design Current), and package power (PPT: Package Power Tracking), dynamically pushing individual core frequencies above base clock (e.g., from 4.30 GHz up to 5.70 GHz).
   * **Why the default is bad (The Latency Killer):**
     1. **PLL Relocking Pauses:** Every time the boost controller switches multipliers between frequencies, the internal Phase-Locked Loop (PLL) must relock, pausing instruction issue for tens of microseconds.
     2. **Thermal Downclocking Under Load:** When a market cascade occurs and multiple cores wake up, aggregate thermal and current budgets are exceeded. The CPU suddenly downclocks all cores (e.g., from 5.7 GHz down to 4.4 GHz). The algorithm runs fast during trivial market moments, but gets throttled and slowed down precisely during peak market volatility when speed matters most.
   * **Why the new value is good (The Fix):** Locks the processor into a constant, immovable base frequency (e.g., 4.30 GHz flat). Every clock cycle takes an identical **0.232 ns**. There is **0.000% clock drift, zero PLL relocking pause, and zero thermal downclocking**, transforming an unpredictable latency distribution with fat tails into a razor-sharp deterministic spike.

   ##### • SVM Mode (Secure Virtual Machine / AMD-V) → Keep `[Enabled]` *(for development / testbed VMs)* or `[Disabled]` *(bare-metal production)*
   * **Acronym Meaning:** **SVM** stands for **Secure Virtual Machine** (AMD's hardware virtualization extensions, commercially known as AMD-V).
   * **What it's doing:** Enables the AMD-V hardware virtualization instruction set (`VMRUN`, `VMLOAD`, Nested Page Tables) for hypervisor-assisted virtualization.
   * **Why the default / tuned value:** On bare-metal production trading nodes running directly on physical hardware, disabling SVM eliminates virtualization microcode paths. On development hosts, simulation testbeds, and KVM (Kernel-based Virtual Machine) environments (such as this project's AlmaLinux 10 testbed), SVM must remain **`[Enabled]`** to provide hardware-accelerated CPU virtualization for simulation instances.

4. Press `[Esc]` to return to the **`Advanced`** menu.

#### Menu 2: Advanced → North Bridge Configuration (Memory & IOMMU)
*Configures DDR5 memory mapping and DMA (Direct Memory Access) virtualization translation.*

1. From the **`Advanced`** menu, press `[↓]` to select **`North Bridge Configuration`**, then press `[Enter]`.
2. Configure the following settings:

   ##### • Above 4GB MMIO Limit (Memory-Mapped Input/Output) → Select `[40bit (1TB)]` *(Default: `[Auto]`)*
   * **Acronym Meaning:** **MMIO** stands for **Memory-Mapped Input/Output**, which maps hardware device registers and packet buffers into the host CPU's memory address space.
   * **What it's doing:** Configures the physical MMIO address decode window above the 4GB boundary. Selecting `[40bit (1TB)]` allocates a 40-bit physical address aperture (1 Terabyte) for PCI device BARs (Base Address Registers).
   * **Why the default is bad (The Latency Killer):** Default BIOS configurations frequently restrict MMIO windows to 32-bit legacy address space (< 4 GB). Enterprise ultra-low latency NICs (e.g., Intel 82599, Solarflare Onload, Mellanox ConnectX) and FPGA (Field-Programmable Gate Array) accelerators require hundreds of megabytes to gigabytes of BAR aperture for packet queues, hardware timestamp registers, and direct register access. Restricting MMIO causes resource allocation failures, initialization stalls, or forces drivers into slow bounce buffering.
   * **Why the new value is good (The Fix):** Guarantees a massive, contiguous 1TB address window where all high-speed network interfaces, FPGAs, and NVMe (Non-Volatile Memory Express) controllers can cleanly map their hardware memory apertures without resource contention or clipping.

   ##### • IOMMU (Input-Output Memory Management Unit / AMD-Vi) → Select `[Disabled]` *(Default: `[Auto]` / `[Enabled]`)*
   * **Acronym Meaning:** **IOMMU** stands for **Input-Output Memory Management Unit** (branded by AMD as AMD-Vi: AMD Virtualization for Directed I/O).
   * **What it's doing:** Controls the hardware IOMMU, which translates device virtual memory addresses (IOVA: Input-Output Virtual Addresses) to system physical DRAM addresses for all PCIe DMA (Direct Memory Access) operations.
   * **Why the default is bad (The Latency Killer):**
     1. **IOTLB Miss Penalties:** Every packet DMA written by the network card must pass through the IOMMU address translation hardware. When an IOTLB (Input-Output Translation Lookaside Buffer) miss occurs, the IOMMU must walk I/O page tables in system RAM, adding **100 ns to 300+ ns of pure latency** to packet arrival.
     2. **DMA Queue Backpressure:** Under heavy market bursts (millions of packets/sec), constant IOTLB thrashing creates memory backpressure on the NIC, causing packet drops in the NIC FIFO (First-In, First-Out) hardware queue.
   * **Why the new value is good (The Fix):** Disabling the IOMMU in BIOS gives the trading NIC direct, unhindered 1:1 access to physical DRAM via native DMA. Incoming packet buffers and AF_XDP zero-copy UMEM (User Memory) regions are written directly into host memory with **0 ns address translation penalty**, completely eliminating IOTLB misses.

   ##### • PPT Control (Package Power Tracking) → Keep `[Auto]` *(Default: `[Auto]`)*
   * **Acronym Meaning:** **PPT** stands for **Package Power Tracking**, the maximum allowable electrical power (in Watts) that the CPU socket is permitted to draw from the motherboard VRMs (Voltage Regulator Modules).
   * **What it's doing:** Limits the maximum continuous electrical wattage that the CPU socket is allowed to consume from the motherboard VRMs.
   * **Why the default is bad:** When paired with aggressive Precision Boost overclocking, high default power limits generate rapid thermal spikes that cause acoustic fan oscillations and severe thermal frequency throttling.
   * **Why the new value is good (The Fix):** When Core Performance Boost (CPB) is disabled, keeping PPT at `[Auto]` guarantees that the processor operates well within its thermal design envelope (< 55°C), ensuring stable silicon temperatures and eliminating power-budget frequency throttling.

3. Press `[Esc]` to return to the **`Advanced`** menu.

#### Menu 3: Advanced → PCIe/PCI/PnP Configuration (Bus States & BAR)
*Optimizes the PCIe (Peripheral Component Interconnect Express) interconnect and PnP (Plug and Play) resource allocation for low-latency network cards and NVMe storage.*

1. From the **`Advanced`** menu, press `[↓]` to select **`PCIe/PCI/PnP Configuration`**, then press `[Enter]`.
2. Under **PCI Devices Common Settings**, configure:

   ##### • Above 4G Decoding → Select `[Enabled]` *(Default: `[Disabled]` / `[Auto]`)*
   * **Acronym Meaning:** Enables 64-bit memory space decoding for PCIe **BARs (Base Address Registers)** above the 4 Gigabyte physical memory boundary.
   * **What it's doing:** Allows PCIe peripherals to allocate memory-mapped register apertures in high 64-bit address space.
   * **Why the default is bad (The Latency Killer):** When disabled, all PCIe peripherals are forced to cram their memory windows into the 32-bit address space below 4 GB (which is heavily congested with ACPI tables, APIC [Advanced Programmable Interrupt Controller] registers, and legacy devices). Modern enterprise trading NICs and FPGAs with large BAR allocations will fail to allocate resources or suffer severe memory window fragmentation.
   * **Why the new value is good (The Fix):** Unlocks the entire 64-bit physical address space for PCIe devices, allowing the OS to map large hardware packet buffers, circular ring descriptors, and hardware timestamping registers contiguously and cleanly.

   ##### • Re-Size BAR Support (Resizable Base Address Register) → Select `[Enabled]` *(Default: `[Disabled]`)*
   * **Acronym Meaning:** **BAR** stands for **Base Address Register**; **Re-Size BAR** stands for **Resizable Base Address Register** (part of PCIe specifications, also known commercially as AMD Smart Access Memory).
   * **What it's doing:** Overcomes the legacy PCIe specification limit that restricted Base Address Registers to a maximum size of 256 MB. Resizable BAR enables the CPU and PCIe root complex to negotiate a BAR aperture that covers the **entire onboard physical memory capacity** of the peripheral in a single mapping.
   * **Why the default is bad (The Latency Killer):** When disabled, the CPU can only access device memory through a narrow 256 MB window. If a smartNIC, FPGA, or GPU accelerator has gigabytes of onboard packet memory, the CPU must constantly shift 256 MB window offsets through driver calls, introducing driver remapping overhead and microsecond access bubbles.
   * **Why the new value is good (The Fix):** The host CPU can directly address the entire memory space of the PCIe accelerator in a single linear mapping. The trading engine reads and writes hardware packet queues and execution tables directly with zero aperture-swap delay.

   ##### • SR-IOV Support (Single Root I/O Virtualization) → Select `[Enabled]` *(Default: `[Disabled]`)*
   * **Acronym Meaning:** **SR-IOV** stands for **Single Root Input/Output Virtualization**.
   * **What it's doing:** Enables the PCIe root complex to recognize Single Root I/O Virtualization hardware attributes, allowing a physical network interface (PF: Physical Function) to expose multiple independent Virtual Functions (VFs) with dedicated DMA engines and packet queues.
   * **Why the default is bad:** When disabled in firmware, the network card cannot partition its hardware queues or expose hardware-isolated virtual channels to user-space trading engines or kernel-bypass queues.
   * **Why the new value is good (The Fix):** Enables hardware queue partitioning. A dedicated Virtual Function (VF) can be attached directly to an isolated trading container or thread, providing dedicated hardware packet rings without sharing queues or conflicting with host administrative traffic.

   ##### • BME DMA Mitigation (Bus Master Enable DMA Mitigation) → Select `[Disabled]` *(Default: `[Enabled]`)*
   * **Acronym Meaning:** **BME** stands for **Bus Master Enable**; **DMA** stands for **Direct Memory Access**; **SMM** stands for **System Management Mode** (the highest privilege CPU execution mode, Ring -2).
   * **What it's doing:** A firmware security feature that revokes the Bus Master Enable (BME) attribute on PCIe devices during boot and System Management Mode (SMM) interrupts to guard against DMA injection attacks before OS driver initialization.
   * **Why the default is bad (The Latency Killer):** If the firmware triggers an SMM interrupt (e.g. for thermal polling, chassis sensors, or legacy USB handling), BME DMA Mitigation can temporarily revoke or stall Bus Master capabilities on the PCIe bus. An unexpected DMA stall on your trading NIC causes packets to back up and drop at the wire, inducing fatal multi-millisecond trading freezes.
   * **Why the new value is good (The Fix):** Prevents firmware from ever revoking or pausing Bus Master Enable on PCIe slots, guaranteeing uninterrupted, non-blocking DMA transmission between the trading NIC and system memory.

   ##### • ASPM Support (Active State Power Management) → Select `[Disabled]` *(Default: `[Auto]` / `[Enabled]` / `[L1]`)*
   * **Acronym Meaning:** **ASPM** stands for **Active State Power Management** (the PCIe link-level autonomous power management protocol defined in the PCI-SIG specifications).
   * **What it's doing:** Controls autonomous link-level power management on PCIe lanes. When PCIe bus traffic pauses between the network card and the CPU, ASPM commands the physical link to transition into low-power states: **$L_0s$** (standby) and **$L_1$** (clock-gated sleep, reducing power by up to 80%).
   * **Why the default is bad (The Latency Killer):** In trading, milliseconds of silence occur between market events. During these quiet periods, ASPM drops the PCIe link into the $L_1$ sleep state. When a packet arrives from the exchange, the PCIe transceivers **must wake up, un-gate clocks, and re-establish physical bit synchronization and link training** before any data can be transferred across the bus. This imposes a **10 µs to 50 µs link wakeup penalty ($t_{L1\_wake}$)**! The packet sits stalled in the NIC FIFO while the PCIe bus powers back on.
   * **Why the new value is good (The Fix):** Completely deactivates PCIe power saving. The PCIe Gen 4 / Gen 5 differential signaling pairs remain permanently energized in the **$L_0$ Full-Power Active state 100% of the time**. The nanosecond a packet is decoded by the physical PHY (Physical Layer transceiver), it is transmitted across the PCIe bus to host DRAM with **0 ns link wakeup delay**.

   ##### • Relaxed Ordering (PCIe Transaction Layer Packet Attribute) → Select `[Enabled]` *(Default: `[Disabled]`)*
   * **Acronym Meaning:** Pertains to the **TLP (Transaction Layer Packet)** ordering rules in the PCIe protocol.
   * **What it's doing:** Controls the Relaxed Ordering attribute in PCIe Transaction Layer Packets. By strict PCI transaction ordering rules, transactions heading in the same direction must be completed in strict chronological order to prevent producer-consumer hazards. Relaxed Ordering relaxes this constraint for transactions that have no data dependency on prior completions.
   * **Why the default is bad (The Latency Killer):** Strict PCI ordering causes severe head-of-line blocking: if an earlier read transaction is delayed waiting for DRAM, all subsequent packet writes and ring buffer status descriptors are completely stalled behind it in the PCIe switch and root complex queues.
   * **Why the new value is good (The Fix):** Allows independent packet DMA writes and descriptor updates to bypass unrelated pending reads in the PCIe root complex pipeline. This maximizes PCIe bus bandwidth and ensures fast, immediate packet delivery during market data quote bursts.

   ##### • No Snoop (PCIe Cache Coherency Attribute) → Select `[Enabled]` *(Default: `[Disabled]`)*
   * **Acronym Meaning:** Pertains to CPU **Cache Snooping** (hardware cache-coherency bus inquiries across CPU cores).
   * **What it's doing:** Controls the No Snoop bit in PCIe Transaction Layer Packets. When a PCIe device writes data to host RAM, standard cache-coherency protocols force the CPU cache controllers to "snoop" all L1, L2, and L3 caches across all cores to invalidate or update duplicate cache lines.
   * **Why the default is bad (The Latency Killer):** Enforcing hardware cache snooping on every single incoming market data packet generates massive, unnecessary coherency traffic across the AMD Infinity Fabric and stalls CPU cache controllers, increasing memory access latency and causing pipeline jitter.
   * **Why the new value is good (The Fix):** In optimized HFT architectures using uncached packet memory (such as AF_XDP zero-copy UMEM [User Memory] or kernel-bypass hugepages), the NIC sets the No Snoop bit. The PCIe root complex writes packet data directly into DRAM or the targeted cache lines without broadcasting snoop requests to other cores, reducing interconnect traffic and saving valuable CPU cycles.

   ##### • NVMe Firmware Source & RAID Mode (Non-Volatile Memory Express)
   * **Acronym Meaning:** **NVMe** stands for **Non-Volatile Memory Express**; **RAID** stands for **Redundant Array of Independent Disks**; **AHCI** stands for **Advanced Host Controller Interface**.
   * Keep **`NVMe Firmware Source`** → **`[AMI Native Support]`**
   * Keep **`NVMe RAID Mode`** → **`[Disabled]`** *(AHCI / Native NVMe)*

3. Press `[Esc]` to return to the **`Advanced`** menu.

#### Menu 4: Advanced → Network Configuration (Intel 82599 Dual 10GbE)
*Displays physical MAC (Media Access Control) addresses and PXE (Preboot Execution Environment) boot configurations for onboard dual 10GbE SFP+ (Enhanced Small Form-factor Pluggable) controllers (`MAC:90:5A:08:3E:00:E6` and `MAC:90:5A:08:3E:00:E7`). Verify network interfaces are detected and healthy.*

#### Menu 5: Save & Exit
1. Press `[F4]` (or press `[→]` to highlight the **`Save & Exit`** tab and select **`Save Changes and Reset`**).
2. Select **`[Yes]`** to confirm and reboot.

### 4. Comprehensive Deep Dive: Every BIOS / UEFI Setting Explained

To eliminate jitter before the operating system even boots, you must configure the motherboard firmware (BIOS/UEFI). Below is an exhaustive breakdown of **every single BIOS setting**, written from the perspective of low-latency market data processing.

---

#### BIOS Setting 1: Global C-state Control
* **What it is:** C-states (Sleep States) are hardware power-saving modes. When a CPU core has no immediate instructions to execute, the motherboard firmware shuts down internal clock generators, lowers core voltages, and flushes CPU cache lines to save power. C0 is the fully active state, while C1, C2, and C6 represent progressively deeper sleep.
* **Untuned Config Value:** `[Enabled]` or `[Auto]`
* **Tuned Config Value:** `[Disabled]`
* **What Difference It Makes:** When disabled, CPU cores are permanently locked in C0 active mode. They consume more idle power (~40-80W higher system power draw), but core wake-up latency drops from **50–150 microseconds to exactly 0 nanoseconds**.
* **Why It's Important for Market Data:** Market data is bursty. During quiet millisecond gaps between exchange quote updates (e.g. between order book events on NASDAQ ITCH), the CPU enters C6 sleep. When the next quote packet hits the wire, the core is asleep and takes up to 150 µs to wake up! Disabling C-states guarantees your parser reacts instantly.

```text
┌─────────────────────────────────────────────────────────────────────────┐
│ GLOBAL C-STATE CONTROL: IDLE SLEEP vs CONTINUOUS EXECUTION              │
├─────────────────────────────────────────────────────────────────────────┤
│ UNTUNED ([Enabled]):                                                    │
│ Core State: [ C6 Deep Sleep (Powered Off) ]                             │
│ Market Quote arrives on wire ──> Wake-up signal sent to CPU             │
│   ├── Voltage Regulator ramps up voltage (20 µs)                        │
│   ├── Phase-Locked Loop (PLL) relocks clock frequency (30 µs)           │
│   └── Cache controller restores pipeline state (50-100 µs)              │
│ Total Penalty: 100 to 150 µs delay before your parser runs a single byte!│
│                                                                         │
│ TUNED ([Disabled]):                                                     │
│ Core State: [ C0 Active (Executing at 100% duty cycle) ]                │
│ Market Quote arrives on wire ──> Instant processing in 0 ns wake delay! │
└─────────────────────────────────────────────────────────────────────────┘
```

---

#### BIOS Setting 2: PSS Support (Processor Performance States)
* **What it is:** ACPI PSS (Performance State Support) exposes dynamic frequency and voltage tables (P-states) to the Linux operating system. It allows operating system governors to throttle CPU clock speeds up or down depending on workload.
* **Untuned Config Value:** `[Enabled]`
* **Tuned Config Value:** `[Disabled]`
* **What Difference It Makes:** Disabling PSS strips the ACPI dynamic scaling tables from the OS ACPI tables. The Linux kernel is prevented from throttling frequency; the CPU runs at a fixed, unvarying clock speed.
* **Why It's Important for Market Data:** When P-states are active, the CPU frequency constantly fluctuates between base clock (e.g., 2.5 GHz) and maximum clock. If a burst of quotes arrives while the core is down-clocked, your processing throughput is cut in half until the OS governor notices the load. Disabling PSS enforces 100% deterministic clock frequency.

---

#### BIOS Setting 3: SMT Control (Simultaneous Multi-Threading)
* **What it is:** SMT (AMD's term for Hyper-Threading) presents two virtual "logical cores" to the operating system for each single physical silicon core. Both virtual threads share the exact same physical execution units (ALUs, vector registers) and Level 1 / Level 2 caches.
* **Untuned Config Value:** `[Enabled]` or `[Auto]` (16 physical cores appear as 32 threads)
* **Tuned Config Value:** `[Disabled]` (16 physical cores appear as 16 physical cores)
* **What Difference It Makes:** Eliminates execution resource contention and cache thrashing. Guarantees that 100% of the core's physical pipeline and 100% of the 32KB L1 data cache is dedicated exclusively to your trading process.
* **Why It's Important for Market Data:** When SMT is enabled, if your ITCH market data thread is running on Thread 0, and a random background process (e.g., SSH daemon, cron job, OS logger) runs on Thread 1, the background process steals execution cycles and evicts your order book from the L1 cache. This produces unpredictable 5–30 µs tail latency spikes.

```text
┌─────────────────────────────────────────────────────────────────────────┐
│ SMT (HYPER-THREADING): RESOURCE SHARING vs DEDICATED SILICON             │
├─────────────────────────────────────────────────────────────────────────┤
│ SMT ENABLED (Untuned Default: 2 Logical Threads per Physical Core):     │
│   Physical Core 0                                                       │
│   ├── Logical Thread 0: [ NASDAQ ITCH Feed Parser ]                     │
│   └── Logical Thread 1: [ Background OS Task (sshd / cron) ]            │
│       Both threads fight for:                                           │
│       - 32 KB L1 Data Cache (cache lines evict each other!)             │
│       - Arithmetic Logic Units (ALUs) & Branch Predictors               │
│       Result: Jitter spikes of 5 to 30 microseconds!                    │
│                                                                         │
│ SMT DISABLED (Tuned: 1 Dedicated Physical Core per Thread):              │
│   Physical Core 0                                                       │
│   └── Logical Thread 0: [ NASDAQ ITCH Feed Parser ]                     │
│       ├── 100% of L1 Data Cache (32 KB dedicated)                       │
│       ├── 100% of L2 Cache (1 MB dedicated)                             │
│       └── 100% of physical ALUs & execution ports                       │
│       Result: Zero contention, rock-solid determinism!                  │
└─────────────────────────────────────────────────────────────────────────┘
```

---

#### BIOS Setting 4: Core Performance Boost (CPB / Turbo Boost)
* **What it is:** CPB (AMD's equivalent to Intel Turbo Boost) dynamically overclocks active cores above their rated base frequency when power and thermal limits permit. For example, boosting an AMD 9950X core from 4.3 GHz base up to 5.7 GHz boost.
* **Untuned Config Value:** `[Enabled]` or `[Auto]`
* **Tuned Config Value:** `[Disabled]` (or locked to fixed all-core multiplier in extreme overclocking)
* **What Difference It Makes:** Eliminates frequency modulation jitter. When CPB engages or disengages, the CPU's Phase-Locked Loop (PLL) must relock clock multipliers, freezing instruction execution for several microseconds. It also avoids thermal throttling drops after prolonged bursts.
* **Why It's Important for Market Data:** While boosting to 5.7 GHz sounds attractive, the *variation* in clock speed causes tick-to-trade latency to vary wildly depending on core temperature and how many other cores are active. Low-latency trading demands **repeatable determinism**: every packet must be processed in the exact same number of nanoseconds, morning or afternoon.

---

#### BIOS Setting 5: Above 4GB MMIO Limit
* **What it is:** Memory-Mapped I/O (MMIO) assigns physical memory addresses to hardware devices (like high-speed PCIe network cards and NVMe controllers) so the CPU can communicate with them. This setting determines the address decoding width (e.g., 40-bit / 1TB).
* **Untuned Config Value:** `[Auto]` or limited to 32-bit (under 4GB)
* **Tuned Config Value:** `[40bit (1TB)]`
* **What Difference It Makes:** Ensures that 64-bit PCIe network cards with large memory apertures (e.g., dual-port Intel 10GbE / 100GbE NICs with multi-gigabyte descriptor queues) can allocate their memory-mapped registers above the 4GB boundary without memory window conflicts.
* **Why It's Important for Market Data:** Modern multi-queue trading network cards allocate extensive DMA descriptor rings and hardware packet buffers. Limiting MMIO below 4GB causes device address collisions, reduced queue allocations, or driver fallback to slow PIO modes.

---

#### BIOS Setting 6: IOMMU (AMD-Vi / Intel VT-d)
* **What it is:** The Input-Output Memory Management Unit (IOMMU) is a hardware component that translates device physical addresses (DMA addresses) into system physical RAM addresses. It acts like virtual memory page tables, but for PCIe peripherals rather than CPU threads.
* **Untuned Config Value:** `[Enabled]`
* **Tuned Config Value:** `[Disabled]`
* **What Difference It Makes:** When enabled, every packet DMA transaction from the NIC must pass through the IOMMU's hardware translation buffer (IOTLB). On an IOTLB miss, the hardware walks page tables in DRAM, adding **100–300 nanoseconds** to every packet write. Disabling IOMMU allows the NIC to write directly to physical memory addresses with zero translation penalty.
* **Why It's Important for Market Data:** When a sudden volume burst hits the exchange (e.g. non-farm payroll release), hundreds of thousands of UDP multicast packets hit the NIC in milliseconds. IOTLB misses create backpressure in the PCIe controller, causing FIFO overflow drops inside the NIC. Direct physical DMA eradicates this bottleneck.

```text
┌─────────────────────────────────────────────────────────────────────────┐
│ IOMMU (AMD-Vi): DMA PACKET TRANSLATION vs DIRECT PHYSICAL ACCESS        │
├─────────────────────────────────────────────────────────────────────────┤
│ IOMMU ENABLED (Untuned Default - Virtualization Safety Layer):          │
│   NIC DMA Packet ──> [ IOMMU Hardware ] ──> Physical RAM                │
│                            │                                            │
│                       IOTLB Miss?                                       │
│                       CPU walks I/O Page Tables in DRAM (~150-300 ns)   │
│                       Latency penalty on high-frequency packet bursts!  │
│                                                                         │
│ IOMMU DISABLED (Tuned - Direct Hardware Memory Access):                 │
│   NIC DMA Packet ─────────────────────────> Physical RAM                │
│               Direct PCIe DMA write: ZERO translation delay!            │
└─────────────────────────────────────────────────────────────────────────┘
```

---

#### BIOS Setting 7: Above 4G Decoding
* **What it is:** Enables or disables 64-bit capable PCIe devices to decode memory spaces located above 4GB in the system memory map.
* **Untuned Config Value:** `[Disabled]`
* **Tuned Config Value:** `[Enabled]`
* **What Difference It Makes:** Opens up the vast 64-bit memory space for peripheral devices. Required prerequisite for enabling PCIe Resizable BAR (Re-Size BAR).
* **Why It's Important for Market Data:** High-throughput trading NICs (Intel E810, X520, Mellanox ConnectX) and FPGA accelerators require 64-bit address spaces to map their high-capacity packet ring buffers and hardware timestamping registers directly.

---

#### BIOS Setting 8: Re-Size BAR (Resizable Base Address Register)
* **What it is:** Base Address Registers (BARs) define how much of a PCIe device's on-board memory the CPU can map into its own address space at one time. Historically, legacy PCIe restricted this aperture to a tiny 256 megabytes. Re-Size BAR allows the CPU to map the device's entire memory space simultaneously.
* **Untuned Config Value:** `[Disabled]`
* **Tuned Config Value:** `[Enabled]`
* **What Difference It Makes:** Eliminates aperture banking. The CPU can read and write to all network card registers, descriptor queues, and on-card packet buffers in a single continuous memory operation without having to re-point aperture translation windows.
* **Why It's Important for Market Data:** Enables ultra-low-latency direct MMIO access. When your execution engine transmits an order over an AF_XDP or kernel-bypass ring, the CPU writes the outbound descriptor directly into NIC memory across the PCIe bus in a single unfragmented instruction.

```text
┌─────────────────────────────────────────────────────────────────────────┐
│ RE-SIZE BAR: LEGACY 256MB APERTURE vs FULL APERTURE DIRECT ACCESS       │
├─────────────────────────────────────────────────────────────────────────┤
│ LEGACY BAR (Untuned Default: 256 MB Window):                            │
│   CPU Memory Map: [ 256 MB Window ] <── Small view into device memory   │
│   Accessing buffers outside 256 MB requires reprogramming BAR windows!  │
│   Adds overhead and stall cycles during high-throughput I/O.            │
│                                                                         │
│ RE-SIZE BAR ENABLED (Tuned: Full Aperture Mapping):                     │
│   CPU Memory Map: [ FULL DEVICE MEMORY MAPPED CONTINUOUSLY ]            │
│   The entire NIC / FPGA memory space is directly accessible.            │
│   Fast, single-cycle MMIO writes for order dispatch!                   │
└─────────────────────────────────────────────────────────────────────────┘
```

---

#### BIOS Setting 9: SR-IOV Support (Single Root I/O Virtualization)
* **What it is:** SR-IOV allows a physical PCIe network card (Physical Function, PF) to partition its hardware resources into multiple virtual network cards (Virtual Functions, VFs).
* **Untuned Config Value:** `[Disabled]`
* **Tuned Config Value:** `[Enabled]`
* **What Difference It Makes:** Prepares hardware support for virtualized queue slicing. Even on bare-metal systems, having SR-IOV enabled allows trading architects to slice hardware queues into isolated virtual endpoints if needed.
* **Why It's Important for Market Data:** Provides flexibility to dedicate an isolated Virtual Function with its own dedicated PCIe queue directly to a specific container or thread without touching the primary management interface.

---

#### BIOS Setting 10: BME DMA Mitigation
* **What it is:** Bus Master Enable (BME) allows a PCIe peripheral to initiate Direct Memory Access (DMA) transactions across the motherboard bus. BME DMA Mitigation is a security feature that forces the BIOS to revoke DMA privileges from PCIe devices during certain boot stages and System Management Interrupts (SMM).
* **Untuned Config Value:** `[Enabled]`
* **Tuned Config Value:** `[Disabled]`
* **What Difference It Makes:** Disabling mitigation ensures that Bus Master DMA remains permanently enabled and active across all CPU and motherboard operating states, preventing unexpected DMA stalls.
* **Why It's Important for Market Data:** If the firmware resets or stalls Bus Master privileges on a PCIe slot, incoming market data packets queue up in the NIC's physical buffer and are eventually dropped, causing missing tick sequence numbers and catastrophic market data recovery storms.

---

#### BIOS Setting 11: ASPM Support (PCIe Active State Power Management)
* **What it is:** ASPM is a power-saving protocol for PCI Express lanes. When no data is traveling across the PCIe bus between the network card and the CPU, ASPM drops the PCIe link into lower power states (L0s and L1), reducing transceiver voltage.
* **Untuned Config Value:** `[Auto]` or `[Enabled]`
* **Tuned Config Value:** `[Disabled]`
* **What Difference It Makes:** Disabling ASPM locks all PCIe lanes in the **L0 (Full Power Active)** state permanently. It prevents PCIe link transitions, eliminating the **5 to 30 microsecond link wake-up delay**.
* **Why It's Important for Market Data:** When trading markets are quiet, no packets traverse the PCIe bus. ASPM puts the PCIe lanes to sleep. When the market moves and an exchange quote arrives, the network card cannot transfer the packet to the CPU until the PCIe physical link completes a full wake-up sequence! Disabling ASPM keeps the bus hot and ready 100% of the time.

```text
┌─────────────────────────────────────────────────────────────────────────┐
│ PCIE ASPM: LINK POWER STATES vs CONTINUOUS L0 READINESS                 │
├─────────────────────────────────────────────────────────────────────────┤
│ ASPM ENABLED (Untuned Default: Powers down PCIe lanes):                 │
│   PCIe Link State: [ L1 Low Power Sleep ]                               │
│   1. Market data packet arrives on physical fiber ──>                   │
│   2. NIC attempts to write packet via DMA ──>                           │
│   3. PCIe link is sleeping! NIC sends wake-up electrical beacon         │
│   4. PCIe link transitions L1 ──> L0s ──> L0 (5 to 30 µs delay!)        │
│   5. Packet finally DMA transfers into host memory.                     │
│   Total Jitter: 5 to 30 microseconds added to every quote burst!        │
│                                                                         │
│ ASPM DISABLED (Tuned: pcie_aspm=off):                                   │
│   PCIe Link State: [ L0 Permanent Active State ]                        │
│   Market data packet arrives ──> Instant DMA write to DRAM (0ns delay)! │
└─────────────────────────────────────────────────────────────────────────┘
```

---

#### BIOS Setting 12: Relaxed Ordering
* **What it is:** Standard PCIe transactions must strictly complete in the exact sequential order they were issued (Strong Ordering). Relaxed Ordering allows the PCIe controller to reorder certain memory transactions that do not depend on each other, preventing slow read operations from blocking independent packet writes.
* **Untuned Config Value:** `[Disabled]`
* **Tuned Config Value:** `[Enabled]`
* **What Difference It Makes:** Increases PCIe Transaction Layer Packet (TLP) throughput. Outbound write operations (such as order submissions or packet descriptors) do not stall waiting for unrelated reads to clear the bus.
* **Why It's Important for Market Data:** Prevents head-of-line blocking on the PCIe bus during market bursts, ensuring incoming market data DMA writes and outbound order execution packets pass each other without contention.

---

#### BIOS Setting 13: No Snoop
* **What it is:** In cache-coherent x86 architectures, whenever an external PCIe device writes data to RAM via DMA, the CPU must "snoop" its own L1/L2/L3 caches to verify if that memory address is currently cached. "No Snoop" is a PCIe attribute bit that signals the CPU that the target buffer is uncached, allowing the DMA transaction to bypass cache snooping.
* **Untuned Config Value:** `[Disabled]`
* **Tuned Config Value:** `[Enabled]`
* **What Difference It Makes:** Bypasses unnecessary CPU cache snooping cycles across the Infinity Fabric or CPU interconnect for streaming DMA packet buffers, reducing memory bus latency by **15–30 nanoseconds** per transfer.
* **Why It's Important for Market Data:** Market data packets are written once into temporary network ring buffers (UMEM or sk_buff). Bypassing cache snooping accelerates the hardware DMA transfer into RAM, allowing your parser thread to read the packet immediately.

---

### 5. Post-Boot Linux Verification Commands

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

### 1. Dynamic Hardware Analysis & Intelligent Core Partitioning Engine

A fundamental challenge in enterprise high-frequency trading infrastructure is that systems vary widely in physical scale: from lightweight 4-core edge acceleration gateways and development testbeds, to 16-core dual-CCD flagship trading rigs (e.g., AMD Ryzen 9 9950X), 24–32 core HEDT workstations (Threadripper 7960X/7970X), and 64–128 core high-density multi-socket server fabrics (AMD EPYC 9554/9754).

**Why Static Hardcoding (e.g., `1-15`) Is Broken in Production:**
1. **Single-Core / Small VMs:** On a single-core or dual-core VM testbed, statically requesting `1-15` either fails or attempts to isolate the only CPU in the system. Isolating Core 0 starves the Linux kernel of worker threads, stalling `kthreadd`, timer interrupts, and system daemons, leading to immediate system lockup or unbootable kernel panics.
2. **High-Core Count Saturation:** On a 32-core Threadripper or 64-core EPYC server, assigning **only** Core 0 as the sole housekeeping core creates a catastrophic interrupt bottleneck. Core 0 must process timer ticks, NVMe storage interrupts, multi-port 25GbE/100GbE NIC network interrupts, and deferred RCU garbage collection callbacks. With 31 or 63 cores generating RCU callbacks simultaneously, Core 0 suffers severe hardware interrupt vector exhaustion, overflowing `ksoftirqd` queues and introducing massive bus contention.
3. **Multi-CCD Cache Locality:** Modern processors (like the AMD Ryzen 9 9950X / 9900X) feature two physical Core Complex Dies (CCDs) connected via the Infinity Fabric. Core 0 sits on CCD0. By intelligently analyzing CCD boundaries, our engine assigns Core 0 on CCD0 to housekeeping, Cores 1–7 (CCD0) to auxiliary feed handlers and gateways, and reserves the entire CCD1 (Cores 8–15) exclusively for the quantitative alpha engine and order execution loops—guaranteeing 100% private, zero-contention L3 cache!

To resolve this, [`hft_tuning.sh`](hft_tuning.sh) implements an automated **Hardware Topology Discovery Engine** (`detect_hardware_topology()`) that queries `lscpu`, `/sys/devices/system/cpu`, and `/proc/meminfo` before generating bootloader parameters or applying runtime tunings.

#### The Core Partitioning Decision Matrix

| Detected Cores | Housekeeping Cores | HK Mask (Hex) | Trading Cores (Isolated) | Hardware Platform & Architectural Strategy |
| :--- | :--- | :--- | :--- | :--- |
| **1 Core** | Core 0 | `0x1` | *None* | **Single-Core Testbed / VM:** Isolation omitted to prevent kernel worker starvation and system lockup. |
| **2 Cores** | Core 0 | `0x1` | Core 1 (`1`) | **Dual-Core Appliance:** Core 0 absorbs all OS tasks; Core 1 runs dedicated trading loop. |
| **4–8 Cores** | Core 0 | `0x1` | Cores 1–(N-1) (e.g., `1-3` or `1-7`) | **Single-CCD Desktop (Core i3/i5/i7, Ryzen 7 9700X):** Core 0 handles OS & IRQs; remaining cores run trading loops. |
| **12–16 Cores** | Core 0 | `0x1` | Cores 1–(N-1) (e.g., `1-11` or `1-15`) | **Dual-CCD Flagship (Ryzen 9 9900X / 9950X):** Core 0 (CCD0) handles OS. CCD1 (Cores 8–15) dedicated to zero-jitter Alpha & Execution. |
| **24–32 Cores** | Cores 0–1 | `0x3` | Cores 2–(N-1) (e.g., `2-23` or `2-31`) | **HEDT Workstations (Threadripper 7960X / 7970X):** 2 Housekeeping Cores prevent IRQ vector saturation under multi-10GbE traffic. |
| **48–64 Cores** | Cores 0–3 | `0xf` | Cores 4–(N-1) (e.g., `4-47` or `4-63`) | **Enterprise Server (Threadripper 7980X, EPYC 9554):** 4 Housekeeping Cores absorb multi-queue NICs and NVMe arrays. |
| **>64 Cores** | Cores 0–7 | `0xff` | Cores 8–(N-1) (e.g., `8-95` on 7995WX, `8-127` on EPYC 9754) | **High-Density NUMA Fabric:** Dedicates an entire 8-core NUMA quadrant (Node 0) to housekeeping; 88–120 pure isolated cores. |

#### Dynamic DRAM-Scaled Static Hugepage Allocation

Pre-allocating static 2MB hugepages at boot avoids memory fragmentation. However, fixed page counts fail on small-memory VMs (causing boot failure or OOM killer invocation) while under-allocating on 128GB+ enterprise servers. The tuning suite dynamically provisions the static pool based on total physical DRAM:

| Detected System DRAM | 2MB Hugepages (`vm.nr_hugepages`) | Static Pool Size | Target Platform Rationale |
| :--- | :--- | :--- | :--- |
| **< 16 GB** | 512 pages | 1.0 GB Pool | Development VMs, mini-PCs, testbeds. Leaves ample memory for OS and compilation. |
| **16 GB – 31 GB** | 1,024 pages | 2.0 GB Pool | Mid-tier development workstations and edge execution gateways. |
| **32 GB – 127 GB** | 2,048 pages | 4.0 GB Pool | Standard bare-metal production trading servers (e.g. 32GB/64GB/96GB platforms like `cherry`). |
| **≥ 128 GB** | 4,096 pages | 8.0 GB Pool | Enterprise multi-market aggregators, high-density order book depth replay engines. |

#### Hardware Topology Architecture Diagrams

```text
┌────────────────────────────────────────────────────────────────────────────────────────┐
│ ARCHITECTURE A: DUAL-CCD 16-CORE PLATFORM (AMD Ryzen 9 9950X / X870E)                  │
├────────────────────────────────────────────────────────────────────────────────────────┤
│ [CCD 0: CORES 0 - 7]                              [CCD 1: CORES 8 - 15]                │
│ ┌──────────────┐ ┌──────────────────────────────┐ ┌──────────────────────────────────┐ │
│ │ Core 0 (HK)  │ │ Cores 1 - 7 (Isolated)       │ │ Cores 8 - 15 (Isolated)          │ │
│ │ Mask: 0x1    │ │ CFS / Tickless Shielded      │ │ CFS / Tickless Shielded          │ │
│ ├──────────────┤ ├──────────────────────────────┤ ├──────────────────────────────────┤ │
│ │ • Linux OS   │ │ • ITCH Multicast Receiver    │ │ • Quant Alpha Strategy Engine    │ │
│ │ • Peripheral │ │ • FIX / OUCH Gateway         │ │ • Sub-nanosecond Execution Loop  │ │
│ │   IRQs (NVMe)│ │ • Level 2 Book Aggregator    │ │ • Zero Context Switches          │ │
│ │ • RCU & Ticks│ │ • Logging & Telemetry        │ │ • 100% Pure Private 32MB L3 Cache│ │
│ └──────┬───────┘ └──────────────┬───────────────┘ └─────────────────┬────────────────┘ │
│        │                        │                                   │                  │
│   ┌────┴────────────────────────┴───┐                  ┌────────────┴────────────┐     │
│   │ CCD0 L3 Cache (32MB Unified)    │                  │ CCD1 L3 Cache (32MB)    │     │
│   │ (Subject to background OS lines)│                  │ (100% UNPOLLUTED L3!)   │     │
│   └────────────────┬────────────────┘                  └────────────┬────────────┘     │
│                    │                                                │                  │
│                    └───────────────────────┬────────────────────────┘                  │
│                                            ▼                                           │
│                       AMD Infinity Fabric / Unified Memory Controller                  │
│                                            │                                           │
│                                 [DRAM: 64GB DDR5-6000]                                 │
│                       (2048 x 2MB Static Hugepages Pre-allocated)                      │
└────────────────────────────────────────────────────────────────────────────────────────┘

┌────────────────────────────────────────────────────────────────────────────────────────┐
│ ARCHITECTURE B: HIGH-DENSITY ENTERPRISE NUMA FABRIC (Threadripper / EPYC / Multi-NUMA) │
├────────────────────────────────────────────────────────────────────────────────────────┤
│ [NUMA NODE 0: HOUSEKEEPING QUADRANT]             [NUMA NODES 1-3: TRADING SILICON]     │
│ ┌──────────────────────────────────────────────┐ ┌───────────────────────────────────┐ │
│ │ Cores 0 - 3 (or 0 - 7 on >64c systems)       │ │ Cores 4 - 63 (or 8 - 127)         │ │
│ │ Mask: 0xf (or 0xff)                          │ │ CFS & Tickless Isolated           │ │
│ ├──────────────────────────────────────────────┤ ├───────────────────────────────────┤ │
│ │ • High-throughput IRQ vector distribution    │ │ • Dedicated Exchange Market Feeds │ │
│ │ • Multi-port 25G/100G NIC management queues │ │ • Lock-free Ring Buffer Engines   │ │
│ │ • Enterprise NVMe RAID storage interrupts    │ │ • Hardware Tickless Execution     │ │
│ │ • All systemd, sshd, and monitoring services │ │ • Zero Cross-NUMA Invalidation    │ │
│ └──────────────────────┬───────────────────────┘ └─────────────────┬─────────────────┘ │
│                        │                                           │                   │
│               [Local Node 0 Memory]                       [Local Node 1-3 Memory]      │
│               (OS & Housekeeping Heap)                    (Static Hugetlbfs UMEM Pool) │
└────────────────────────────────────────────────────────────────────────────────────────┘
```

---

### 2. Master Kernel Boot Parameter Specification

The tuning suite dynamically substitutes `<trading_cores>` and `<hugepages_count>` into the master kernel parameter string based on the host's audited topology:

```text
isolcpus=domain,nohz,<trading_cores> nohz=on nohz_full=<trading_cores> rcu_nocbs=<trading_cores> rcupdate.rcu_normal_after_boot=1 skew_tick=1 preempt=full nosmt audit=0 mce=ignore_ce transparent_hugepage=never default_hugepagesz=2M hugepages=<hugepages_count> pcie_aspm=off mitigations=off
```

#### Production Boot String Examples

* **16-Core Flagship Bare-Metal (Ryzen 9 9950X, 64GB RAM):**
  ```text
  isolcpus=domain,nohz,1-15 nohz=on nohz_full=1-15 rcu_nocbs=1-15 rcupdate.rcu_normal_after_boot=1 skew_tick=1 preempt=full nosmt audit=0 mce=ignore_ce transparent_hugepage=never default_hugepagesz=2M hugepages=2048 pcie_aspm=off mitigations=off
  ```
* **4-Core Testbed / VM (Core i3-9100T, 16GB RAM):**
  ```text
  isolcpus=domain,nohz,1-3 nohz=on nohz_full=1-3 rcu_nocbs=1-3 rcupdate.rcu_normal_after_boot=1 skew_tick=1 preempt=full nosmt audit=0 mce=ignore_ce transparent_hugepage=never default_hugepagesz=2M hugepages=1024 pcie_aspm=off mitigations=off
  ```
* **32-Core Workstation (Threadripper 7970X, 128GB RAM):**
  ```text
  isolcpus=domain,nohz,2-31 nohz=on nohz_full=2-31 rcu_nocbs=2-31 rcupdate.rcu_normal_after_boot=1 skew_tick=1 preempt=full nosmt audit=0 mce=ignore_ce transparent_hugepage=never default_hugepagesz=2M hugepages=4096 pcie_aspm=off mitigations=off
  ```

---

### 3. Parameter Breakdown Summary Matrix

| Category | Boot Parameter | Functional Goal / Low-Latency Rationale |
| :--- | :--- | :--- |
| **Core Shielding** | `isolcpus=domain,nohz,<trading_cores>` | Isolates trading cores from CFS load balancing and scheduler ticks without disrupting managed hardware queues. |
| **Core Shielding** | `nohz=on` | Enables generic dynamic tick subsystem infrastructure. |
| **Core Shielding** | `nohz_full=<trading_cores>` | Disables the 1000 Hz kernel scheduler tick on trading cores with 1 runnable task (adaptive tickless mode). |
| **Core Shielding** | `rcu_nocbs=<trading_cores>` | Offloads RCU garbage collection callbacks away from trading cores to housekeeping core(s). |
| **Core Shielding** | `rcupdate.rcu_normal_after_boot=1` | Accelerates boot via expedited grace periods, then restores non-disruptive normal RCU at runtime. |
| **Core Shielding** | `skew_tick=1` | Desynchronizes timer interrupts across CPU cores to prevent simultaneous memory bus stampedes. |
| **Kernel Preemption** | `preempt=full` | Forces full preemption across all non-atomic kernel execution paths, slashing timer dispatch latency tail. |
| **Hardware Determinism** | `nosmt` | Disables hyperthreading / SMT at the kernel entry point. |
| **Hardware Determinism** | `audit=0` | Strips kernel system call audit logging (~30ns saved per syscall). |
| **Hardware Determinism** | `mce=ignore_ce` | Prevents CPU execution stalls when hardware correctable memory/bus errors occur. |
| **Hardware Determinism** | `transparent_hugepage=never` | Prevents memory allocation freezing during runtime compaction. |
| **Memory Architecture** | `default_hugepagesz=2M` | Enforces 2MB hugepage default architecture (3-level page tables). |
| **Memory Architecture** | `hugepages=<count>` | Pre-allocates dynamic contiguous 2MB hugepage DRAM pool (512–4096 pages) at early boot. |
| **Hardware Determinism** | `pcie_aspm=off` | Forces all PCIe interconnects to stay locked in L0 active power mode. |
| **Hardware Determinism** | `mitigations=off` | Disables speculative execution barriers (Meltdown, Spectre, MDS, L1TF). |

---

### 4. Comprehensive Deep Dive: Every Kernel Boot Parameter Explained

Kernel boot parameters (passed via GRUB / systemd-boot to `/proc/cmdline`) configure the low-level behavior of the Linux kernel during early bootstrap. Below is an exhaustive breakdown of **all 15 kernel command-line parameters**, explaining what they do, why the Linux default behaves the way it does, and how our tuning achieves deterministic nanosecond performance.

---

#### Boot Parameter 1: `isolcpus=domain,nohz,<trading_cores>`
* **What it is:** Instructs the Linux Completely Fair Scheduler (CFS) to isolate the specified list of CPU cores (e.g., Cores `1-15` on a 16-core chip, `1-3` on a 4-core machine, or `2-31` on a 32-core workstation) from standard process load-balancing domains. Housekeeping cores (Core 0, or Cores 0–1 / 0–3 / 0–7) are intentionally left unisolated.
* **Untuned Config Value:** *(Not set / Empty)* — All cores participate in scheduler load balancing.
* **Tuned Config Value:** `isolcpus=domain,nohz,<trading_cores>` (e.g., `1-15`, `1-3`, `2-31`)
* **What Difference It Makes:** Standard Linux dynamically balances running processes across all cores. If an unpinned background process or cron job wakes up, the scheduler will happily place it on your trading core. `isolcpus` completely removes the isolated cores from the scheduler's automatic work queue. No process can execute on isolated cores unless explicitly pinned there via `taskset`, `numactl`, or `pthread_setaffinity_np()`.
* **Why It's Important for Market Data:** Guarantees that your market data parsers, order book builders, and execution gateways run with 100% exclusivity on physical silicon. No random background OS daemon can preempt your trading loop.

```text
┌─────────────────────────────────────────────────────────────────────────┐
│ CORE PARTITIONING: HOUSEKEEPING CORE vs ISOLATED TRADING CORES          │
├─────────────────────────────────────────────────────────────────────────┤
│ Housekeeping Core(s) (Core 0, or 0-1 / 0-3 / 0-7 - Unisolated):         │
│   Runs: Linux kernel workers, systemd, sshd, rsyslog, cron, disk I/O,   │
│         peripheral hardware IRQs, RCU garbage collection callbacks.     │
│                                                                         │
│ Trading Cores (e.g. Cores 1-15 or 1-3 - isolcpus):                      │
│   • Removed from CFS scheduler balancing domains                        │
│   • Zero background processes allowed to run here                       │
│   • Only your explicitly pinned trading threads run on these cores:     │
│     - Core 1: ITCH Multicast Feed Handler                               │
│     - Core 2: Level 2 / Level 3 Order Book Engine                       │
│     - Core 3: Quantitative Alpha Strategy Loop                          │
│     - Core 4: OUCH / FIX Order Execution Gateway                        │
└─────────────────────────────────────────────────────────────────────────┘
```

---

#### Boot Parameter 2: `nohz=on`
* **What it is:** Enables the generic dynamic tick subsystem infrastructure within the Linux kernel, paving the way for full tickless core isolation.
* **Untuned Config Value:** `nohz=on` (or distribution default)
* **Tuned Config Value:** `nohz=on`
* **What Difference It Makes:** Initializes kernel high-resolution timer (hrtimer) support required for adaptive tickless execution.
* **Why It's Important for Market Data:** Required baseline dependency for `nohz_full` to operate correctly.

---

#### Boot Parameter 3: `nohz_full=<trading_cores>`
* **What it is:** Adaptive Tickless Mode (Full dynticks). By default, the Linux kernel fires a hardware timer interrupt (the "scheduler tick") at 1000 Hz (1,000 times per second, or once every 1 millisecond) on EVERY core. `nohz_full` disables this 1000 Hz timer tick on isolated trading cores whenever there is only 1 runnable task on that core.
* **Untuned Config Value:** *(Not set)* — 1000 Hz timer tick fires continuously on every core.
* **Tuned Config Value:** `nohz_full=<trading_cores>` (e.g., `1-15`, `1-3`, `2-31`)
* **What Difference It Makes:** Eradicates 1,000 timer interrupts per second per core! When your trading thread is spinning in an active poll loop on an isolated core, the kernel completely stops scheduling timer ticks to that core. Execution becomes completely continuous.
* **Why It's Important for Market Data:** Every timer interrupt forces the CPU to pause your user-space market data loop, save CPU registers to the stack, switch to kernel mode, update process accounting statistics, and switch back. That takes **1 to 3 microseconds** 1,000 times a second! If a quote packet arrives during that 3 µs pause, you miss the market update.

```text
┌─────────────────────────────────────────────────────────────────────────┐
│ NOHZ_FULL: 1000 HZ SCHEDULER TICK vs TICKLESS TRADING CORE              │
├─────────────────────────────────────────────────────────────────────────┤
│ UNTUNED (Default 1000 Hz Scheduler Tick):                               │
│ Time:   0ms      1ms      2ms      3ms      4ms      5ms                │
│ Core 1: ─[TICK]───[TICK]───[TICK]───[TICK]───[TICK]───[TICK]───         │
│          ▲                                                              │
│          └── Every [TICK] is a 1-3 µs interrupt pause!                  │
│              60,000 interruptions every minute on your trading thread!  │
│                                                                         │
│ TUNED (nohz_full=<trading_cores> on isolated core with 1 task):         │
│ Time:   0ms      1ms      2ms      3ms      4ms      5ms                │
│ Core 1: ─────────────────────────────────────────────────────────────── │
│          ZERO timer interrupts! Pure continuous nanosecond execution.   │
└─────────────────────────────────────────────────────────────────────────┘
```

---

#### Boot Parameter 4: `rcu_nocbs=<trading_cores>`
* **What it is:** RCU (Read-Copy-Update) is a lockless synchronization mechanism used throughout the Linux kernel. When kernel data structures are freed, their memory deallocation is deferred into "RCU callbacks". By default, the core that triggered the RCU operation executes its own callbacks. `rcu_nocbs` offloads all RCU callback processing away from trading cores to housekeeping core(s).
* **Untuned Config Value:** *(Not set)* — Every core processes its own RCU garbage collection.
* **Tuned Config Value:** `rcu_nocbs=<trading_cores>` (e.g., `1-15`, `1-3`, `2-31`)
* **What Difference It Makes:** Prevents RCU callback "ksoftirqd" and "rcuc" worker threads from waking up on your trading cores. The trading cores remain completely free of kernel garbage collection overhead.
* **Why It's Important for Market Data:** RCU callbacks can accumulate and fire in bursts, stalling a trading core for **10 to 50 microseconds** while freeing memory buffers from other parts of the system. Offloading them guarantees the trading core never halts.

```text
┌──────────────────────────────────────────────────────────────────────────┐
│ RCU CALLBACK OFFLOADING: rcu_nocbs=<trading_cores>                       │
├──────────────────────────────────────────────────────────────────────────┤
│ UNTUNED (Default - RCU Callbacks run on local core):                     │
│   Core 1: [Trading Algo] ──>[RCU Garbage Collection Stall: 20µs]──>[Algo]│
│                              ▲ Stalls your market data processing!       │
│                                                                          │
│ TUNED (rcu_nocbs=<trading_cores> - Callbacks offloaded to HK core):      │
│   Core 1: [Trading Algo]───────────────────────────────────────>[Algo]   │
│           (100% uninterrupted uninterrupted order book processing)       │
│                                                                          │
│   Housekeeping: ──>[Processes All Deferred RCU Callbacks in Background]─ │
└──────────────────────────────────────────────────────────────────────────┘
```

---

#### Boot Parameter 5: `rcupdate.rcu_normal_after_boot=1`
* **What it is:** During early system boot, Linux uses "expedited" RCU grace periods to boot quickly, which generates heavy cross-core IPIs (Inter-Processor Interrupts). Setting this parameter instructs the kernel to immediately transition back to normal, gentle RCU behavior as soon as system initialization completes.
* **Untuned Config Value:** `0` (or dynamic)
* **Tuned Config Value:** `1`
* **What Difference It Makes:** Prevents expedited RCU grace periods from sending synchronous IPI interrupts to isolated trading cores at runtime.
* **Why It's Important for Market Data:** Eliminates cross-core interrupt storms that disrupt latency-critical execution loops.

---

#### Boot Parameter 6: `skew_tick=1`
* **What it is:** On multi-core systems, timer interrupts naturally tend to synchronize over time, causing all cores to execute timer handlers at the exact same instant. `skew_tick=1` intentionally offsets the timer tick phase across cores.
* **Untuned Config Value:** `0` (Synchronized ticks)
* **Tuned Config Value:** `1` (Desynchronized / Skewed ticks)
* **What Difference It Makes:** Prevents simultaneous memory bus collisions. If all cores hit memory at the exact same cycle, memory controller queues saturate.
* **Why It's Important for Market Data:** Ensures that housekeeping timer activity on Core 0 does not contend for DRAM bus channels at the exact moment your trading cores are reading market data packets from memory.

```text
┌─────────────────────────────────────────────────────────────────────────┐
│ SKEW_TICK: DESYNCHRONIZING MEMORY BUS STAMPEDES                         │
├─────────────────────────────────────────────────────────────────────────┤
│ SKEW_TICK=0 (Untuned: All cores hit bus simultaneously):                │
│   Core 0 Timer: ───[TICK]────────────────────────                       │
│   Core 1 Timer: ───[TICK]────────────────────────                       │
│   Core 2 Timer: ───[TICK]────────────────────────                       │
│   Memory Bus:   ═══[COLLISION / STAMPEDE]════════ <── Memory latency spike!
│                                                                         │
│ SKEW_TICK=1 (Tuned: Ticks are staggered in time):                       │
│   Core 0 Timer: ───[TICK]────────────────────────                       │
│   Core 1 Timer: ───────────[TICK]────────────────                       │
│   Core 2 Timer: ────────────────────[TICK]───────                       │
│   Memory Bus:   Smooth, distributed access with zero bus contention.    │
└─────────────────────────────────────────────────────────────────────────┘
```

---

#### Boot Parameter 7: `preempt=full`
* **What it is:** Sets the Linux kernel preemption model to `PREEMPT_DYNAMIC` Full Preemption. Standard enterprise Linux kernels run with `preempt=voluntary` or `preempt=none`, where the kernel cannot be interrupted while executing system calls on behalf of a process.
* **Untuned Config Value:** `preempt=voluntary` (or `preempt=none`)
* **Tuned Config Value:** `preempt=full`
* **What Difference It Makes:** Makes virtually all kernel code paths preemptible. If a high-priority trading thread needs CPU time while the kernel is performing a low-priority task, the kernel yields execution in **under 2 microseconds** instead of waiting for a voluntary scheduling point (which can take up to 150 µs).
* **Why It's Important for Market Data:** Slashing scheduler wake-up tail latency. When cyclictest measures real-time dispatch, `preempt=full` reduces the 99.99th percentile wake-up tail from **146 µs down to 11 µs**.

```text
┌─────────────────────────────────────────────────────────────────────────┐
│ KERNEL PREEMPTION: VOLUNTARY vs FULL PREEMPTION                         │
├─────────────────────────────────────────────────────────────────────────┤
│ VOLUNTARY PREEMPTION (Untuned Default):                                 │
│   Low-prio task in kernel syscall ─────────────────────────> [Yield]    │
│                         ▲                                        ▲      │
│                         │ Market Packet arrives!                 │      │
│                         └── High-priority trading task waits! ───┘      │
│                         Worst-case delay: 50 to 150 microseconds!       │
│                                                                         │
│ FULL PREEMPTION (Tuned: preempt=full):                                  │
│   Low-prio task in kernel syscall ───> [FORCED PREEMPTION]              │
│                         ▲                     │                         │
│                         │ Market arrives!     ▼                         │
│                         └── Trading task runs immediately! (<2 µs)      │
└─────────────────────────────────────────────────────────────────────────┘
```

---

#### Boot Parameter 8: `nosmt`
* **What it is:** Kernel-level directive to disable Simultaneous Multi-Threading (Hyper-Threading).
* **Untuned Config Value:** *(Not set)* — SMT enabled.
* **Tuned Config Value:** `nosmt`
* **What Difference It Makes:** Even if SMT is enabled in BIOS by accident, the kernel shuts down all sibling sibling threads during early boot, presenting only true physical cores to user space.
* **Why It's Important for Market Data:** Guarantees that every CPU core index (0, 1, 2...) represents a distinct physical silicon core with dedicated L1 cache and execution pipeline.

---

#### Boot Parameter 9: `audit=0`
* **What it is:** Disables the Linux kernel auditing subsystem (`kauditd`). In enterprise servers, the audit daemon logs security-relevant system calls (like `execve`, `socket`, `connect`).
* **Untuned Config Value:** `audit=1`
* **Tuned Config Value:** `audit=0`
* **What Difference It Makes:** Completely disables the audit hook from the kernel's system call entry and exit path, saving **20 to 40 nanoseconds** on every single system call.
* **Why It's Important for Market Data:** High-speed trading applications perform millions of socket and timer operations per second. Removing audit overhead speeds up every socket call across the board.

---

#### Boot Parameter 10: `mce=ignore_ce`
* **What it is:** Machine Check Exceptions (MCE) are hardware-level alerts reported by CPU hardware when correctable errors (CE) occur (such as single-bit ECC RAM errors). By default, the kernel halts the CPU core to record details in the system event log.
* **Untuned Config Value:** *(Not set)* — Logs correctable errors synchronously.
* **Tuned Config Value:** `mce=ignore_ce`
* **What Difference It Makes:** Tells the kernel to ignore correctable memory errors instead of triggering a synchronous execution stall. (Uncorrectable fatal errors still trigger a safe kernel panic).
* **Why It's Important for Market Data:** Prevents unexpected multi-millisecond CPU freezes during market trading hours if an ECC DIMM experiences a harmless, transparently corrected single-bit memory flip.

---

#### Boot Parameter 11: `transparent_hugepage=never`
* **What it is:** Disables the kernel's runtime Transparent Hugepage (THP) allocator during early bootstrap.
* **Untuned Config Value:** `transparent_hugepage=always` or `madvise`
* **Tuned Config Value:** `transparent_hugepage=never`
* **What Difference It Makes:** Prevents the kernel's background memory defragmentation thread (`khugepaged`) from running. When THP is active, the kernel periodically scans memory to coalesce 4KB pages into 2MB blocks, causing catastrophic 10–100ms allocation freezes.
* **Why It's Important for Market Data:** Eliminates unpredictable latency spikes during order book allocations. Low-latency systems use **static hugepages** (pre-allocated at boot) instead of dynamic THP.

---

#### Boot Parameter 12: `default_hugepagesz=2M`
* **What it is:** Sets the system's default hugepage architecture size to 2 Megabytes (2MB).
* **Untuned Config Value:** 4KB (standard page size)
* **Tuned Config Value:** `default_hugepagesz=2M`
* **What Difference It Makes:** Configures the default hugepage mount `/dev/hugepages` to use 2MB pages. 2MB hugepages use a 3-level page table instead of 4-level, fitting comfortably into CPU Translation Lookaside Buffers (TLBs).
* **Why It's Important for Market Data:** Standard 4KB pages require 4,096 page table entries for a 16MB order book. 2MB hugepages require only 8 entries! Those 8 entries reside permanently in L1 D-TLB, eliminating page table walk stalls.

---

#### Boot Parameter 13: `hugepages=<count>`
* **What it is:** Pre-allocates a dedicated contiguous pool of 2MB hugepages during early boot, dynamically scaled to the host system's total DRAM (e.g., 512 pages / 1GB for <16GB RAM; 1024 pages / 2GB for 16–31GB RAM; 2048 pages / 4GB for 32–127GB RAM; 4096 pages / 8GB for ≥128GB RAM), before the memory space becomes fragmented by the operating system.
* **Untuned Config Value:** `0` (no pre-allocated hugepages)
* **Tuned Config Value:** `hugepages=<count>` (e.g., `hugepages=2048` for 4GB pool on 32GB/64GB production systems, or `hugepages=512` on <16GB testbeds)
* **What Difference It Makes:** Guarantees that the dedicated physical DRAM pool is locked, unswappable, and physically contiguous. Your application can map these pages via `mmap(MAP_HUGETLB)` with 0% chance of allocation failure or fragmentation stalls.
* **Why It's Important for Market Data:** Used for pre-allocating the primary memory pool: AF_XDP packet UMEM rings, L2/L3 order book depth queues, and lock-free SPSC circular ring buffers.

---

#### Boot Parameter 14: `pcie_aspm=off`
* **What it is:** Kernel-level command to force the PCIe subsystem to ignore Active State Power Management (ASPM) requests from devices.
* **Untuned Config Value:** `pcie_aspm=default` (allows driver power savings)
* **Tuned Config Value:** `pcie_aspm=off`
* **What Difference It Makes:** Overrides device drivers that attempt to put PCIe links into low-power states (L0s/L1). Guarantees PCIe interconnects stay locked in L0 active mode.
* **Why It's Important for Market Data:** Prevents PCIe link wake-up delays (5–30 µs) on trading network cards during quiet market intervals.

---

#### Boot Parameter 15: `mitigations=off`
* **What it is:** Disables all CPU hardware vulnerability software mitigations (Meltdown, Spectre v1/v2, MDS, L1TF, Retpoline, Speculative Store Bypass).
* **Untuned Config Value:** `mitigations=auto` (All software barriers active)
* **Tuned Config Value:** `mitigations=off`
* **What Difference It Makes:** Strips indirect branch predictors, retpolines, and memory barrier fences (`lfence`, IBRS, IBPB) from every system call and context switch. Restores **15% to 30% raw CPU throughput** and cuts syscall overhead by **30–50 nanoseconds**.
* **Why It's Important for Market Data:** Electronic trading servers operate on private, dedicated colocation networks where untrusted multi-tenant code is never executed. Bearing the massive latency penalty of speculative execution fences is counterproductive; disabling them restores the silicon's native bare-metal execution speed.

```text
┌─────────────────────────────────────────────────────────────────────────┐
│ CPU SPECULATIVE EXECUTION BARRIERS: MITIGATIONS=AUTO vs OFF             │
├─────────────────────────────────────────────────────────────────────────┤
│ MITIGATIONS=AUTO (Untuned Default):                                     │
│   Every system call, context switch, and indirect function call issues: │
│   - Retpoline thunks                                                    │
│   - Indirect Branch Prediction Barriers (IBPB)                          │
│   - CPU pipeline serialization fences                                   │
│   Performance Cost: +30 to 50 nanoseconds added to every system call!   │
│                                                                         │
│ MITIGATIONS=OFF (Tuned for Dedicated Production Trading Servers):       │
│   • All software speculative barriers DISABLED                          │
│   • Branch predictors execute at full silicon wire speed                │
│   • Minimal syscall latency drops from ~90ns to ~60ns!                  │
└─────────────────────────────────────────────────────────────────────────┘
```

---

### 3. ⚠️ Post-Mortem: Dangerous Parameters to AVOID on Production Bare-Metal

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

## ⚡ Runtime Kernel & OS Tunings

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
| **10**| **IRQ Shielding & Core Pinning** | `systemctl stop irqbalance`<br>`default_smp_affinity = <hk_mask>` | Shields trading cores by routing all peripheral IRQs to housekeeping core(s) |
| **11**| **Static 2MB Hugepages** | `sysctl vm.nr_hugepages = <count>`<br>`mount -t hugetlbfs nodev /dev/hugepages` | Pre-allocates dynamic DRAM pool (512–4096 pages); 3-level page tables; 0 TLB stalls |
| **12**| **POSIX Real-Time & Memlock Limits** | `/etc/security/limits.d/99-hft.conf`<br>`systemd DefaultLimitMEMLOCK=infinity` | Enables `mlockall` & `SCHED_FIFO` 99 for trading daemons |
| **13**| **PCIe Network MaxReadReq (4096B)** | `setpci -s <bdf> CAP_EXP+8.w=5000:7000`<br>`echo full > /sys/kernel/debug/sched/preempt` | Maximizes PCIe DMA burst efficiency; forces full kernel preemption |

> [!NOTE]
> **\*Note on Automatic NUMA Balancing:** On enterprise multi-NUMA server platforms, disabling NUMA balancing stops background thread page migration stalls across sockets. On high-frequency single-NUMA AMD Ryzen architectures, this is not strictly required as memory access is already uniform (UMA), though retaining the setting remains recommended practice to eliminate background kernel scanning threads.

### Comprehensive Deep Dive: Every Runtime Tuning Explained

The 13 runtime configurations applied by [`hft_tuning.sh`](hft_tuning.sh) take effect immediately without requiring a system reboot. Below is an exhaustive breakdown of **every single runtime tuning**, explaining what it does, the standard untuned Linux behavior, the tuned value, and why it is indispensable for market data ingestion and order execution.

---

#### Tuning 1: CPU Scaling Governor (`performance`) & Min Frequency Pinning
* **What it is:** The Linux `cpufreq` subsystem manages CPU clock speeds using software governors. By default, Linux runs the `powersave` or `schedutil` governor, which constantly monitors CPU utilization and dynamically shifts clock frequencies between energy-efficient low frequencies and peak boost clocks.
* **Untuned Config Value:** `governor = powersave` (or `schedutil`), `scaling_min_freq = 400 MHz` to `2.2 GHz`
* **Tuned Config Value:** `cpupower frequency-set -g performance`, `scaling_min_freq = scaling_max_freq`
* **What Difference It Makes:** Under `powersave`, when market activity is quiet, the core drops down to 2.2 GHz. When an exchange quote burst arrives, the governor takes **10 to 50 milliseconds** to detect the spike and ramp up the clock multipliers. Locking the governor to `performance` and clamping the minimum frequency to the maximum frequency ensures the CPU is permanently running at maximum clock speed with **0ns ramp-up latency**.
* **Why It's Important for Market Data:** Market data quotes arrive in sudden, unpredictable microsecond bursts. If the CPU core is running at low frequency when the burst hits, your parser takes twice as long to process each packet, causing packets to queue up in NIC memory buffers and creating severe processing lag.

```text
┌─────────────────────────────────────────────────────────────────────────┐
│ CPU FREQUENCY GOVERNORS: IDLE RAMP DELAY vs FIXED PERFORMANCE           │
├─────────────────────────────────────────────────────────────────────────┤
│ POWERSAVE / SCHEDUTIL GOVERNOR (Untuned Default):                       │
│ Freq: 5.7 GHz ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─╱─────────── │
│       4.0 GHz ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ╱              │
│       2.2 GHz ─────────────────────────────────────────╱  10-50ms ramp! │
│               └───────────────────────┬────────────────┘                │
│                                       │ Burst arrives                   │
│                                       │ (Core throttled at low freq!)   │
│                                                                         │
│ PERFORMANCE GOVERNOR (Tuned: min_freq = max_freq):                      │
│ Freq: 5.7 GHz ═════════════════════════════════════════════════════════ │
│               Core is ALWAYS at peak frequency. 0ns ramp latency!       │
└─────────────────────────────────────────────────────────────────────────┘
```

---

#### Tuning 2: PM QoS C-State Elimination (`/dev/cpu_dma_latency = 0`)
* **What it is:** Linux Power Management Quality of Service (PM QoS) allows processes to register system performance requirements with the kernel. Opening the character device `/dev/cpu_dma_latency` and writing a 32-bit integer of `0` tells the CPU power management driver that the system can tolerate **zero microseconds** of exit latency from sleep states.
* **Untuned Config Value:** Not requested; CPU cores enter C1E, C3, C6 sleep states freely.
* **Tuned Config Value:** Open `/dev/cpu_dma_latency`, write `int32_t = 0`, hold open indefinitely via systemd service `hft-dma-latency.service`.
* **What Difference It Makes:** Even when the CPU has no immediate work, PM QoS forbids the hardware from entering any idle state deeper than active C0 polling. It cuts core wake-up latency from **50–150 microseconds to exactly 0 nanoseconds**.
* **Why It's Important for Market Data:** When cyclictest measures timer wake-up latency, C-state sleep is the single largest contributor to latency spikes. In our live benchmark runs on `cherry`, eliminating C-states slashed peak wake-up latency tail from **146,771 ns down to 11,396 ns (a 92.2% reduction!)**.

```text
┌─────────────────────────────────────────────────────────────────────────┐
│ PM QOS C-STATE LOCK (/dev/cpu_dma_latency = 0)                          │
├─────────────────────────────────────────────────────────────────────────┤
│ UNTUNED (No PM QoS Lock):                                               │
│ Quiet millisecond between orders ──> Core drops into C6 sleep           │
│ Market order arrives on wire ──> Core takes 150 µs to power on and wake │
│ Result: Massive 150 µs latency spike on the first packet of every burst!│
│                                                                         │
│ TUNED (PM QoS Locked to 0 µs):                                          │
│ Quiet millisecond between orders ──> Core spins actively in C0          │
│ Market order arrives on wire ──> Instant processing in 0 nanoseconds!   │
└─────────────────────────────────────────────────────────────────────────┘
```

---

#### Tuning 3: CFS Task Migration Cost (`sched_migration_cost_ns = 5000000`)
* **What it is:** Instructs the Completely Fair Scheduler (CFS) on how long a task should be considered "cache hot" after it stops running on a core. The default kernel setting is 500,000 nanoseconds (0.5 ms).
* **Untuned Config Value:** `500000` (0.5 milliseconds)
* **Tuned Config Value:** `5000000` (5.0 milliseconds)
* **What Difference It Makes:** Increases the migration penalty threshold by 10x. The kernel scheduler will refuse to migrate your running trading thread to a different core unless the target core has been idle for at least 5ms.
* **Why It's Important for Market Data:** When an execution thread migrates between cores, it loses all its hot Level 1 and Level 2 CPU caches. A 16MB order book and symbol lookup table must be completely re-fetched from Level 3 cache or main DRAM, costing **10 to 50 microseconds** of degraded throughput. High migration cost enforces strict cache affinity.

```text
┌─────────────────────────────────────────────────────────────────────────┐
│ CFS TASK MIGRATION: CACHE DESTRUCTION vs CACHE RETENTION                │
├─────────────────────────────────────────────────────────────────────────┤
│ DEFAULT (migration_cost_ns = 500000):                                   │
│ Core 1 (Your Algo): Hot L1/L2 caches (Order books, symbol index)        │
│ Core 5 becomes idle ──> CFS steals thread from Core 1 to Core 5!        │
│ Result: Core 5 has COLD caches. Order book must reload from RAM (50µs)! │
│                                                                         │
│ TUNED (migration_cost_ns = 5000000):                                    │
│ CFS sees the thread is cache-hot and refuses to move it.                │
│ Result: Your thread stays on Core 1; L1/L2 caches remain hot!           │
└─────────────────────────────────────────────────────────────────────────┘
```

---

#### Tuning 4: Automatic NUMA Balancing (`kernel.numa_balancing = 0`)*
* **What it is:** In multi-socket or multi-die enterprise servers (e.g. AMD EPYC, Intel Xeon, Threadripper PRO), the kernel's automatic NUMA balancer periodically runs a background thread (`task_numa_work`). This thread intentionally invalidates page table entries to force minor page faults, tracking which CPU core touches the memory so it can migrate the physical pages across sockets.
* **Untuned Config Value:** `1` (Enabled)
* **Tuned Config Value:** `0` (Disabled)
* **What Difference It Makes:** Stops the background page scanner completely. Disabling it prevents random minor page fault interruptions and cross-socket page copying stalls.
* **Why It's Important for Market Data:** Minor page faults induced by NUMA balancing freeze application threads for **5 to 50 microseconds**. In an HFT application, you explicitly bind your threads and memory buffers to the specific NUMA node adjacent to the trading NIC using `numactl` or `pthread_setaffinity_np()`. You never want the OS moving memory behind your back.
* *\*Note: On single-socket AMD Ryzen desktop architectures (which operate as a single uniform memory domain), this setting is not strictly necessary for memory locality, but remains essential practice to eliminate the background scanning thread.*

---

#### Tuning 5: Virtual Memory Swappiness & Emergency Reserve
* **What it is:** 
  1. `vm.swappiness`: Controls how aggressively the kernel swaps application memory pages from physical RAM to swap disk space when caching filesystem data.
  2. `vm.min_free_kbytes`: Sets the minimum amount of physical memory that the kernel keeps free at all times as an emergency pool for non-blocking atomic allocations (like network interrupt packet reception).
* **Untuned Config Value:** `vm.swappiness = 60`, `vm.min_free_kbytes = ~67584` (64 MB)
* **Tuned Config Value:** `vm.swappiness = 0`, `vm.min_free_kbytes = 1048576` (1 Gigabyte emergency reserve)
* **What Difference It Makes:**
  - `swappiness=0` strictly prevents the kernel from swapping trading application heap, stack, or order books out to SSD/disk.
  - `min_free_kbytes=1GB` guarantees that the kernel always has a 1GB contiguous physical pool. The kernel will **never enter "direct reclaim"** (a synchronous stall where the kernel freezes running applications while it desperately searches for free RAM pages).
* **Why It's Important for Market Data:** Direct memory reclaim is one of the most vicious causes of multi-millisecond tail latency spikes. When sudden gigabit multicast packet storms hit the network card, standard Linux exhausts its tiny 64MB emergency pool and freezes for 10–50ms to reclaim pages, dropping thousands of packets. Reserving 1GB prevents this completely.

```text
┌─────────────────────────────────────────────────────────────────────────┐
│ DIRECT RECLAIM FREEZES vs 1GB EMERGENCY MEMORY RESERVE                  │
├─────────────────────────────────────────────────────────────────────────┤
│ UNTUNED (min_free_kbytes = 64MB):                                       │
│ Massive market burst arrives ──> 100,000 UDP packets arrive in 10ms     │
│ 64MB buffer exhausted! ──> Kernel enters [ DIRECT RECLAIM ]             │
│   └── Kernel FREEZES your trading process for 10-50 milliseconds!       │
│   └── Thousands of market data packets are dropped on the wire!         │
│                                                                         │
│ TUNED (min_free_kbytes = 1GB reserve):                                  │
│ Massive market burst arrives ──> Packets allocated from 1GB reserve     │
│ Zero direct reclaim. Zero pauses. Zero dropped packets!                 │
└─────────────────────────────────────────────────────────────────────────┘
```

---

#### Tuning 6: VM Stat Timer Interruption Suppression (`vm.stat_interval = 120`)
* **What it is:** The Linux virtual memory subsystem collects system-wide memory usage statistics (like page counts, active/inactive lists) by running `vmstat_update()` via a per-CPU kernel timer tick.
* **Untuned Config Value:** `1` (Every 1 second)
* **Tuned Config Value:** `120` (Every 2 minutes)
* **What Difference It Makes:** Extends the statistics timer interval by 120x. Slashes periodic vmstat timer interruptions by **99.2%**.
* **Why It's Important for Market Data:** Out of the box, standard Linux interrupts every single core once every second just to update accounting stats in `/proc/meminfo`. That's 60 interruptions per minute! Changing the interval to 120 seconds reduces the interruptions from 60 per minute down to 0.5 per minute.

---

#### Tuning 7: Transparent Hugepages Hard-Disable (`transparent_hugepage = never`)
* **What it is:** Transparent Huge Pages (THP) is an automatic operating system feature that attempts to scan memory in the background via the `khugepaged` daemon and collapse contiguous 4KB pages into 2MB hugepages on the fly.
* **Untuned Config Value:** `always` or `madvise`
* **Tuned Config Value:** `never` (in both `enabled` and `defrag`)
* **What Difference It Makes:** Stops `khugepaged` completely. When memory becomes fragmented, THP triggers synchronous page compaction during memory allocation, causing execution stalls of **10 to 100 milliseconds**.
* **Why It's Important for Market Data:** Never rely on the operating system to dynamically create hugepages at runtime. HFT architectures pre-allocate **static hugepages** at boot time (via hugetlbfs), guaranteeing unfragmented 2MB physical pages without risking dynamic compaction stalls.

---

#### Tuning 8: Socket Low-Latency Busy-Polling, Ring & Qdisc
* **What it is:** 
  1. `net.core.busy_poll` & `busy_read`: Instructs the Linux socket layer to actively spin-poll the network device driver queue for incoming packets for up to $N$ microseconds before sleeping and waiting for a hardware interrupt.
  2. `net.core.default_qdisc`: Sets the root queuing discipline for network transmission. Standard Linux uses `fq_codel` (Fair Queueing with Controlled Delay), which adds complex hashing, timestamping, and queue sojourn management. We replace it with `pfifo_fast`, a lockless, ultra-fast First-In-First-Out queue.
  3. `ethtool -G rx 1024/4096`: Expands the physical hardware descriptor rings on the network card to absorb packet bursts.
* **Untuned Config Value:** `busy_poll = 0` (Interrupt-driven), `qdisc = fq_codel`, `rx ring = 256/512`
* **Tuned Config Value:** `busy_poll = 50`, `busy_read = 50`, `default_qdisc = pfifo_fast`, `rx ring = 1024` (or `4096` on 100GbE)
* **What Difference It Makes:**
  - Socket reads become active polling loops: when a packet arrives, your application reads it in **nanoseconds**, avoiding the 3–8 µs interrupt dispatch delay.
  - `pfifo_fast` eliminates **300–800 nanoseconds** of transmission packet scheduling overhead.
  - Expanded ring buffers prevent packet drops during microbursts.
* **Why It's Important for Market Data:** When processing live exchange feeds, busy-polling eliminates the sleep-and-wake cycle of socket `recv()`, ensuring you react to price updates immediately.

```text
┌─────────────────────────────────────────────────────────────────────────┐
│ SOCKET BUSY-POLLING vs INTERRUPT-DRIVEN RECEPTION                       │
├─────────────────────────────────────────────────────────────────────────┤
│ INTERRUPT-DRIVEN (Untuned: busy_poll = 0):                              │
│ App calls recv() ──> No packet yet ──> Thread goes to sleep             │
│ Packet arrives at NIC ──> NIC raises electrical IRQ ──> CPU halts       │
│ CPU runs kernel ISR ──> Wakes up app thread ──> App reads packet        │
│ Total Delay: 3,000 to 8,000 nanoseconds!                                │
│                                                                         │
│ BUSY-POLLING (Tuned: busy_poll = 50us):                                 │
│ App calls recv() ──> CPU actively spins polling the NIC ring            │
│ Packet arrives at NIC ──> Read IMMEDIATELY from memory!                 │
│ Total Delay: Sub-microsecond!                                           │
└─────────────────────────────────────────────────────────────────────────┘
```

---

#### Tuning 9: TCP Serialization & Metrics (Autocorking & Idle Reset)
* **What it is:**
  1. `tcp_autocorking = 0`: Disables Linux TCP packet coalescing. By default, Linux holds back small TCP packets hoping that the application will quickly write more data, merging them into a single packet to maximize bandwidth efficiency.
  2. `tcp_slow_start_after_idle = 0`: Disables TCP congestion window reset after idle periods.
  3. `tcp_no_metrics_save = 1`: Prevents the kernel from saving TCP route metrics in cache after a connection closes.
  4. `tcp_moderate_rcvbuf = 0`: Disables automatic receive buffer modulation, maintaining fixed buffer sizes.
* **Untuned Config Value:** `tcp_autocorking = 1`, `tcp_slow_start_after_idle = 1`, `tcp_no_metrics_save = 0`
* **Tuned Config Value:** `tcp_autocorking = 0`, `tcp_slow_start_after_idle = 0`, `tcp_no_metrics_save = 1`, `tcp_moderate_rcvbuf = 0`
* **What Difference It Makes:** Forces **immediate packet serialization**. The instant your trading logic issues a `send()` call for a 64-byte order execution message (OUCH, FIX), the kernel pushes it directly to the NIC transmit FIFO without holding it back.
* **Why It's Important for Market Data & Order Gateways:** Autocorking is disastrous for trading: it can delay an outbound order execution by up to **1 millisecond** while waiting for more data. Setting `tcp_autocorking=0` ensures your order hits the wire instantly.

```text
┌─────────────────────────────────────────────────────────────────────────┐
│ TCP AUTOCORKING: PACKET DELAY vs IMMEDIATE WIRE TRANSMISSION            │
├─────────────────────────────────────────────────────────────────────────┤
│ AUTOCORKING ENABLED (Untuned Default - Optimized for bulk throughput): │
│ Time 0µs:   Order 1 (64 bytes) submitted ──> [Socket Buffer: HELD]      │
│ Time 200µs: Kernel waits for more bytes...                              │
│ Time 1000µs: Kernel flushes buffer to wire ──> [1 MILLISECOND DELAY!]   │
│                                                                         │
│ AUTOCORKING DISABLED (Tuned: tcp_autocorking = 0):                      │
│ Time 0µs:   Order 1 (64 bytes) submitted ──> [NIC Transmit Wire: NOW!]  │
│ Order reaches exchange matching engine in sub-microsecond time!         │
└─────────────────────────────────────────────────────────────────────────┘
```

---

#### Tuning 10: IRQ Shielding & Core Pinning (`irqbalance` Masked)
* **What it is:** Stops and masks the `irqbalance` daemon, and writes the dynamic housekeeping CPU mask (`$HW_HOUSEKEEPING_MASK_HEX`) to `/proc/irq/default_smp_affinity` and all active `/proc/irq/*/smp_affinity` descriptors.
  - **≤ 16 Physical Cores** (Desktop / Dual-CCD Ryzen): Mask `0x1` (Core 0)
  - **24 – 32 Physical Cores** (Threadripper 7960X/7970X): Mask `0x3` (Cores 0–1)
  - **48 – 64 Physical Cores** (Threadripper 7980X, EPYC 9554): Mask `0xf` (Cores 0–3)
  - **> 64 Physical Cores** (96c 7995WX, 128c EPYC 9754): Mask `0xff` (Cores 0–7)
* **Untuned Config Value:** `irqbalance` running; interrupts dynamically distributed across all CPU cores.
* **Tuned Config Value:** `irqbalance` masked and stopped; all peripheral hardware IRQs pinned to Housekeeping Cores (`HW_HOUSEKEEPING_MASK_HEX`).
* **What Difference It Makes:** Shields trading cores from all peripheral hardware interrupts (storage NVMe interrupts, USB controllers, network management interrupts). Housekeeping cores absorb all system interrupts, while trading cores run 100% uninterrupted. Furthermore, scaling the housekeeping mask across high core counts prevents IRQ vector saturation on single cores. When reverting tunings, the suite dynamically generates `HW_ALL_CORES_MASK` (e.g. `f` for 4c, `ffff` for 16c, `ffffffff` for 32c) to cleanly restore IRQ distribution across the entire CPU socket.
* **Why It's Important for Market Data:** In our baseline test before tuning on server `cherry`, dynamic IRQ distribution caused **923 execution pauses greater than 1µs**, with peak pauses reaching **1.2 milliseconds** when storage and network interrupts hit the measured core. Pinning IRQs reduced jitter pauses from **923 events down to 1 event (a 99.89% reduction!)** and eliminated the 1.2ms pause entirely!

```text
┌─────────────────────────────────────────────────────────────────────────┐
│ IRQ SHIELDING: DISTRIBUTED JITTER vs DYNAMIC HOUSEKEEPING SHIELD        │
├─────────────────────────────────────────────────────────────────────────┤
│ UNTUNED (irqbalance Active):                                            │
│ Core 0: ──[IRQ]──────────────[IRQ]──────────────[IRQ]──                 │
│ Core 1 (Your Algo): ────[IRQ]──────[IRQ]─────────────── <── INTERRUPTED!│
│ Every interrupt adds 1 to 5 µs of pause and trashes your L1 cache!      │
│                                                                         │
│ TUNED (irqbalance Masked, all IRQs pinned to Housekeeping Cores):       │
│ HK Cores (e.g. Core 0 or 0-3): ─[IRQ][IRQ][IRQ][IRQ][IRQ][IRQ]─         │
│ Trading Cores (Isolated):      ──────────────────────── <── ZERO IRQs!  │
│ 100% clean, uninterrupted execution!                                    │
└─────────────────────────────────────────────────────────────────────────┘
```

---

#### Tuning 11: Pre-allocating Static 2MB Hugepages (hugetlbfs)
* **What it is:** Allocates a dedicated pool of static 2MB memory blocks scaled dynamically to system physical memory, and mounts a dedicated `hugetlbfs` filesystem at `/dev/hugepages`:
  - **< 16 GB DRAM**: 512 pages (1 GB static pool)
  - **16 GB – 31 GB DRAM**: 1,024 pages (2 GB static pool)
  - **32 GB – 127 GB DRAM**: 2,048 pages (4 GB static pool)
  - **≥ 128 GB DRAM**: 4,096 pages (8 GB static pool)
* **Untuned Config Value:** `0` hugepages allocated; applications use standard 4KB paging.
* **Tuned Config Value:** `vm.nr_hugepages = <HW_HUGEPAGES_COUNT>`, mounted at `/dev/hugepages`
* **What Difference It Makes:** Standard 4KB paging requires a 4-level page table walk in hardware whenever a Translation Lookaside Buffer (TLB) miss occurs, costing **~400 nanoseconds**. 2MB hugepages reduce page table depth to 3 levels, and a 16MB buffer requires only 8 page table entries instead of 4,096. Dynamic scaling ensures memory-constrained VMs do not crash or OOM during build phases, while enterprise servers with 128GB+ RAM receive ample pool space for large order book depths and dual-port 10GbE/25GbE AF_XDP rings.
* **Why It's Important for Market Data:** Large order books, symbol tables, and AF_XDP UMEM packet rings mapped in 2MB hugepages fit entirely within the CPU's hardware L1 D-TLB, completely eliminating hardware page table walk stalls.

---

#### Tuning 12: POSIX Real-Time & Memlock Limits (`/etc/security/limits.d/99-hft.conf`)
* **What it is:** Sets user-space system resource limits for the trading user account:
  - `memlock unlimited`: Maximum locked-in-memory address space.
  - `rtprio 99`: Maximum real-time scheduling priority under `SCHED_FIFO` / `SCHED_RR`.
  - `nofile 1048576`: Maximum open file descriptor limit.
* **Untuned Config Value:** `memlock = 64 KB`, `rtprio = 0` (unprivileged), `nofile = 1024`
* **Tuned Config Value:** `memlock = unlimited`, `rtprio = 99`, `nofile = 1048576`
* **What Difference It Makes:** Standard Linux forbids regular users from locking memory or acquiring real-time scheduler priority. This configuration enables your trading application to call `mlockall(MCL_CURRENT | MCL_FUTURE)` to lock its entire address space into RAM, and to acquire `sched_setscheduler(SCHED_FIFO, 99)` for real-time kernel scheduling.
* **Why It's Important for Market Data:** Prevents operating system permission errors (`EPERM`) when allocating large hugepage ring buffers or setting real-time thread priorities.

---

#### Tuning 13: PCIe High-Performance Bus & Read Request Optimization
* **What it is:** 
  1. `setpci -s <bdf> CAP_EXP+8.w=5000:7000`: Programs the PCI Express Maximum Read Request Size (MRRS) register on physical network controllers to 4,096 bytes (4KB).
  2. `echo full > /sys/kernel/debug/sched/preempt`: Enforces full kernel preemption across all runtime scheduler domains.
* **Untuned Config Value:** `MRRS = 512 bytes`, `sched/preempt = voluntary`
* **Tuned Config Value:** `MRRS = 4096 bytes`, `sched/preempt = full`
* **What Difference It Makes:**
  - Standard MRRS of 512 bytes forces the network card DMA engine to fragment memory reads into multiple small Transaction Layer Packets (TLPs). Setting MRRS to 4096 bytes allows the NIC to burst-read memory across the PCIe bus in a single high-efficiency transaction.
  - Runtime preemption reduces kernel dispatch latency tails to sub-microsecond levels.
* **Why It's Important for Market Data:** Maximizes PCIe Transaction Layer throughput between physical 10GbE/100GbE network cards (like Intel E810 / X520) and host memory, accelerating outbound order dispatch and inbound packet DMA.

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

### 🌐 Advanced Network Stack & Socket Buffer Deep Dive

When ingesting high-volume financial market data feeds (such as NASDAQ TotalView-ITCH, CME MDP 3.0, OPRA, or Eurex EMDI over UDP Multicast) or transmitting orders via binary protocols (NASDAQ OUCH, CME iLink 3, FIX), the operating system network stack is the frontline of defense against packet loss and latency jitter.

Below is an exhaustive breakdown of **every network parameter and physical NIC tuning** configured by this suite:

---

#### Network Config 1: Maximum Socket Receive & Send Buffers (`rmem_max` & `wmem_max`)
* **What it is:** Sets the upper ceiling (in bytes) for socket receive and send buffers that an application can request via `setsockopt(SO_RCVBUF)` and `setsockopt(SO_SNDBUF)`.
* **Untuned Config Value:** `net.core.rmem_max = 212992` (208 KB), `net.core.wmem_max = 212992` (208 KB)
* **Tuned Config Value:** `net.core.rmem_max = 134217728` (128 MB), `net.core.wmem_max = 134217728` (128 MB)
* **What Difference It Makes:** Increases socket buffer capacity by **615x**. An untuned 208 KB buffer can hold only ~140 MTU packets (1500 bytes each). A 128 MB buffer holds up to **85,000 packets**.
* **Why It's Important for Market Data:** During high-volatility events (e.g. market open or Fed interest rate decisions), exchange multicast feeds can burst at **10 Gigabits per second (over 800,000 packets per second)**. A 208 KB buffer fills up in **150 microseconds**! Once full, Linux drops incoming packets silently (`UDP buffer errors`), leading to missing trade updates and requiring slow TCP snapshot recovery. A 128 MB buffer absorbs massive market bursts effortlessly.

```text
┌─────────────────────────────────────────────────────────────────────────┐
│ UDP MARKET DATA BURST: BUFFER CAPACITY vs PACKET DROPS                  │
├─────────────────────────────────────────────────────────────────────────┤
│ UNTUNED DEFAULT (rmem_max = 208 KB):                                    │
│   Market Open Quote Burst: 100,000 UDP packets arrive in 100ms          │
│   [ 208 KB Socket Buffer ] ──> FULL in 150 µs!                          │
│   Remaining 98,000 packets ──> [ DROPPED ON THE FLOOR! ]                │
│   Result: Corrupted order book! Exchange sequence gap! Recovery storm!  │
│                                                                         │
│ TUNED (rmem_max = 128 MB):                                              │
│   Market Open Quote Burst: 100,000 UDP packets arrive in 100ms          │
│   [ 128 MB Socket Buffer ] ──> Holds all 100,000 packets easily!        │
│   Zero packet drops. Zero gap recovery. 100% data integrity!            │
└─────────────────────────────────────────────────────────────────────────┘
```

---

#### Network Config 2: Guaranteed Minimum UDP Buffer Allocation (`udp_rmem_min` & `udp_wmem_min`)
* **What it is:** Defines the minimum memory size (in bytes) guaranteed to a UDP socket, even under severe operating system memory pressure.
* **Untuned Config Value:** `net.ipv4.udp_rmem_min = 4096` (4 KB), `net.ipv4.udp_wmem_min = 4096` (4 KB)
* **Tuned Config Value:** `net.ipv4.udp_rmem_min = 16384` (16 KB), `net.ipv4.udp_wmem_min = 16384` (16 KB)
* **What Difference It Makes:** Increases guaranteed baseline UDP buffer pages by 4x, protecting UDP sockets from being starved by kernel memory reclaim.
* **Why It's Important for Market Data:** UDP multicast is connectionless and has no retransmission or flow control. If the kernel throttles socket buffers due to transient memory pressure, packets are permanently lost.

---

#### Network Config 3: Kernel Input Device Backlog Queue (`netdev_max_backlog`)
* **What it is:** The maximum number of incoming network packets queued in the kernel's per-CPU backlog list after being pulled from the network card ring buffer by the driver's NAPI poll loop, before being processed by the protocol stack.
* **Untuned Config Value:** `1000` packets
* **Tuned Config Value:** `250000` packets
* **What Difference It Makes:** Expands the kernel backlog queue capacity by **250x**.
* **Why It's Important for Market Data:** On 10GbE and 100GbE physical links, a burst of 1,000 packets arrives in less than **1 microsecond**. If the CPU is momentarily servicing an interrupt, an untuned queue of 1,000 packets overflows instantly, causing drops at the network interface layer before packets even reach socket buffers.

---

#### Network Config 4: Root Packet Queuing Discipline (`pfifo_fast` vs `fq_codel`)
* **What it is:** The Linux Traffic Control (TC) queuing discipline (qdisc) governs how packets are scheduled for transmission onto the physical network card. Modern Linux distributions default to `fq_codel` (Fair Queueing with Controlled Delay), which aims to prevent "bufferbloat" for general internet traffic.
* **Untuned Config Value:** `net.core.default_qdisc = fq_codel`
* **Tuned Config Value:** `net.core.default_qdisc = pfifo_fast`
* **What Difference It Makes:** Replaces a complex, compute-intensive queueing algorithm with a simple, lockless 3-band FIFO (First-In-First-Out) queue.
* **Why It's Important for Order Gateways:** `fq_codel` actively inspects packet headers, computes flow hashes, tracks per-flow sojourn times, and introduces artificial delays or packet drops to regulate flow throughput. For an ultra-low-latency order execution gateway, this computation adds **300 to 800 nanoseconds** of jitter to every outbound order execution packet! `pfifo_fast` immediately pushes outbound orders directly to the NIC transmit ring without inspection.

```text
┌─────────────────────────────────────────────────────────────────────────┐
│ TRANSMIT QDISC: fq_codel (Complex) vs pfifo_fast (Zero Overhead)         │
├─────────────────────────────────────────────────────────────────────────┤
│ fq_codel (Untuned Default - General Internet Bufferbloat Prevention):   │
│   Outbound Order ──> [ Hash Flow ID ] ──> [ Calculate Sojourn Time ]    │
│                  ──> [ Fair Queue Classification ] ──> [ NIC Transmit ] │
│   Latency Overhead: +300 to 800 nanoseconds per order!                  │
│                                                                         │
│ pfifo_fast (Tuned - Lockless FIFO):                                     │
│   Outbound Order ──> [ Direct Lockless FIFO ] ──> [ NIC Transmit ]      │
│   Latency Overhead: ZERO nanoseconds scheduling delay!                  │
└─────────────────────────────────────────────────────────────────────────┘
```

---

#### Network Config 5: Physical Hardware Descriptor Rings (`ethtool -G rx 4096 tx 4096`)
* **What it is:** Configures the number of DMA ring buffer descriptors allocated directly inside the network controller's hardware registers.
* **Untuned Config Value:** `rx 256` or `512` descriptors, `tx 256` or `512` descriptors
* **Tuned Config Value:** `rx 1024` (or `4096` on high-speed 25G/100G Intel/Mellanox NICs), `tx 1024` / `4096`
* **What Difference It Makes:** Multiplies hardware queue capacity by 4x to 8x.
* **Why It's Important for Market Data:** When an ITCH multicast packet wave hits the physical SFP+ optical transceiver, the packets are written into the hardware descriptor ring via PCIe DMA. If the descriptor ring is small (e.g. 256 descriptors), any microsecond stall in the CPU polling loop causes the hardware ring to fill and drop packets directly on the wire (`rx_discards_phy` or `rx_missed_errors`).

---

#### Network Config 6: Zero-Delay Interrupt Coalescing (`ethtool -C rx-usecs 0 adaptive-rx off`)
* **What it is:** Network cards use "Interrupt Coalescing" to bundle multiple arriving packets together before firing a single hardware interrupt to the CPU. `rx-usecs` specifies how many microseconds the NIC waits before generating an interrupt.
* **Untuned Config Value:** `adaptive-rx on`, `rx-usecs = 50` to `100` microseconds
* **Tuned Config Value:** `adaptive-rx off`, `rx-usecs 0`, `tx-usecs 0`
* **What Difference It Makes:** Completely disables packet bundling. Setting `rx-usecs 0` instructs the hardware controller to generate an interrupt (or mark descriptor completion) the **exact instant the last byte of a packet hits the silicon**.
* **Why It's Important for Market Data:** With adaptive coalescing enabled, the first packet of a market data quote burst sits inside the NIC buffer for **50 to 100 microseconds** while the hardware waits to see if more packets arrive! For HFT, a 100 µs delay means your strategy is completely blind to price moves until long after competitors have already traded.

---

#### Network Config 7: Stripping Latency-Inducing NIC Offloads (`ethtool -K ... off`)
* **What it is:** Modern NICs include specialized silicon engines designed to offload packet processing from the CPU:
  - **GRO** (Generic Receive Offload) & **LRO** (Large Receive Offload): Merges multiple consecutive small TCP/UDP packets into a single giant packet buffer before passing it to the OS.
  - **TSO** (TCP Segmentation Offload) & **GSO** (Generic Segmentation Offload): Splits large user-space buffers into MTU-sized packets in hardware.
* **Untuned Config Value:** `gro on`, `lro on`, `tso on`, `gso on`
* **Tuned Config Value:** `gro off`, `lro off`, `tso off`, `gso off`, `rx off`, `tx off`
* **What Difference It Makes:** Forces the network interface to process each packet individually, exactly as received over the wire.
* **Why It's Important for Market Data:** GRO and LRO are catastrophic for market data: they intentionally buffer and delay incoming packets to assemble larger buffers! This adds **20 to 100 microseconds** of artificial latency jitter and can corrupt timing headers used for tick timestamping. Stripping offloads ensures raw, immediate packet delivery.

---

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

### Part 1: The 13 Runtime Kernel & OS Settings
Audits active sysctls, `/sys` files, and background daemons:
```text
┌────┬─────────────────────────────────┬────────────────────┬────────────────────┬──────────┐
│ #  │ TUNING SUBSYSTEM                │ EXPECTED VALUE     │ DETECTED VALUE     │ STATUS   │
├────┼─────────────────────────────────┼────────────────────┼────────────────────┼──────────┤
│ 1  │ CPU Scaling Governor            │ performance        │ performance        │ PASS     │
│ 2  │ PM QoS C-State Elimination      │ 0us lock active    │ active (0us lock)  │ PASS     │
│ 3  │ CFS Task Migration Cost         │ 5000000 ns (5ms)   │ 5000000 ns         │ PASS     │
│ 4  │ Automatic NUMA Balancing*       │ 0 (disabled)       │ 0                  │ PASS     │
│ 5  │ Virtual Memory Swappiness       │ 0 (disabled)       │ 0                  │ PASS     │
│ 6  │ VM Stat Timer Interval          │ 120 seconds        │ 120 seconds        │ PASS     │
│ 7  │ Transparent Hugepages (THP)     │ never (disabled)   │ never              │ PASS     │
│ 8  │ Socket Busy-Polling             │ 50 microseconds    │ 50 us              │ PASS     │
│ 9  │ TCP Slow Start After Idle       │ 0 (disabled)       │ 0                  │ PASS     │
│ 10 │ IRQ Shielding (HK Mask)         │ stopped / aff=<hk> │ stopped / aff=<hk> │ PASS     │
│ 11 │ Static 2MB Hugepages            │ >= <count> pages   │ <count> pages      │ PASS     │
│ 12 │ POSIX Real-Time & Memlock       │ unlimited / 99     │ unlimited / 99     │ PASS     │
│ 13 │ PCIe Network MaxReadReq         │ 4096 bytes         │ 4096 bytes         │ PASS     │
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
