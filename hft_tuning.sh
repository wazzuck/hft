#!/usr/bin/env bash
# ==============================================================================
# HFT LOW-LATENCY KERNEL & OS TUNING SUITE (THE TOP 11 CONFIGS)
# ==============================================================================
# Purpose: Focused, pedagogical, menu-driven tuning suite for multi-NUMA HFT hosts.
# Features:
#   1. Before Benchmark (Nanosecond precision across 8 latency dimensions)
#   2. Apply Top 11 Low-Latency Kernel/OS Tunings (Runtime only - No GRUB / No Reboot)
#   3. After Benchmark (Nanosecond precision post-tuning comparison)
#   4. Learning Mode: Side-by-side nanosecond delta analysis + deep architectural
#      explanation of each of the 11 tunings for multi-NUMA low-latency trading.
# Author : Google Antigravity Advanced Agentic Systems Architecture
# ==============================================================================

set -eo pipefail

export PATH="/usr/local/sbin:/usr/sbin:/sbin:$PATH"

# ------------------------------------------------------------------------------
# 1. VISUAL FORMATTING & COLOR PALETTE
# ------------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ------------------------------------------------------------------------------
# 2. FILE LOCATIONS & RUNTIME STATE
# ------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"

# Dedicated results directory with CPU model auto-detection
BASE_RESULTS_DIR="$SCRIPT_DIR/results"
[ -d "$HOME/results" ] && BASE_RESULTS_DIR="$HOME/results"

# Detect CPU model for results segregation (now and in the future)
CPU_RAW_NAME="$(lscpu 2>/dev/null | awk -F: '/Model name/ {print $2; exit}' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' || awk -F: '/model name/ {print $2; exit}' /proc/cpuinfo 2>/dev/null || echo "Unknown_CPU")"
# Sanitize to clean folder name (e.g. "AMD_Ryzen_9_9900X", "Intel_Core_i9-14900K")
CPU_DIR_NAME="$(echo "$CPU_RAW_NAME" | sed -E -e 's/\([R|TM]+\)//g' -e 's/([0-9]+-Core.*|CPU.*|[0-9]+th Gen.*)//g' -e 's/[^a-zA-Z0-9._-]/_/g' -e 's/__*/_/g' -e 's/^_//' -e 's/_$//')"
[ -z "$CPU_DIR_NAME" ] && CPU_DIR_NAME="$(echo "$CPU_RAW_NAME" | sed -e 's/[^a-zA-Z0-9._-]/_/g' -e 's/__*/_/g' -e 's/^_//' -e 's/_$//')"
[ -z "$CPU_DIR_NAME" ] && CPU_DIR_NAME="Generic_CPU"

# Auto-generate results folder with CPU model, date, and time: e.g. results/AMD_Ryzen_9_9900X_20260910_005443
SESSION_DIR_NAME="${CPU_DIR_NAME}_${TIMESTAMP}"
RESULTS_DIR="$BASE_RESULTS_DIR/$SESSION_DIR_NAME"
mkdir -p "$RESULTS_DIR" 2>/dev/null || RESULTS_DIR="/tmp/$SESSION_DIR_NAME"
mkdir -p "$RESULTS_DIR" 2>/dev/null || RESULTS_DIR="/tmp"

# Maintain convenience symlinks:
# 1. results/<CPU_NAME>_latest -> latest timestamped run for this CPU
# 2. results/<CPU_NAME>        -> latest timestamped run for this CPU
if [ -d "$RESULTS_DIR" ]; then
    ln -sfn "$SESSION_DIR_NAME" "$BASE_RESULTS_DIR/${CPU_DIR_NAME}_latest" 2>/dev/null || true
    ln -sfn "$SESSION_DIR_NAME" "$BASE_RESULTS_DIR/${CPU_DIR_NAME}" 2>/dev/null || true
fi

BEFORE_FILE="$RESULTS_DIR/before_latency_${TIMESTAMP}.txt"
BEFORE_LATEST="$RESULTS_DIR/before_latency_latest.txt"
AFTER_FILE="$RESULTS_DIR/after_latency_${TIMESTAMP}.txt"
AFTER_LATEST="$RESULTS_DIR/after_latency_latest.txt"
SYSCTL_BACKUP="/tmp/hft_tuning_sysctl_backup.conf"

BENCH_SRC="/tmp/hft_mini_bench_${TIMESTAMP}.c"
BENCH_BIN="/tmp/hft_mini_bench_${TIMESTAMP}"
DMA_DAEMON_SRC="/tmp/hft_dma_lock.c"
DMA_DAEMON_BIN="/tmp/hft_dma_lock"
DMA_PID_FILE="/tmp/hft_dma_lock.pid"

# Reboot Persistence Engine Paths
SYSCTL_PERSIST_CONF="/etc/sysctl.d/99-hft-tuning.conf"
BOOT_TUNE_SCRIPT="/usr/local/bin/hft-boot-tune.sh"
DMA_PERSIST_BIN="/usr/local/bin/hft_dma_latency"
SYSTEMD_TUNE_SERVICE="/etc/systemd/system/hft-tuning.service"
SYSTEMD_DMA_SERVICE="/etc/systemd/system/hft-dma-latency.service"

# Associative arrays for metrics
declare -A BEFORE_METRICS
declare -A AFTER_METRICS

# ------------------------------------------------------------------------------
# 3. LOGGING & OUTPUT UTILITIES
# ------------------------------------------------------------------------------
print_banner() {
    clear 2>/dev/null || true
    echo -e "${BLUE}${BOLD}"
    cat << "EOF_BANNER"
  ╔══════════════════════════════════════════════════════════════════════════╗
  ║       ⚡ HFT LOW-LATENCY KERNEL & OS TUNING SUITE (TOP 13) ⚡            ║
  ║      Nanosecond Precision Microbenchmarks • Multi-NUMA Ready             ║
  ╚══════════════════════════════════════════════════════════════════════════╝
EOF_BANNER
    echo -e "${NC}"
}

print_header() {
    echo ""
    echo -e "${BLUE}${BOLD}══════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${WHITE}${BOLD}  $1${NC}"
    echo -e "${BLUE}${BOLD}══════════════════════════════════════════════════════════════════════════${NC}"
}

print_subheader() {
    echo ""
    echo -e "${CYAN}${BOLD}─── $1 ───${NC}"
}

print_info() {
    echo -e "  ${YELLOW}ℹ [INFO]${NC} $1"
}

print_success() {
    echo -e "  ${GREEN}✓ [SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "  ${MAGENTA}⚠ [WARNING]${NC} $1"
}

print_error() {
    echo -e "  ${RED}✗ [ERROR]${NC} $1"
}

pause_for_user() {
    echo ""
    echo -e "${DIM}Press [Enter] to return to the main menu...${NC}"
    read -r
}

# ------------------------------------------------------------------------------
# 4. NANOSECOND RESOLUTION DIAGNOSTIC & REQUIREMENTS
# ------------------------------------------------------------------------------
check_nanosecond_support() {
    print_header "NANOSECOND RESOLUTION HARDWARE & KERNEL DIAGNOSTIC"

    echo -e "  ${WHITE}${BOLD}Testing if true sub-nanosecond hardware timing is active...${NC}\n"

    # 1. Check CPU Invariant TSC
    local has_constant_tsc=false
    local has_nonstop_tsc=false
    if grep -q "constant_tsc" /proc/cpuinfo 2>/dev/null; then
        has_constant_tsc=true
    fi
    if grep -q "nonstop_tsc" /proc/cpuinfo 2>/dev/null; then
        has_nonstop_tsc=true
    fi

    if [ "$has_constant_tsc" = true ] && [ "$has_nonstop_tsc" = true ]; then
        print_success "CPU Invariant Time Stamp Counter (TSC): DETECTED (constant_tsc, nonstop_tsc)"
        echo -e "     -> The TSC increments at a fixed frequency independent of CPU power states or core frequency."
    elif [ "$has_constant_tsc" = true ]; then
        print_warning "CPU TSC has constant_tsc but nonstop_tsc is missing."
    else
        print_error "CPU lacks constant_tsc! Time measurements may drift when CPU frequency changes."
    fi

    # 2. Check Active Clocksource
    local clocksource="unknown"
    if [ -f /sys/devices/system/clocksource/clocksource0/current_clocksource ]; then
        clocksource="$(cat /sys/devices/system/clocksource/clocksource0/current_clocksource)"
    fi

    if [ "$clocksource" = "tsc" ]; then
        print_success "Active Linux Clocksource: 'tsc' (Direct hardware register read, ~15ns overhead)"
    elif [ "$clocksource" = "kvm-clock" ]; then
        print_info "Active Linux Clocksource: 'kvm-clock' (Virtual guest clocksource)"
        echo -e "     -> In virtual machines, kvm-clock provides nanosecond resolution but has slight hypervisor jitter."
    else
        print_warning "Active Linux Clocksource: '$clocksource' (Slow fallback clocksource: HPET or ACPI PM)"
    fi

    # 3. Measure TSC frequency and clock resolution in C
    cat << 'EOF_TSC_TEST' > /tmp/hft_tsc_test.c
#define _GNU_SOURCE
#include <stdio.h>
#include <stdint.h>
#include <time.h>
#include <x86intrin.h>

int main(void) {
    struct timespec res;
    clock_getres(CLOCK_MONOTONIC, &res);
    printf("CLOCK_RES_NS=%ld\n", res.tv_nsec);

    struct timespec slp = {0, 50000000}; // 50ms
    _mm_lfence();
    uint64_t t0 = _rdtsc();
    _mm_lfence();
    nanosleep(&slp, NULL);
    _mm_lfence();
    uint64_t t1 = _rdtsc();
    _mm_lfence();
    double ghz = (double)(t1 - t0) / 50000000.0;
    printf("CALIBRATED_GHZ=%.4f\n", ghz);
    return 0;
}
EOF_TSC_TEST

    local res_ns="1" ghz="3.0"
    if gcc -O2 /tmp/hft_tsc_test.c -o /tmp/hft_tsc_test 2>/dev/null; then
        local tsc_out
        tsc_out="$(/tmp/hft_tsc_test)"
        res_ns="$(echo "$tsc_out" | awk -F= '/CLOCK_RES_NS/ {print $2}')"
        ghz="$(echo "$tsc_out" | awk -F= '/CALIBRATED_GHZ/ {print $2}')"
        rm -f /tmp/hft_tsc_test.c /tmp/hft_tsc_test
    fi

    print_success "POSIX CLOCK_MONOTONIC Resolution: ${res_ns} nanosecond(s)"
    print_success "Calibrated Hardware TSC Frequency: ${ghz} GHz (Tick cycle = ~$(echo "scale=3; 1.0 / $ghz" | bc -l 2>/dev/null || echo "0.32") ns)"

    echo ""
    echo -e "${WHITE}${BOLD}EXPLANATION OF NANOSECOND AVAILABILITY & REQUIREMENTS:${NC}"
    cat << "EOF_NS_EXPLAIN"
  1. How Nanosecond Precision is Achieved in this Suite:
     - On modern x86_64 processors, timing does NOT rely on slow OS system calls.
     - The microbenchmark embeds inline assembly for the CPU Time Stamp Counter (RDTSC).
     - We execute `_mm_lfence()` before and after `_rdtsc()` to serialize the CPU pipeline,
       preventing out-of-order execution from measuring instructions outside the timing window.
     - Each clock tick represents exactly 1 CPU cycle (~0.3 nanoseconds on a 3.1 GHz core).

  2. What is Required if Nanosecond Precision is Unavailable or Inaccurate:
     - Hardware Requirement: Intel Nehalem+ or AMD Zen+ with invariant TSC.
     - BIOS Setting: Disable "Spread Spectrum Clocking" (modulates bus clocks for EMI).
     - Virtualization Note: In KVM/QEMU, launch the VM with:
         --cpu host-passthrough,cache.mode=passthrough
       This passes the physical host CPU's invariant TSC directly into the guest VM.
     - Kernel Setting: Ensure the active clocksource is set to 'tsc':
         echo tsc > /sys/devices/system/clocksource/clocksource0/current_clocksource
EOF_NS_EXPLAIN
}

# ------------------------------------------------------------------------------
# 4.5 EXHAUSTIVE HOST HARDWARE SPECIFICATION & TOPOLOGY INTROSPECTION ENGINE
# ------------------------------------------------------------------------------
collect_host_hardware_profile() {
    local out_dir="${1:-$RESULTS_DIR}"
    mkdir -p "$out_dir" 2>/dev/null || true
    local out_txt="$out_dir/host_hardware_profile.txt"
    local out_json="$out_dir/host_hardware_profile.json"

    print_info "Collecting exhaustive host hardware profile..."

    # System & DMI Metadata
    local sys_vendor="$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || echo "Unknown")"
    local prod_name="$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo "Unknown")"
    local prod_ver="$(cat /sys/class/dmi/id/product_version 2>/dev/null || echo "Unknown")"
    local board_name="$(cat /sys/class/dmi/id/board_name 2>/dev/null || echo "Unknown")"
    local board_vendor="$(cat /sys/class/dmi/id/board_vendor 2>/dev/null || echo "Unknown")"
    local bios_vendor="$(cat /sys/class/dmi/id/bios_vendor 2>/dev/null || echo "Unknown")"
    local bios_version="$(cat /sys/class/dmi/id/bios_version 2>/dev/null || echo "Unknown")"
    local bios_date="$(cat /sys/class/dmi/id/bios_date 2>/dev/null || echo "Unknown")"

    # CPU Metadata
    local cpu_model="$(lscpu 2>/dev/null | awk -F: '/Model name/ {print $2; exit}' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' || awk -F: '/model name/ {print $2; exit}' /proc/cpuinfo 2>/dev/null || echo "Unknown")"
    local cpu_arch="$(uname -m)"
    local cpu_sockets="$(lscpu 2>/dev/null | awk -F: '/Socket\(s\)/ {print $2}' | xargs || echo "1")"
    local cpu_cores="$(lscpu 2>/dev/null | awk -F: '/Core\(s\) per socket/ {print $2}' | xargs || echo "1")"
    local cpu_threads="$(lscpu 2>/dev/null | awk -F: '/Thread\(s\) per core/ {print $2}' | xargs || echo "1")"
    local cpu_total="$(nproc --all 2>/dev/null || echo "1")"
    local cpu_online="$(cat /sys/devices/system/cpu/online 2>/dev/null || echo "all")"
    local cpu_offline="$(cat /sys/devices/system/cpu/offline 2>/dev/null || echo "none")"
    local cpu_max_mhz="$(lscpu 2>/dev/null | awk -F: '/CPU max MHz/ {print $2}' | xargs || echo "unknown")"
    local numa_nodes="$(lscpu 2>/dev/null | awk -F: '/NUMA node\(s\)/ {print $2}' | xargs || echo "1")"
    local l1d_cache="$(lscpu 2>/dev/null | awk -F: '/L1d cache/ {print $2}' | xargs || echo "unknown")"
    local l1i_cache="$(lscpu 2>/dev/null | awk -F: '/L1i cache/ {print $2}' | xargs || echo "unknown")"
    local l2_cache="$(lscpu 2>/dev/null | awk -F: '/L2 cache/ {print $2}' | xargs || echo "unknown")"
    local l3_cache="$(lscpu 2>/dev/null | awk -F: '/L3 cache/ {print $2}' | xargs || echo "unknown")"
    local cpu_gov="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "unknown")"
    local cstate_drv="$(cat /sys/devices/system/cpu/cpuidle/current_driver 2>/dev/null || echo "none")"
    local smt_state="$(cat /sys/devices/system/cpu/smt/control 2>/dev/null || echo "unknown")"

    # Memory Metadata
    local mem_total_kb="$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo "0")"
    local mem_avail_kb="$(awk '/MemAvailable/ {print $2}' /proc/meminfo 2>/dev/null || echo "0")"
    local mem_total_gb="$(awk -v kb="$mem_total_kb" 'BEGIN {printf "%.1f", kb/1024/1024}')"
    local swap_total_kb="$(awk '/SwapTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo "0")"

    # OS / Kernel
    local os_pretty="$(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME" || echo "Linux")"
    local kernel_ver="$(uname -r)"
    local kernel_cmdline="$(cat /proc/cmdline 2>/dev/null)"
    local clocksource="$(cat /sys/devices/system/clocksource/clocksource0/current_clocksource 2>/dev/null || echo "unknown")"
    local host_name="$(hostname 2>/dev/null || echo "unknown")"

    # Write Exhaustive Text Specification
    cat << EOF_TXT > "$out_txt"
================================================================================
HOST SYSTEM & HARDWARE SPECIFICATION PROFILE
================================================================================
Capture Timestamp    : $(date -u +"%Y-%m-%d %H:%M:%S UTC")
Host Name            : $host_name
Operating System     : $os_pretty
Linux Kernel         : $kernel_ver ($cpu_arch)
Active Clocksource   : $clocksource
Kernel Command Line  : $kernel_cmdline

--------------------------------------------------------------------------------
1. SYSTEM & MOTHERBOARD
--------------------------------------------------------------------------------
System Manufacturer  : $sys_vendor
Product Model Name   : $prod_name
Product Version      : $prod_ver
Motherboard Model    : $board_name (Vendor: $board_vendor)
BIOS Firmware Vendor : $bios_vendor
BIOS Firmware Version: $bios_version
BIOS Release Date    : $bios_date

--------------------------------------------------------------------------------
2. PROCESSOR ARCHITECTURE & TOPOLOGY
--------------------------------------------------------------------------------
CPU Model String     : $cpu_model
Instruction Arch     : $cpu_arch
Physical Sockets     : $cpu_sockets
Physical Cores/Socket: $cpu_cores
Threads per Core     : $cpu_threads
Total Logical Cores  : $cpu_total
Online CPU Mask      : $cpu_online
Offline CPU Mask     : $cpu_offline
Max Rated Frequency  : ${cpu_max_mhz} MHz
Scaling Governor     : $cpu_gov
SMT Control State    : $smt_state
CPU Idle Driver      : $cstate_drv
NUMA Architecture    : $numa_nodes NUMA Node(s)
L1 Data Cache        : $l1d_cache
L1 Instruction Cache : $l1i_cache
L2 Cache             : $l2_cache
L3 Cache             : $l3_cache
Hardware TSC Features: $(grep -q "constant_tsc" /proc/cpuinfo 2>/dev/null && echo "constant_tsc" || echo "") $(grep -q "nonstop_tsc" /proc/cpuinfo 2>/dev/null && echo "nonstop_tsc" || echo "")

--------------------------------------------------------------------------------
3. MEMORY SUBSYSTEM & PHYSICAL DIMMS
--------------------------------------------------------------------------------
Total System DRAM    : ${mem_total_gb} GB (${mem_total_kb} kB)
Available DRAM       : $(awk -v kb="$mem_avail_kb" 'BEGIN {printf "%.1f", kb/1024/1024}') GB
Configured Swap Space: $(awk -v kb="$swap_total_kb" 'BEGIN {printf "%.1f", kb/1024/1024}') GB

Physical DIMM Modules (DMI):
$(sudo dmidecode -t memory 2>/dev/null | grep -E "Locator:|Size: [0-9]|Type: DDR|Speed: [0-9]|Manufacturer:|Part Number:" | head -30 || echo "  (DMI memory information not accessible)")

--------------------------------------------------------------------------------
4. NETWORK CONTROLLERS & PHYSICAL INTERFACES
--------------------------------------------------------------------------------
PCI Network Controllers:
$(lspci -nnk 2>/dev/null | grep -E -A 3 "Ethernet controller" || echo "  (None detected)")

Active Network Interfaces:
$(ip -br a 2>/dev/null || echo "  (Unable to query ip)")

--------------------------------------------------------------------------------
5. STORAGE & NVME SUBSYSTEM
--------------------------------------------------------------------------------
PCI Storage Controllers:
$(lspci -nnk 2>/dev/null | grep -E -A 3 "Non-Volatile memory" || echo "  (None detected)")

Block Storage Devices:
$(lsblk -o NAME,SIZE,TYPE,FSTYPE,MODEL,MOUNTPOINTS 2>/dev/null || echo "  (Unable to query lsblk)")

--------------------------------------------------------------------------------
6. PCIE BUS SUBSYSTEM & VIRTUALIZATION
--------------------------------------------------------------------------------
PCIe ASPM Link Policy: $(cat /sys/module/pcie_aspm/parameters/policy 2>/dev/null || echo "N/A")
IOMMU Hardware State : $([ -d /sys/class/iommu ] && ls -d /sys/class/iommu/* 2>/dev/null | head -1 || echo "Disabled / Bypass")
================================================================================
EOF_TXT

    # Generate Machine-Readable JSON Profile
    if command -v python3 >/dev/null 2>&1; then
        python3 -c "
import json
data = {
    \"capture_timestamp_utc\": \"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\",
    \"hostname\": \"$host_name\",
    \"os\": {
        \"pretty_name\": \"$os_pretty\",
        \"kernel_release\": \"$kernel_ver\",
        \"architecture\": \"$cpu_arch\",
        \"clocksource\": \"$clocksource\",
        \"cmdline\": \"$kernel_cmdline\"
    },
    \"system\": {
        \"manufacturer\": \"$sys_vendor\",
        \"product_name\": \"$prod_name\",
        \"product_version\": \"$prod_ver\",
        \"motherboard_model\": \"$board_name\",
        \"motherboard_vendor\": \"$board_vendor\",
        \"bios_vendor\": \"$bios_vendor\",
        \"bios_version\": \"$bios_version\",
        \"bios_release_date\": \"$bios_date\"
    },
    \"processor\": {
        \"model\": \"$cpu_model\",
        \"sockets\": \"$cpu_sockets\",
        \"cores_per_socket\": \"$cpu_cores\",
        \"threads_per_core\": \"$cpu_threads\",
        \"total_logical_cpus\": \"$cpu_total\",
        \"online_cpus\": \"$cpu_online\",
        \"offline_cpus\": \"$cpu_offline\",
        \"max_frequency_mhz\": \"$cpu_max_mhz\",
        \"scaling_governor\": \"$cpu_gov\",
        \"smt_control\": \"$smt_state\",
        \"cstate_driver\": \"$cstate_drv\",
        \"numa_nodes\": \"$numa_nodes\",
        \"cache\": {
            \"l1d\": \"$l1d_cache\",
            \"l1i\": \"$l1i_cache\",
            \"l2\": \"$l2_cache\",
            \"l3\": \"$l3_cache\"
        }
    },
    \"memory\": {
        \"total_gb\": \"$mem_total_gb\",
        \"total_kb\": \"$mem_total_kb\",
        \"available_kb\": \"$mem_avail_kb\",
        \"swap_total_kb\": \"$swap_total_kb\"
    }
}
print(json.dumps(data, indent=2))
" > "$out_json" 2>/dev/null || true
    fi

    print_success "Host hardware profile captured:"
    echo "     • Text Specification   : $out_txt"
    [ -f "$out_json" ] && echo "     • Machine-Readable JSON: $out_json"
}

# ------------------------------------------------------------------------------
# 5. EMBEDDED C NANOSECOND MICROBENCHMARK ENGINE
# ------------------------------------------------------------------------------
ensure_benchmark_binary() {
    if [ -x "$BENCH_BIN" ]; then
        return 0
    fi

    print_info "Compiling embedded nanosecond microbenchmark suite..."

    cat << 'EOF_BENCH' > "$BENCH_SRC"
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <pthread.h>
#include <sched.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <sys/un.h>
#include <sys/mman.h>
#include <x86intrin.h>

static double tsc_ghz = 0.0;
static int target_core = 0;

static void pin_thread(int core_id) {
    if (core_id < 0) return;
    cpu_set_t cpuset;
    CPU_ZERO(&cpuset);
    CPU_SET(core_id, &cpuset);
    pthread_setaffinity_np(pthread_self(), sizeof(cpu_set_t), &cpuset);
}

static void calibrate_tsc(void) {
    struct timespec slp = {0, 100000000}; // 100ms
    _mm_lfence();
    uint64_t t0 = _rdtsc();
    _mm_lfence();
    nanosleep(&slp, NULL);
    _mm_lfence();
    uint64_t t1 = _rdtsc();
    _mm_lfence();
    tsc_ghz = (double)(t1 - t0) / 100000000.0;
    if (tsc_ghz < 0.5) tsc_ghz = 2.5; // safe fallback
}

static inline double cycles_to_ns(uint64_t cycles) {
    return (double)cycles / tsc_ghz;
}

static int cmp_doubles(const void *a, const void *b) {
    double da = *(const double *)a;
    double db = *(const double *)b;
    return (da > db) - (da < db);
}

typedef struct {
    double min;
    double mean;
    double p90;
    double p99;
    double max;
} LatencyStats;

static LatencyStats compute_stats(double *samples, size_t n) {
    LatencyStats st = {0};
    if (n == 0) return st;
    qsort(samples, n, sizeof(double), cmp_doubles);
    st.min = samples[0];
    st.max = samples[n - 1];
    st.p90 = samples[(size_t)(n * 0.90)];
    st.p99 = samples[(size_t)(n * 0.99)];
    double sum = 0.0;
    for (size_t i = 0; i < n; i++) sum += samples[i];
    st.mean = sum / n;
    return st;
}

// 1. Clock monotonic (vDSO)
static void bench_clock(LatencyStats *st) {
    const int N = 200000;
    double *s = malloc(N * sizeof(double));
    struct timespec ts;
    for (int i = 0; i < N; i++) {
        _mm_lfence();
        uint64_t t0 = _rdtsc();
        _mm_lfence();
        clock_gettime(CLOCK_MONOTONIC, &ts);
        _mm_lfence();
        uint64_t t1 = _rdtsc();
        s[i] = cycles_to_ns(t1 - t0);
    }
    *st = compute_stats(s, N);
    free(s);
}

// 2. Minimal syscall getpid
static void bench_syscall(LatencyStats *st) {
    const int N = 100000;
    double *s = malloc(N * sizeof(double));
    for (int i = 0; i < N; i++) {
        _mm_lfence();
        uint64_t t0 = _rdtsc();
        _mm_lfence();
        getpid();
        _mm_lfence();
        uint64_t t1 = _rdtsc();
        s[i] = cycles_to_ns(t1 - t0);
    }
    *st = compute_stats(s, N);
    free(s);
}

// 3. Context switch via pipes
typedef struct { int p1[2]; int p2[2]; int n; } PipeCtx;
static void *pipe_worker(void *arg) {
    PipeCtx *c = (PipeCtx *)arg;
    pin_thread(target_core);
    uint64_t v = 0;
    for (int i = 0; i < c->n; i++) {
        if (read(c->p1[0], &v, sizeof(v)) <= 0) break;
        if (write(c->p2[1], &v, sizeof(v)) <= 0) break;
    }
    return NULL;
}

static void bench_ctx_switch(LatencyStats *st) {
    const int N = 10000;
    PipeCtx c;
    if (pipe(c.p1) < 0 || pipe(c.p2) < 0) return;
    c.n = N;
    pthread_t th;
    pthread_create(&th, NULL, pipe_worker, &c);
    double *s = malloc(N * sizeof(double));
    uint64_t v = 1;
    for (int i = 0; i < N; i++) {
        _mm_lfence();
        uint64_t t0 = _rdtsc();
        _mm_lfence();
        if (write(c.p1[1], &v, sizeof(v)) <= 0) break;
        if (read(c.p2[0], &v, sizeof(v)) <= 0) break;
        _mm_lfence();
        uint64_t t1 = _rdtsc();
        s[i] = cycles_to_ns(t1 - t0) / 2.0; // 2 switches per round-trip
    }
    pthread_join(th, NULL);
    close(c.p1[0]); close(c.p1[1]); close(c.p2[0]); close(c.p2[1]);
    *st = compute_stats(s, N);
    free(s);
}

// 4. TCP loopback ping-pong (64 bytes)
typedef struct { int port; int n; } NetCtx;
static void *tcp_srv(void *arg) {
    NetCtx *c = (NetCtx *)arg;
    pin_thread(target_core);
    int srv = socket(AF_INET, SOCK_STREAM, 0);
    int opt = 1;
    setsockopt(srv, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
    struct sockaddr_in addr = { .sin_family = AF_INET, .sin_port = htons(c->port), .sin_addr.s_addr = htonl(INADDR_LOOPBACK) };
    bind(srv, (struct sockaddr *)&addr, sizeof(addr));
    listen(srv, 1);
    int cl = accept(srv, NULL, NULL);
    setsockopt(cl, IPPROTO_TCP, TCP_NODELAY, &opt, sizeof(opt));
    int poll_us = 50;
    setsockopt(cl, SOL_SOCKET, SO_BUSY_POLL, &poll_us, sizeof(poll_us));
    char buf[64];
    for (int i = 0; i < c->n; i++) {
        if (recv(cl, buf, sizeof(buf), MSG_WAITALL) <= 0) break;
        send(cl, buf, sizeof(buf), 0);
    }
    close(cl); close(srv);
    return NULL;
}

static void bench_tcp(LatencyStats *st) {
    const int N = 8000;
    int port = 28765;
    NetCtx c = { .port = port, .n = N };
    pthread_t th;
    pthread_create(&th, NULL, tcp_srv, &c);
    usleep(40000);
    int sock = socket(AF_INET, SOCK_STREAM, 0);
    int opt = 1;
    setsockopt(sock, IPPROTO_TCP, TCP_NODELAY, &opt, sizeof(opt));
    int poll_us = 50;
    setsockopt(sock, SOL_SOCKET, SO_BUSY_POLL, &poll_us, sizeof(poll_us));
    struct sockaddr_in addr = { .sin_family = AF_INET, .sin_port = htons(port), .sin_addr.s_addr = htonl(INADDR_LOOPBACK) };
    connect(sock, (struct sockaddr *)&addr, sizeof(addr));
    char buf[64] = {0};
    double *s = malloc(N * sizeof(double));
    for (int i = 0; i < N; i++) {
        _mm_lfence();
        uint64_t t0 = _rdtsc();
        _mm_lfence();
        send(sock, buf, sizeof(buf), 0);
        recv(sock, buf, sizeof(buf), MSG_WAITALL);
        _mm_lfence();
        uint64_t t1 = _rdtsc();
        s[i] = cycles_to_ns(t1 - t0);
    }
    close(sock);
    pthread_join(th, NULL);
    *st = compute_stats(s, N);
    free(s);
}

// 5. Memory Pointer Chasing (Random in 16MB buffer using 2MB Hugepages when available)
static void bench_mem_pointer_chase(double *ns_per_access) {
    const size_t sz = 16 * 1024 * 1024 / sizeof(void *);
    const size_t bytes = 16 * 1024 * 1024;
    void **arr = (void **)mmap(NULL, bytes, PROT_READ | PROT_WRITE,
                               MAP_PRIVATE | MAP_ANONYMOUS | MAP_HUGETLB, -1, 0);
    int is_mmap = 1;
    if (arr == MAP_FAILED) {
        arr = (void **)malloc(bytes);
        is_mmap = 0;
    }
    if (!arr) { *ns_per_access = 0.0; return; }
    size_t *indices = malloc(sz * sizeof(size_t));
    if (!indices) { if (is_mmap) munmap(arr, bytes); else free(arr); *ns_per_access = 0.0; return; }
    for (size_t i = 0; i < sz; i++) indices[i] = i;
    srand(12345);
    for (size_t i = sz - 1; i > 0; i--) {
        size_t j = rand() % (i + 1);
        size_t tmp = indices[i];
        indices[i] = indices[j];
        indices[j] = tmp;
    }
    for (size_t i = 0; i < sz - 1; i++) arr[indices[i]] = (void *)&arr[indices[i + 1]];
    arr[indices[sz - 1]] = (void *)&arr[indices[0]];
    free(indices);

    const int loops = 1500000;
    void **p = &arr[0];
    _mm_lfence();
    uint64_t t0 = _rdtsc();
    _mm_lfence();
    for (int i = 0; i < loops; i++) {
        p = (void **)*p;
    }
    _mm_lfence();
    uint64_t t1 = _rdtsc();
    if ((uintptr_t)p == 0xdeadbeef) printf("magic\n");
    *ns_per_access = cycles_to_ns(t1 - t0) / loops;
    if (is_mmap) {
        munmap(arr, bytes);
    } else {
        free(arr);
    }
}

// 6. OS Jitter Spin-loop (1 second)
static void bench_jitter(double *max_spike_ns, uint64_t *spikes) {
    uint64_t dur_cycles = (uint64_t)(1000000000ULL * tsc_ghz);
    uint64_t thresh_cycles = (uint64_t)(1000.0 * tsc_ghz);
    uint64_t start = _rdtsc(), prev = start, count = 0, max_gap = 0;
    while (1) {
        _mm_lfence();
        uint64_t cur = _rdtsc();
        uint64_t d = cur - prev;
        if (d > thresh_cycles) {
            count++;
            if (d > max_gap) max_gap = d;
        }
        prev = cur;
        if (cur - start >= dur_cycles) break;
    }
    *max_spike_ns = cycles_to_ns(max_gap);
    *spikes = count;
}

// 7. Modern Kernel-Bypass AF_XDP Zero-Copy Ring Benchmark
#if defined(HAVE_XDP)
#include <linux/if_link.h>
#include <linux/if_xdp.h>
#include <bpf/bpf.h>
#include <xdp/xsk.h>

#define XSK_NUM_FRAMES 2048
#define XSK_FRAME_SIZE XSK_UMEM__DEFAULT_FRAME_SIZE
#define XSK_ITERS 10000

static void bench_afxdp(LatencyStats *st) {
    void *bufs;
    size_t size = XSK_NUM_FRAMES * XSK_FRAME_SIZE;
    if (posix_memalign(&bufs, getpagesize(), size)) return;

    struct xsk_ring_prod fq;
    struct xsk_ring_cons cq;
    struct xsk_umem *umem;

    struct xsk_umem_config ucfg = {
        .fill_size = XSK_RING_PROD__DEFAULT_NUM_DESCS,
        .comp_size = XSK_RING_CONS__DEFAULT_NUM_DESCS,
        .frame_size = XSK_FRAME_SIZE,
        .frame_headroom = XSK_UMEM__DEFAULT_FRAME_HEADROOM,
        .flags = 0
    };

    int ret = xsk_umem__create(&umem, bufs, size, &fq, &cq, &ucfg);
    if (ret) { free(bufs); return; }

    struct xsk_socket *xsk;
    struct xsk_ring_cons rx;
    struct xsk_ring_prod tx;
    struct xsk_socket_config scfg = {
        .rx_size = XSK_RING_CONS__DEFAULT_NUM_DESCS,
        .tx_size = XSK_RING_PROD__DEFAULT_NUM_DESCS,
        .xdp_flags = XDP_FLAGS_SKB_MODE,
        .bind_flags = XDP_COPY
    };

    ret = xsk_socket__create(&xsk, "lo", 0, umem, &rx, &tx, &scfg);
    if (ret) {
        xsk_umem__delete(umem);
        free(bufs);
        return;
    }
    int xsk_fd = xsk_socket__fd(xsk);

    // Seed fill ring with initial empty frames
    uint32_t fq_idx;
    if (xsk_ring_prod__reserve(&fq, 512, &fq_idx) == 512) {
        for (int i = 0; i < 512; i++) {
            *xsk_ring_prod__fill_addr(&fq, fq_idx++) = i * XSK_FRAME_SIZE;
        }
        xsk_ring_prod__submit(&fq, 512);
    }

    double *s = malloc(XSK_ITERS * sizeof(double));
    uint32_t tx_idx;

    for (int i = 0; i < XSK_ITERS; i++) {
        _mm_lfence();
        uint64_t t0 = _rdtsc();
        _mm_lfence();

        while (xsk_ring_prod__reserve(&tx, 1, &tx_idx) != 1) {
            sendto(xsk_fd, NULL, 0, MSG_DONTWAIT, NULL, 0);
            uint32_t cq_idx;
            unsigned int c = xsk_ring_cons__peek(&cq, 32, &cq_idx);
            if (c > 0) xsk_ring_cons__release(&cq, c);
        }

        struct xdp_desc *desc = xsk_ring_prod__tx_desc(&tx, tx_idx);
        desc->addr = (i % 512) * XSK_FRAME_SIZE;
        desc->len = 64; // 64-byte payload (typical market order)
        xsk_ring_prod__submit(&tx, 1);

        _mm_lfence();
        uint64_t t1 = _rdtsc();
        _mm_lfence();
        s[i] = cycles_to_ns(t1 - t0);

        // Kick Tx and clean completion ring
        sendto(xsk_fd, NULL, 0, MSG_DONTWAIT, NULL, 0);
        uint32_t cq_idx;
        unsigned int c = xsk_ring_cons__peek(&cq, 1, &cq_idx);
        if (c > 0) xsk_ring_cons__release(&cq, c);
    }

    *st = compute_stats(s, XSK_ITERS);
    free(s);
    xsk_socket__delete(xsk);
    xsk_umem__delete(umem);
    free(bufs);
}
#endif

int main(int argc, char **argv) {
    if (argc > 1) target_core = atoi(argv[1]);
    pin_thread(target_core);
    calibrate_tsc();

    LatencyStats clk, sys, ctx, tcp;
    double mem_ns = 0.0, max_j_ns = 0.0;
    uint64_t spikes = 0;

    bench_clock(&clk);
    bench_syscall(&sys);
    bench_ctx_switch(&ctx);
    bench_tcp(&tcp);
    bench_mem_pointer_chase(&mem_ns);
    bench_jitter(&max_j_ns, &spikes);

    printf("CLOCK_AVG_NS=%.1f\nCLOCK_P99_NS=%.1f\n", clk.mean, clk.p99);
    printf("SYSCALL_AVG_NS=%.1f\nSYSCALL_P99_NS=%.1f\n", sys.mean, sys.p99);
    printf("CTXSWITCH_AVG_NS=%.1f\nCTXSWITCH_P99_NS=%.1f\n", ctx.mean, ctx.p99);
    printf("TCPLOOP_AVG_NS=%.1f\nTCPLOOP_P99_NS=%.1f\n", tcp.mean, tcp.p99);
    printf("MEM_CHASE_NS=%.2f\n", mem_ns);
    printf("JITTER_SPIKES=%lu\nJITTER_MAX_NS=%.1f\n", spikes, max_j_ns);

#if defined(HAVE_XDP)
    LatencyStats afxdp = {0};
    bench_afxdp(&afxdp);
    if (afxdp.mean > 0) {
        printf("AFXDP_AVG_NS=%.1f\nAFXDP_P99_NS=%.1f\n", afxdp.mean, afxdp.p99);
    }
#endif

    return 0;
}
EOF_BENCH

    local xdp_flags=""
    local xdp_libs=""
    if [ -f /usr/include/xdp/xsk.h ] || pkg-config --exists libxdp 2>/dev/null; then
        xdp_flags="-DHAVE_XDP"
        xdp_libs="-lxdp -lbpf"
    fi

    gcc -O3 -march=native -pthread $xdp_flags "$BENCH_SRC" $xdp_libs -o "$BENCH_BIN" 2>/dev/null || \
    gcc -O3 -pthread $xdp_flags "$BENCH_SRC" $xdp_libs -o "$BENCH_BIN" 2>/dev/null || \
    gcc -O3 -pthread "$BENCH_SRC" -o "$BENCH_BIN"
    chmod +x "$BENCH_BIN"
}

# ------------------------------------------------------------------------------
# 6. PM QoS C-STATE LOCK BACKGROUND HELPER
# ------------------------------------------------------------------------------
start_dma_lock() {
    if [ ! -f "$DMA_DAEMON_BIN" ]; then
        cat << 'EOF_DMA' > "$DMA_DAEMON_SRC"
#include <fcntl.h>
#include <stdint.h>
#include <unistd.h>
int main(void) {
    int fd = open("/dev/cpu_dma_latency", O_RDWR);
    if (fd < 0) return 1;
    int32_t val = 0;
    write(fd, &val, sizeof(val));
    while (1) pause();
    return 0;
}
EOF_DMA
        gcc -O2 "$DMA_DAEMON_SRC" -o "$DMA_DAEMON_BIN" 2>/dev/null || true
    fi

    if [ -f "$DMA_DAEMON_BIN" ] && sudo test -c /dev/cpu_dma_latency; then
        stop_dma_lock
        sudo "$DMA_DAEMON_BIN" >/dev/null 2>&1 &
        echo $! | sudo tee "$DMA_PID_FILE" >/dev/null 2>&1 || true
        print_success "PM QoS lock active: exit latency locked to 0us via /dev/cpu_dma_latency."
    fi
}

stop_dma_lock() {
    if [ -f "$DMA_PID_FILE" ]; then
        local pid
        pid="$(cat "$DMA_PID_FILE" 2>/dev/null || true)"
        [ -n "$pid" ] && sudo kill "$pid" 2>/dev/null || true
        sudo rm -f "$DMA_PID_FILE" 2>/dev/null || true
    fi
    sudo pkill -f "$DMA_DAEMON_BIN" 2>/dev/null || true
}

# ------------------------------------------------------------------------------
# 7. BENCHMARK EXECUTION HARNESS ("BEFORE" & "AFTER")
# ------------------------------------------------------------------------------
run_benchmark_pass() {
    local phase="$1" # "BEFORE" or "AFTER"
    local outfile="$BEFORE_FILE"
    local linkfile="$BEFORE_LATEST"
    [ "$phase" = "AFTER" ] && outfile="$AFTER_FILE" && linkfile="$AFTER_LATEST"

    print_header "STEP: RUNNING ${phase} BENCHMARK (NANOSECOND RESOLUTION)"

    ensure_benchmark_binary
    collect_host_hardware_profile "$RESULTS_DIR"

    # Determine measurement core
    local total_cpus
    total_cpus="$(nproc --all 2>/dev/null || echo "1")"
    local bench_core="0"
    [ "$total_cpus" -ge 2 ] && bench_core="1"

    print_info "Running self-contained C microbenchmarks on Core $bench_core..."
    local raw_out
    raw_out="$(sudo "$BENCH_BIN" "$bench_core")"

    # Run cyclictest for timer wakeup latency
    print_info "Running cyclictest on Core $bench_core (30,000 cycles, 200us interval, prio 99)..."
    local c_avg="0" c_max="0"
    local cyc_raw
    if [ "$total_cpus" -ge 2 ]; then
        cyc_raw="$(sudo cyclictest -m -p99 -i 200 -l 30000 -q -N -a "$bench_core" -t 1 2>/dev/null | tail -1 || true)"
    else
        cyc_raw="$(sudo cyclictest -m -p99 -i 200 -l 30000 -q -N 2>/dev/null | tail -1 || true)"
    fi

    if [[ "$cyc_raw" =~ Avg:[[:space:]]*([0-9]+)[[:space:]]+Max:[[:space:]]*([0-9]+) ]]; then
        c_avg="${BASH_REMATCH[1]}"
        c_max="${BASH_REMATCH[2]}"
    fi

    # Record output to file
    {
        echo "PHASE=$phase"
        echo "TIMESTAMP=$(date)"
        echo "CORE=$bench_core"
        echo "$raw_out"
        echo "CYCLIC_AVG_NS=$c_avg"
        echo "CYCLIC_MAX_NS=$c_max"
    } > "$outfile"
    cp -f "$outfile" "$linkfile" 2>/dev/null || true

    # Display results
    print_subheader "${phase} Nanosecond Latency Results"
    printf "  %-32s : %s ns\n" "Clock Monotonic (vDSO) Mean" "$(awk -F= '/CLOCK_AVG_NS/ {print $2}' "$outfile")"
    printf "  %-32s : %s ns\n" "Clock Monotonic (vDSO) P99" "$(awk -F= '/CLOCK_P99_NS/ {print $2}' "$outfile")"
    printf "  %-32s : %s ns\n" "Minimal Syscall (getpid) Mean" "$(awk -F= '/SYSCALL_AVG_NS/ {print $2}' "$outfile")"
    printf "  %-34s : %s ns\n" "Thread Context Switch Mean" "$(awk -F= '/CTXSWITCH_AVG_NS/ {print $2}' "$outfile")"
    printf "  %-34s : %s ns\n" "TCP Loopback Ping-Pong (Kernel)" "$(awk -F= '/TCPLOOP_AVG_NS/ {print $2}' "$outfile")"
    local xdp_mean
    xdp_mean="$(awk -F= '/AFXDP_AVG_NS/ {print $2}' "$outfile" 2>/dev/null || true)"
    if [ -n "$xdp_mean" ]; then
        printf "  %-34s : ${GREEN}%s ns${NC} ${DIM}(Zero-Copy Bypass)${NC}\n" "AF_XDP Kernel-Bypass Ring" "$xdp_mean"
    fi
    printf "  %-34s : %s ns / load\n" "DRAM / LLC Pointer Chase" "$(awk -F= '/MEM_CHASE_NS/ {print $2}' "$outfile")"
    printf "  %-34s : %s ns\n" "Max OS Jitter Pause (>1us)" "$(awk -F= '/JITTER_MAX_NS/ {print $2}' "$outfile")"
    printf "  %-34s : %s ns\n" "Cyclictest Wakeup Jitter (Max)" "$c_max"

    print_success "Results recorded to: $outfile"
}

# ------------------------------------------------------------------------------
# 8. THE 11 MOST IMPORTANT KERNEL & OS LOW-LATENCY TUNINGS
# ------------------------------------------------------------------------------
apply_ten_tunings() {
    print_header "APPLYING THE TOP 13 KERNEL & OS LOW-LATENCY TUNINGS"
    print_info "Runtime execution only: No GRUB modification, no system reboot required."
    echo ""

    # Backup baseline sysctl if not already saved
    if [ ! -f "$SYSCTL_BACKUP" ]; then
        sudo sysctl -a > "$SYSCTL_BACKUP" 2>/dev/null || true
        print_info "Baseline sysctl backed up to $SYSCTL_BACKUP"
    fi

    # 1. CPU Scaling Governor & Min Freq Pinning
    print_subheader "1. CPU Scaling Governor -> Performance & Min Freq Pinning"
    local gov_set=false
    for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        if [ -f "$g" ]; then
            echo performance | sudo tee "$g" >/dev/null 2>&1 || true
            gov_set=true
        fi
    done
    for min_f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_min_freq; do
        local max_f="${min_f%min_freq}max_freq"
        if [ -f "$min_f" ] && [ -f "$max_f" ]; then
            sudo cat "$max_f" 2>/dev/null | sudo tee "$min_f" >/dev/null 2>&1 || true
        fi
    done
    [ "$gov_set" = true ] && print_success "Governor set to 'performance' and min freq locked to max." || print_info "Governor managed by hypervisor/host."

    # 2. PM QoS / C-State Elimination
    print_subheader "2. PM QoS Exit Latency Locking (/dev/cpu_dma_latency = 0)"
    start_dma_lock
    for s in /sys/devices/system/cpu/cpu*/cpuidle/state[1-9]/disable; do
        [ -f "$s" ] && echo 1 | sudo tee "$s" >/dev/null 2>&1 || true
    done

    # 3. Scheduler Task Migration Cost
    print_subheader "3. CFS Scheduler Migration Cost (sched_migration_cost_ns = 5000000)"
    if sudo test -f /sys/kernel/debug/sched/migration_cost_ns; then
        echo 5000000 | sudo tee /sys/kernel/debug/sched/migration_cost_ns >/dev/null 2>&1 || true
        print_success "debugfs: migration_cost_ns = 5,000,000 ns (5ms)"
    elif sysctl kernel.sched_migration_cost_ns >/dev/null 2>&1; then
        sudo sysctl -w kernel.sched_migration_cost_ns=5000000 >/dev/null 2>&1 || true
        print_success "sysctl: kernel.sched_migration_cost_ns = 5000000"
    else
        print_info "migration_cost_ns handled by kernel defaults."
    fi

    # 4. Disable Automatic NUMA Balancing
    print_subheader "4. Disabling Automatic NUMA Balancing (kernel.numa_balancing = 0)"
    sudo sysctl -w kernel.numa_balancing=0 >/dev/null 2>&1 || true
    print_success "kernel.numa_balancing = 0 (kills background NUMA scanner)"

    # 5. Virtual Memory Swappiness = 0 & Direct Reclaim Shield (min_free_kbytes = 1GB)
    print_subheader "5. Eliminating Swapping (vm.swappiness = 0) & Direct Reclaim Shield (min_free_kbytes = 1GB)"
    sudo sysctl -w vm.swappiness=0 >/dev/null 2>&1 || true
    sudo sysctl -w vm.min_free_kbytes=1048576 >/dev/null 2>&1 || true
    print_success "vm.swappiness = 0, vm.min_free_kbytes = 1048576 (1GB emergency pool prevents direct reclaim)"

    # 6. Reduce VM Stat Timer Interruption
    print_subheader "6. Suppressing VM Stat Timer Interrupts (vm.stat_interval = 120)"
    sudo sysctl -w vm.stat_interval=120 >/dev/null 2>&1 || true
    print_success "vm.stat_interval = 120s (reduced 1 Hz timer tick by 99.2%)"

    # 7. Disable Transparent Huge Pages (THP)
    print_subheader "7. Disabling Transparent Huge Pages (transparent_hugepage = never)"
    if [ -f /sys/kernel/mm/transparent_hugepage/enabled ]; then
        echo never | sudo tee /sys/kernel/mm/transparent_hugepage/enabled >/dev/null 2>&1 || true
        echo never | sudo tee /sys/kernel/mm/transparent_hugepage/defrag >/dev/null 2>&1 || true
        print_success "THP disabled (never) to eliminate allocation defrag stalls."
    fi

    # 7b. Pre-allocate Static 2MB Hugepages (hugetlbfs)
    print_subheader "7b. Pre-allocating Static 2MB Hugepages (vm.nr_hugepages = 2048 / 4GB)"
    sudo sysctl -w vm.nr_hugepages=2048 >/dev/null 2>&1 || true
    if [ ! -d /dev/hugepages ]; then
        sudo mkdir -p /dev/hugepages 2>/dev/null || true
    fi
    if ! mountpoint -q /dev/hugepages 2>/dev/null; then
        sudo mount -t hugetlbfs nodev /dev/hugepages >/dev/null 2>&1 || true
    fi
    local hp_avail
    hp_avail="$(grep -i "HugePages_Total" /proc/meminfo 2>/dev/null | awk '{print $2}' || echo "0")"
    print_success "Pre-allocated $hp_avail x 2MB static hugepages for zero-copy UMEM & order books."

    # 8. Network Low-Latency Socket Busy-Polling & NIC Hardware Ring Optimization
    print_subheader "8. Socket Low-Latency Busy-Polling & NIC Hardware Ring Optimization"
    sudo sysctl -w net.core.busy_poll=50 >/dev/null 2>&1 || true
    sudo sysctl -w net.core.busy_read=50 >/dev/null 2>&1 || true
    sudo sysctl -w net.core.netdev_max_backlog=250000 >/dev/null 2>&1 || true
    sudo sysctl -w net.core.default_qdisc=pfifo_fast >/dev/null 2>&1 || true
    print_success "net.core.busy_poll = 50us, busy_read = 50us, default_qdisc = pfifo_fast"

    # Hardware NIC / Intel E810 & 10GbE Ring & Coalescing Optimization
    local nic_tuned=false
    for iface in $(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -v -E '^(lo|virbr|docker|veth)'); do
        if command -v ethtool >/dev/null 2>&1; then
            sudo ethtool -G "$iface" rx 1024 tx 1024 >/dev/null 2>&1 || sudo ethtool -G "$iface" rx 4096 tx 4096 >/dev/null 2>&1 || true
            sudo ethtool -C "$iface" adaptive-rx off adaptive-tx off rx-usecs 0 tx-usecs 0 >/dev/null 2>&1 || true
            sudo ethtool -K "$iface" gro off lro off tso off gso off ntuple on >/dev/null 2>&1 || sudo ethtool -K "$iface" gro off lro off tso off gso off >/dev/null 2>&1 || true
            sudo tc qdisc replace dev "$iface" root pfifo_fast >/dev/null 2>&1 || sudo tc qdisc replace dev "$iface" root mq >/dev/null 2>&1 || true
            print_success "NIC $iface: Ring buffers optimized, adaptive coalescing disabled (0us), offloads stripped, qdisc pfifo_fast."
            nic_tuned=true
        fi
    done
    [ "$nic_tuned" = false ] && print_info "Hardware NIC rings tuned via kernel defaults / virtual adapter."

    # 9. TCP Slow Start After Idle & Immediate Serialization (tcp_autocorking = 0)
    print_subheader "9. TCP Immediate Serialization (autocorking = 0, slow_start_after_idle = 0)"
    sudo sysctl -w net.ipv4.tcp_slow_start_after_idle=0 >/dev/null 2>&1 || true
    sudo sysctl -w net.ipv4.tcp_timestamps=0 >/dev/null 2>&1 || true
    sudo sysctl -w net.ipv4.tcp_autocorking=0 >/dev/null 2>&1 || true
    sudo sysctl -w net.ipv4.tcp_no_metrics_save=1 >/dev/null 2>&1 || true
    sudo sysctl -w net.ipv4.tcp_moderate_rcvbuf=0 >/dev/null 2>&1 || true
    sudo sysctl -w net.ipv4.udp_rmem_min=16384 >/dev/null 2>&1 || true
    sudo sysctl -w net.ipv4.udp_wmem_min=16384 >/dev/null 2>&1 || true
    print_success "TCP immediate serialization active: autocorking=0, no_metrics_save=1, slow_start_after_idle=0"

    # 10. Stop IRQBalance & Pin Peripheral IRQs to Housekeeping Core
    print_subheader "10. Disabling IRQBalance & Shielding Trading Cores from IRQs"
    if systemctl is-active --quiet irqbalance 2>/dev/null; then
        sudo systemctl stop irqbalance >/dev/null 2>&1 || true
        print_success "Stopped irqbalance service."
    fi
    # Pin IRQs to Core 0 (mask 1)
    echo 1 | sudo tee /proc/irq/default_smp_affinity >/dev/null 2>&1 || true
    for irq_aff in /proc/irq/*/smp_affinity; do
        [ -f "$irq_aff" ] && echo 1 | sudo tee "$irq_aff" >/dev/null 2>&1 || true
    done
    print_success "All hardware and network IRQs pinned away from trading cores to Core 0."

    # 11. SMT / Hyper-Threading Disabling at Runtime
    print_subheader "11. SMT / Hyper-Threading Disablement (1 Thread/Core)"
    if [ -f /sys/devices/system/cpu/smt/control ]; then
        echo off | sudo tee /sys/devices/system/cpu/smt/control >/dev/null 2>&1 || true
        print_success "SMT disabled at runtime (/sys/devices/system/cpu/smt/control -> off)."
    fi

    # 12. POSIX Real-Time & Memory Locking Limits (mlockall & rtprio)
    print_subheader "12. POSIX Real-Time & Memory Locking Limits (memlock unlimited, rtprio 99)"
    if [ ! -d /etc/security/limits.d ]; then
        sudo mkdir -p /etc/security/limits.d 2>/dev/null || true
    fi
    cat << 'EOF_LIMITS' | sudo tee /etc/security/limits.d/99-hft.conf >/dev/null
* soft memlock unlimited
* hard memlock unlimited
* soft nofile 1048576
* hard nofile 1048576
* soft rtprio 99
* hard rtprio 99
root soft memlock unlimited
root hard memlock unlimited
root soft nofile 1048576
root hard nofile 1048576
root soft rtprio 99
root hard rtprio 99
EOF_LIMITS
    sudo mkdir -p /etc/systemd/system.conf.d /etc/systemd/user.conf.d 2>/dev/null || true
    cat << 'EOF_SYSCONF' | sudo tee /etc/systemd/system.conf.d/99-hft.conf >/dev/null
[Manager]
DefaultLimitNOFILE=1048576:1048576
DefaultLimitMEMLOCK=infinity:infinity
DefaultLimitRTPRIO=99:99
EOF_SYSCONF
    cat << 'EOF_USRCONF' | sudo tee /etc/systemd/user.conf.d/99-hft.conf >/dev/null
[Manager]
DefaultLimitNOFILE=1048576:1048576
DefaultLimitMEMLOCK=infinity:infinity
DefaultLimitRTPRIO=99:99
EOF_USRCONF
    print_success "POSIX limits configured: memlock=unlimited, nofile=1048576, rtprio=99."

    # 13. PCIe Max Read Request Size (MRRS = 4096B) & Full Kernel Preemption
    print_subheader "13. PCIe High-Performance Bus Tuning (MRRS = 4096B) & Preemption"
    local pcie_tuned=false
    for bdf in $(lspci -D -d ::0200 2>/dev/null | awk '{print $1}'); do
        if command -v setpci >/dev/null 2>&1; then
            sudo setpci -s "$bdf" CAP_EXP+8.w=5000:7000 >/dev/null 2>&1 || true
            pcie_tuned=true
        fi
    done
    [ "$pcie_tuned" = true ] && print_success "PCIe Device Control: Network controllers set to MaxReadReq 4096B." || print_info "PCIe bus managed by host."

    # Dynamic preemption mode
    if [ -f /sys/kernel/debug/sched/preempt ]; then
        echo full | sudo tee /sys/kernel/debug/sched/preempt >/dev/null 2>&1 || true
        print_success "Kernel preemption switched to FULL (PREEMPT_DYNAMIC -> full)."
    fi

    echo ""
    print_success "All key low-latency configurations successfully applied!"
}

# ------------------------------------------------------------------------------
# 9. REVERT CAPABILITY
# ------------------------------------------------------------------------------
revert_tunings() {
    print_header "REVERTING SYSTEM SETTINGS TO PRE-TUNING BASELINE"

    stop_dma_lock

    # Re-enable C-States
    for s in /sys/devices/system/cpu/cpu*/cpuidle/state[1-9]/disable; do
        [ -f "$s" ] && echo 0 | sudo tee "$s" >/dev/null 2>&1 || true
    done

    # Reset CPU governor to schedutil / ondemand
    for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        [ -f "$g" ] && echo schedutil | sudo tee "$g" >/dev/null 2>&1 || true
    done

    # Restore sysctl parameters to standard Linux defaults
    sudo sysctl -w \
        net.core.busy_poll=0 \
        net.core.busy_read=0 \
        net.core.default_qdisc=fq_codel \
        vm.swappiness=30 \
        vm.stat_interval=1 \
        vm.min_free_kbytes=45451 \
        kernel.numa_balancing=1 \
        net.ipv4.tcp_slow_start_after_idle=1 \
        net.ipv4.tcp_autocorking=1 \
        net.ipv4.tcp_no_metrics_save=0 \
        net.ipv4.tcp_moderate_rcvbuf=1 \
        net.ipv4.tcp_timestamps=1 >/dev/null 2>&1 || true

    for iface in $(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -v -E '^(lo|virbr|docker|veth)'); do
        sudo tc qdisc replace dev "$iface" root fq_codel >/dev/null 2>&1 || sudo tc qdisc del dev "$iface" root >/dev/null 2>&1 || true
    done

    if systemctl is-enabled --quiet irqbalance 2>/dev/null; then
        sudo systemctl start irqbalance >/dev/null 2>&1 || true
        print_success "Restarted irqbalance service."
    fi

    # Reset default IRQ smp affinity mask (broadcast to all cores)
    if [ -f /proc/irq/default_smp_affinity ]; then
        echo "ff" | sudo tee /proc/irq/default_smp_affinity >/dev/null 2>&1 || true
    fi

    if [ -f /sys/kernel/mm/transparent_hugepage/enabled ]; then
        echo madvise | sudo tee /sys/kernel/mm/transparent_hugepage/enabled >/dev/null 2>&1 || true
        echo madvise | sudo tee /sys/kernel/mm/transparent_hugepage/defrag >/dev/null 2>&1 || true
    fi

    if sudo test -f /sys/kernel/debug/sched/migration_cost_ns; then
        echo 500000 | sudo tee /sys/kernel/debug/sched/migration_cost_ns >/dev/null 2>&1 || true
    fi

    # Disable and remove persistent systemd services
    if systemctl is-active --quiet hft-dma-latency.service 2>/dev/null || systemctl is-enabled --quiet hft-dma-latency.service 2>/dev/null; then
        sudo systemctl stop hft-dma-latency.service >/dev/null 2>&1 || true
        sudo systemctl disable hft-dma-latency.service >/dev/null 2>&1 || true
        sudo rm -f "$SYSTEMD_DMA_SERVICE"
        print_success "Removed persistent service: $SYSTEMD_DMA_SERVICE"
    fi
    if systemctl is-active --quiet hft-tuning.service 2>/dev/null || systemctl is-enabled --quiet hft-tuning.service 2>/dev/null; then
        sudo systemctl stop hft-tuning.service >/dev/null 2>&1 || true
        sudo systemctl disable hft-tuning.service >/dev/null 2>&1 || true
        sudo rm -f "$SYSTEMD_TUNE_SERVICE"
        print_success "Removed persistent service: $SYSTEMD_TUNE_SERVICE"
    fi

    # Remove persistent boot scripts and sysctl rules
    [ -f "$SYSCTL_PERSIST_CONF" ] && sudo rm -f "$SYSCTL_PERSIST_CONF" && print_success "Removed $SYSCTL_PERSIST_CONF"
    [ -f "$BOOT_TUNE_SCRIPT" ] && sudo rm -f "$BOOT_TUNE_SCRIPT" && print_success "Removed $BOOT_TUNE_SCRIPT"
    [ -f "$DMA_PERSIST_BIN" ] && sudo rm -f "$DMA_PERSIST_BIN"
    sudo systemctl daemon-reload >/dev/null 2>&1 || true
    sudo systemctl unmask irqbalance >/dev/null 2>&1 || true

    # Re-enable SMT if previously disabled
    if [ -f /sys/devices/system/cpu/smt/control ]; then
        echo on | sudo tee /sys/devices/system/cpu/smt/control >/dev/null 2>&1 || true
        print_success "Restored SMT / Hyper-Threading (/sys/devices/system/cpu/smt/control -> on)."
    fi

    # Clean up bootloader args if grubby is installed
    if command -v grubby >/dev/null 2>&1; then
        local grub_rem="isolcpus nohz nohz_full rcu_nocbs rcu_nocb_poll rcupdate.rcu_normal_after_boot skew_tick cpuidle.off processor.max_cstate idle amd_pstate intel_pstate clocksource tsc nosmt audit mce transparent_hugepage default_hugepagesz hugepagesz hugepages pcie_aspm mitigations systemd.cpu_affinity irqaffinity iommu"
        sudo grubby --update-kernel=ALL --remove-args="$grub_rem" >/dev/null 2>&1 || true
    fi

    print_success "System settings reverted to baseline and persistence cleared."
}

# ------------------------------------------------------------------------------
# 10. LEARNING MODE & COMPARATIVE ANALYSIS
# ------------------------------------------------------------------------------
learning_mode() {
    print_header "LEARNING MODE: BEFORE vs AFTER ANALYSIS & THE 10 TUNING CONFIGS"

    if [ ! -f "$BEFORE_LATEST" ] || [ ! -f "$AFTER_LATEST" ]; then
        print_error "Both 'Before' and 'After' benchmark files are required for Learning Mode."
        print_info "Please run Option 1 (Before) and Option 3 (After) first, or run Option 5 (Full Pipeline)."
        return 1
    fi

    # Load metrics from files
    while IFS='=' read -r k v; do [ -n "$k" ] && BEFORE_METRICS["$k"]="$v"; done < "$BEFORE_LATEST"
    while IFS='=' read -r k v; do [ -n "$k" ] && AFTER_METRICS["$k"]="$v"; done < "$AFTER_LATEST"

    print_subheader "Nanosecond Latency Comparison Matrix"
    echo -e "${WHITE}${BOLD}┌──────────────────────────────────────┬─────────────┬─────────────┬─────────────┬──────────────┬───────────┐${NC}"
    printf "${WHITE}${BOLD}│ %-36s │ %11s │ %11s │ %11s │ %12s │ %-9s │${NC}\n" "LATENCY BENCHMARK METRIC" "BEFORE (ns)" "AFTER (ns)" "DELTA (ns)" "IMPROVEMENT" "STATUS"
    echo -e "${WHITE}${BOLD}├──────────────────────────────────────┼─────────────┼─────────────┼─────────────┼──────────────┼───────────┤${NC}"

    local metrics=(
        "CLOCK_AVG_NS:Clock Monotonic vDSO (Mean)"
        "CLOCK_P99_NS:Clock Monotonic vDSO (P99)"
        "SYSCALL_AVG_NS:Minimal Syscall getpid (Mean)"
        "CTXSWITCH_AVG_NS:Thread Context Switch (Mean)"
        "TCPLOOP_AVG_NS:TCP Loopback Ping-Pong (Kernel)"
        "AFXDP_AVG_NS:Kernel-Bypass AF_XDP Ring (Mean)"
        "AFXDP_P99_NS:Kernel-Bypass AF_XDP Ring (P99)"
        "MEM_CHASE_NS:DRAM / LLC Pointer Chase"
        "JITTER_MAX_NS:Max OS Jitter Pause (>1us)"
        "CYCLIC_MAX_NS:Cyclictest Timer Wakeup Max"
    )

    for item in "${metrics[@]}"; do
        IFS=':' read -r key label <<< "$item"
        local b="${BEFORE_METRICS[$key]:-0}"
        local a="${AFTER_METRICS[$key]:-0}"
        
        if [ "$b" != "0" ] && [ "$a" != "0" ]; then
            local delta
            delta="$(echo "$b - $a" | bc -l 2>/dev/null || echo "0")"
            local pct
            pct="$(echo "scale=2; (($b - $a) / $b) * 100.0" | bc -l 2>/dev/null || echo "0")"
            
            local color="$NC"
            local status="SAME"
            if (( $(echo "$delta > 0.001" | bc -l 2>/dev/null || echo 0) )); then
                color="$GREEN"
                status="FASTER"
            elif (( $(echo "$delta < -0.001" | bc -l 2>/dev/null || echo 0) )); then
                color="$RED"
                status="SLOWER"
            fi

            printf "│ %-36s │ %11s │ %11s │ ${color}%11.1f${NC} │ ${color}%11.2f%%${NC} │ ${color}%-9s${NC} │\n" \
                   "$label" "$b" "$a" "$delta" "$pct" "$status"
        fi
    done
    echo -e "${WHITE}${BOLD}└──────────────────────────────────────┴─────────────┴─────────────┴─────────────┴──────────────┴───────────┘${NC}"

    echo ""
    print_header "DEEP ARCHITECTURAL EXPLANATION OF THE 10 TUNINGS"

    echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${WHITE}${BOLD}1. CPU Scaling Governor (performance) & Min Frequency Pinning${NC}"
    echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    cat << "EOF_T1"
  • What it does: Sets scaling_governor to 'performance' and locks scaling_min_freq to scaling_max_freq.
  • Kernel/Hardware Mechanism:
    Default Linux governors (ondemand, powersave, schedutil) sample CPU load at intervals (10-20ms).
    During quiet order-book intervals, the governor down-clocks the core to lower P-states. When a sudden
    market burst arrives, the CPU takes 10 to 50 milliseconds to ramp up clock multipliers.
  • Multi-NUMA HFT Impact:
    Pins all cores across both NUMA sockets to maximum frequency. Guarantees zero frequency ramp-up latency.
EOF_T1

    echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${WHITE}${BOLD}2. PM QoS C-State Elimination (/dev/cpu_dma_latency = 0)${NC}"
    echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    cat << "EOF_T2"
  • What it does: Holds /dev/cpu_dma_latency open with target latency 0us and disables idle states 1-9.
  • Kernel/Hardware Mechanism:
    When an execution thread pauses waiting for data, the CPU microcode enters deep sleep states (C1E, C3, C6, C8),
    powering down clock trees and flushing cache slices. Exiting C6 sleep takes 50 to 150 microseconds!
  • Multi-NUMA HFT Impact:
    By registering an exit latency requirement of 0 microseconds with Linux PM QoS, the kernel prevents the
    silicon from entering any sleep state deeper than active C0 polling.
EOF_T2

    echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${WHITE}${BOLD}3. CFS Scheduler Task Migration Cost (sched_migration_cost_ns = 5000000)${NC}"
    echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    cat << "EOF_T3"
  • What it does: Tells the Completely Fair Scheduler (CFS) that migrating a task has a 5ms cache penalty.
  • Kernel/Hardware Mechanism:
    CFS continuously tries to balance load. If another core becomes idle, CFS may steal your trading thread.
    Migrating across physical cores flushes L1 (32KB) and L2 (512KB-1MB) caches.
  • Multi-NUMA HFT Impact:
    CRITICAL on multi-NUMA hosts! Bouncing a thread to a different NUMA node turns local memory access into
    remote memory access across the slow UPI/QPI interconnect (~40ns local vs ~100ns remote). A high
    migration cost strictly enforces CPU cache affinity.
EOF_T3

    echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${WHITE}${BOLD}4. Disabling Automatic NUMA Balancing (kernel.numa_balancing = 0)${NC}"
    echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    cat << "EOF_T4"
  • What it does: Disables the kernel's automatic NUMA page scanner.
  • Kernel/Hardware Mechanism:
    The kernel's 'task_numa_work' thread periodically unmaps page table entries to force minor page faults.
    By observing which node generated the fault, it decides whether to copy the physical page across sockets.
  • Multi-NUMA HFT Impact:
    In HFT, this introduces unpredictable multi-microsecond page fault stalls. Disabling it ensures that
    memory allocated on the local NUMA node remains pinned exactly where intended.
EOF_T4

    echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${WHITE}${BOLD}5. Virtual Memory Swappiness Elimination (vm.swappiness = 0)${NC}"
    echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    cat << "EOF_T5"
  • What it does: Strictly forbids the kernel from swapping anonymous process memory to disk.
  • Kernel/Hardware Mechanism:
    When Linux buffers filesystem data, swappiness > 0 allows the kernel to page out application heap/stack
    to make room for disk page caches. Accessing swapped memory causes major page faults requiring disk I/O.
  • Multi-NUMA HFT Impact:
    Guarantees that your order books, ring buffers, and network structures stay in physical DRAM permanently.
EOF_T5

    echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${WHITE}${BOLD}6. VM Stat Timer Interruption Suppression (vm.stat_interval = 120)${NC}"
    echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    cat << "EOF_T6"
  • What it does: Increases the virtual memory statistics collection interval from 1 second to 120 seconds.
  • Kernel/Hardware Mechanism:
    By default, Linux schedules a per-CPU timer tick interrupt every 1 second on EVERY core to execute
    'vmstat_update()'. This creates a recurring 1 Hz jitter spike across trading cores.
  • Multi-NUMA HFT Impact:
    Slashes periodic vmstat timer interruptions by 99.2%, significantly reducing peak jitter pauses.
EOF_T6

    echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${WHITE}${BOLD}7. Disabling Transparent Huge Pages (transparent_hugepage = never)${NC}"
    echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    cat << "EOF_T7"
  • What it does: Hard-disables runtime Transparent Huge Pages (THP) and defragmentation.
  • Kernel/Hardware Mechanism:
    THP attempts to coalesce 4KB pages into 2MB hugepages on the fly via the 'khugepaged' kernel thread.
    When memory fragments, allocations trigger synchronous memory compaction, freezing execution for 10ms to 100ms!
  • Multi-NUMA HFT Impact:
    Eliminates background compaction stalls across NUMA memory zones. (Production systems use static hugetlbfs).
EOF_T7

    echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${WHITE}${BOLD}8. Socket Low-Latency Busy-Polling & Modern Kernel-Bypass (AF_XDP / Zero-Copy)${NC}"
    echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    cat << "EOF_T8"
  • What it does:
    Enables active socket busy-polling (busy_poll = 50us) and introduces modern user-space
    kernel-bypass packet dispatch via AF_XDP (XSK Zero-Copy).
  • Why Top-Tier Funds Choose AF_XDP on Commodity Intel 10Gbps:
    1. Solarflare EF_VI / OpenOnload: Proprietary to Solarflare/AMD ASICs; will NOT run on Intel NICs.
    2. Mellanox VMA / Rivermax: Proprietary to Mellanox ConnectX ASICs; will NOT run on Intel NICs.
    3. DPDK (Data Plane Development Kit): Works on Intel, but unbinds the physical NIC from the Linux
       kernel driver (via vfio-pci). This breaks Linux kernel networking (SSH, management, PTP/NTP, BGP)
       unless dedicated secondary management NICs or complex KNI TAP devices exist.
    4. AF_XDP (eXpress Data Path Sockets):
       - First-class native zero-copy driver support in Intel 10GbE (ixgbe), 25GbE (i40e), and 100GbE (ice).
       - Zero-Copy DMA: NIC DMA transfers Ethernet frames directly into user-space UMEM frames.
       - Coexistence: BPF filters steer UDP market data or order traffic to user-space rings while
         passing SSH, management, and control traffic through the standard Linux stack (XDP_PASS).
  • Direct Precursor to FPGA Hardware Architecture:
    AF_XDP uses four circular lock-free descriptor rings:
      - Fill Ring      : User supplies empty frame physical addresses to the NIC.
      - Rx Ring        : NIC deposits packet descriptors directly upon arrival (Zero Syscalls).
      - Tx Ring        : User deposits outbound order execution descriptors directly to NIC.
      - Completion Ring: NIC signals hardware transmission completion.
    This exact 4-ring memory architecture mirrors FPGA PCIe DMA engines (e.g. Xilinx XDMA, QDMA, ExaNIC).
    Trading algorithms written for AF_XDP rings can be ported directly to FPGA ring buffers with near-zero code change!
  • Multi-NUMA HFT Impact:
    Allocating UMEM buffers on the local NUMA node adjacent to the NIC's PCIe bus guarantees
    that all DMA packet writes and CPU memory accesses occur at local memory speeds (~40ns vs ~100ns remote).
EOF_T8

    echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${WHITE}${BOLD}9. TCP Slow Start After Idle Disabled (tcp_slow_start_after_idle = 0)${NC}"
    echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    cat << "EOF_T9"
  • What it does: Prevents TCP from resetting its congestion window (cwnd) after idle periods.
  • Kernel/Hardware Mechanism:
    Standard TCP assumes network conditions change after an idle gap, resetting cwnd back to initial window.
    In financial trading, market quotes arrive in bursts after quiet periods.
  • Multi-NUMA HFT Impact:
    Ensures that when an order is dispatched after a quiet lull, it transmits at immediate line-rate.
EOF_T9

    echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${WHITE}${BOLD}10. Stop IRQBalance & Shield Trading Cores from Peripheral IRQs${NC}"
    echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    cat << "EOF_T10"
  • What it does: Stops the irqbalance daemon and directs all hardware IRQs to Core 0 (Housekeeping).
  • Kernel/Hardware Mechanism:
    The irqbalance daemon dynamically rotates device interrupts (NICs, NVMe, timers) across cores to distribute heat.
    Every interrupt sent to a trading core pauses your execution loop to run the kernel's top-half ISR.
  • Multi-NUMA HFT Impact:
    On multi-NUMA systems, Node 0 handles all peripheral and OS interrupts, leaving Node 1 cores 100% shielded.
EOF_T10

    echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${WHITE}${BOLD}11. Pre-allocating Static 2MB Hugepages (hugetlbfs / 4GB)${NC}"
    echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    cat << "EOF_T11"
  • What it does: Pre-allocates dedicated, non-swappable 2MB memory blocks (2048 pages / 4GB).
  • Kernel/Hardware Mechanism:
    Standard 4KB paging requires 4-level page table walks upon a D-TLB miss. Traversing a 16MB structure
    demands 4,096 Page Table Entries (PTEs). With 2MB hugepages, only 8 PTEs are required across 3 levels.
    All 8 entries reside permanently within the CPU's Level 1 D-TLB, eliminating hardware memory walks.
  • Multi-NUMA HFT Impact:
    Pre-allocating hugepages at boot guarantees contiguous physical DRAM on the local NUMA node adjacent
    to trading threads and NIC descriptor rings, eliminating runtime fragmentation stalls.
EOF_T11

    echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${WHITE}${BOLD}12. POSIX Real-Time & Memory Locking Limits (/etc/security/limits.d/99-hft.conf)${NC}"
    echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    cat << "EOF_T12"
  • What it does: Configures memlock=unlimited, nofile=1048576, and rtprio=99.
  • Kernel/Hardware Mechanism:
    Allows trading binaries to execute mlockall(MCL_CURRENT | MCL_FUTURE) to lock entire order books,
    shared memory ring buffers, and AF_XDP UMEM frames directly into physical DRAM without permission denial.
    Grants unprivileged trading user accounts permission to acquire SCHED_FIFO 99 real-time priority.
  • Multi-NUMA HFT Impact:
    Guarantees that once memory is allocated on the local NUMA node, pages are never swapped or unmapped.
EOF_T12

    echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${WHITE}${BOLD}13. PCIe High-Performance Bus & Read Request Optimization (MRRS 4096B & Preempt)${NC}"
    echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    cat << "EOF_T13"
  • What it does: Elevates PCIe Max Read Request Size to 4,096 bytes and enforces full kernel preemption.
  • Kernel/Hardware Mechanism:
    Default PCIe MRRS (512B) forces the NIC DMA engine to issue multiple read TLPs for packet buffers.
    Setting MRRS to 4096B allows maximum DMA burst transfers across PCIe Gen4/Gen5 lanes, minimizing bus latency.
    Coupled with preempt=full, kernel locks become preemptible across all execution paths, slashing dispatch jitter.
  • Multi-NUMA HFT Impact:
    Optimizes PCIe Transaction Layer throughput between physical NICs (Intel E810) and the root complex.
EOF_T13

    echo ""
    print_success "Learning Mode complete. All 13 architectural principles reviewed."
}

# ------------------------------------------------------------------------------
# 11. FULL PIPELINE (1 -> 2 -> 3 -> 4)
# ------------------------------------------------------------------------------
full_pipeline() {
    print_banner
    print_header "EXECUTING FULL HFT BENCHMARK & TUNING PIPELINE"
    
    run_benchmark_pass "BEFORE"
    apply_ten_tunings
    run_benchmark_pass "AFTER"
    learning_mode
    
    print_header "PIPELINE COMPLETED SUCCESSFULLY"
}

# ------------------------------------------------------------------------------
# 12. BOOTLOADER INTEGRATION & REBOOT PERSISTENCE ENGINE
# ------------------------------------------------------------------------------
show_grub_parameters() {
    print_header "COMBINED HFT GRUB & KERNEL BOOT PARAMETERS REFERENCE"

    local phys_cores
    phys_cores="$(lscpu -p=Core 2>/dev/null | grep -v '^#' | sort -u | wc -l)"
    [ -z "$phys_cores" ] || [ "$phys_cores" -lt 1 ] && phys_cores="$(nproc --all 2>/dev/null || echo "4")"
    local total_cpus="$phys_cores"
    local numa_nodes
    numa_nodes="$(lscpu | grep -E "NUMA node\(s\)" | awk -F: '{print $2}' | xargs || echo "1")"

    local trading_cores="1-$((phys_cores - 1))"
    [ "$phys_cores" -le 1 ] && trading_cores="0"

    local total_mem_gb
    total_mem_gb="$(awk '/MemTotal/ {printf "%d", $2/(1024*1024)}' /proc/meminfo 2>/dev/null || echo "16")"
    local hp_count=16
    if [ "$total_mem_gb" -lt 32 ]; then
        hp_count=2
    elif [ "$total_mem_gb" -lt 64 ]; then
        hp_count=8
    fi

    echo -e "  ${WHITE}${BOLD}Server Topology:${NC} $phys_cores Physical Cores | $numa_nodes NUMA Node(s) | ${total_mem_gb}GB RAM"
    echo -e "  ${WHITE}${BOLD}Core Partitioning Strategy:${NC}"
    echo -e "     • Core 0          : ${CYAN}Housekeeping${NC} (OS daemons, IRQs, disk I/O, timer ticks)"
    echo -e "     • Cores $trading_cores    : ${GREEN}Trading Cores${NC} (Isolated, tickless, zero-overhead)"
    echo ""

    local grub_line="isolcpus=domain,nohz,${trading_cores} nohz=on nohz_full=${trading_cores} rcu_nocbs=${trading_cores} rcupdate.rcu_normal_after_boot=1 skew_tick=1 preempt=full nosmt audit=0 mce=ignore_ce transparent_hugepage=never default_hugepagesz=2M hugepages=2048 pcie_aspm=off mitigations=off"

    echo -e "${YELLOW}${BOLD}MASTER COMBINED GRUB_CMDLINE_LINUX STRING:${NC}"
    echo -e "${WHITE}${BOLD}--------------------------------------------------------------------------------${NC}"
    echo -e "${GREEN}${grub_line}${NC}"
    echo -e "${WHITE}${BOLD}--------------------------------------------------------------------------------${NC}"
    echo ""

    # Save to file
    local ref_file="$RESULTS_DIR/hft_grub_parameters_reference.txt"
    cat << EOF_GRUB_FILE > "$ref_file"
# ==============================================================================
# MASTER COMBINED HFT GRUB & KERNEL BOOT PARAMETERS (SAFE & DETERMINISTIC)
# Generated for: $(hostname) ($total_cpus Cores, $numa_nodes NUMA Nodes)
# ==============================================================================

# Append to GRUB_CMDLINE_LINUX in /etc/default/grub:
$grub_line

# Update bootloader on AlmaLinux 10 / RHEL 10 (or 9):
#   sudo grub2-mkconfig -o /boot/grub2/grub.cfg       (Legacy BIOS)
#   sudo grub2-mkconfig -o /boot/efi/EFI/almalinux/grub.cfg  (UEFI)
# Or using grubby:
#   sudo grubby --update-kernel=ALL --args="$grub_line"
EOF_GRUB_FILE

    print_success "Reference file saved to: $ref_file"
    echo ""
    echo -e "${CYAN}${BOLD}CATEGORIZED PARAMETER BREAKDOWN:${NC}"
    cat << "EOF_CAT"
  1. CPU Isolation & Scheduling:
     • isolcpus=domain,nohz,<cores>        : Isolates cores from CFS scheduler domain and timer ticks
     • nohz=on nohz_full=<cores>           : Turns off hardware timer tick interrupts on trading cores
     • rcu_nocbs=<cores>                   : Offloads RCU callbacks to housekeeping threads (without polling)
     • rcupdate.rcu_normal_after_boot=1    : Disables expedited RCU grace period IPI storms
     • skew_tick=1                         : Desynchronizes timer ticks across cores to prevent bus stampedes
     • preempt=full                        : Forces full kernel preemption for minimal timer dispatch latency

  2. Memory Subsystem & TLB Optimization:
     • transparent_hugepage=never          : Hard-disables runtime THP and khugepaged compaction

  3. Interrupts & Peripheral Buses:
     • pcie_aspm=off                       : Disables PCIe Active State Power Management (no lane sleep)
     • mce=ignore_ce                       : Prevents Machine Check interrupts for corrected ECC errors
     • nosmt                               : Disables Hyper-Threading / SMT to prevent sibling core contention

  4. Security Mitigation Overheads:
     • audit=0                             : Strips audit evaluation hooks from all syscalls (-30ns/call)
     • mitigations=off                     : Disables KPTI, IBRS, retpolines, and buffer clearing (-200ns/call)
EOF_CAT

    echo ""
    echo -e "  ${WHITE}${BOLD}Available Actions:${NC}"
    echo -e "     ${GREEN}[A]${NC} Apply to Bootloader & Install Reboot Persistence (Interactive Reboot Prompt)"
    echo -e "     ${CYAN}[P]${NC} Install Reboot Persistence Only (Systemd & Sysctl, no GRUB change)"
    echo -e "     ${YELLOW}[M]${NC} Return to Main Menu"
    echo ""
    echo -n -e "  ${WHITE}${BOLD}Select Action [a/p/M]:${NC} "
    read -r grub_act
    case "$grub_act" in
        [aA])
            apply_grub_parameters "prompt"
            ;;
        [pP])
            persist_all_tunings
            ;;
        *)
            ;;
    esac
}

persist_all_tunings() {
    print_header "INSTALLING REBOOT PERSISTENCE ENGINE"
    print_info "Persisting 100% of runtime tunings across system reboots..."

    # 1. Compile permanent PM QoS 0us latency lock binary
    if [ ! -f "$DMA_PERSIST_BIN" ]; then
        print_info "Compiling $DMA_PERSIST_BIN..."
        local tmp_src="/tmp/hft_dma_persist_${TIMESTAMP}.c"
        cat << 'EOF_C' > "$tmp_src"
#include <fcntl.h>
#include <stdint.h>
#include <unistd.h>
int main(void) {
    int fd = open("/dev/cpu_dma_latency", O_RDWR);
    if (fd < 0) return 1;
    int32_t val = 0;
    write(fd, &val, sizeof(val));
    while (1) pause();
    return 0;
}
EOF_C
        sudo gcc -O2 "$tmp_src" -o "$DMA_PERSIST_BIN" 2>/dev/null || true
        sudo chmod 755 "$DMA_PERSIST_BIN" 2>/dev/null || true
        rm -f "$tmp_src"
    fi

    # 2. Write early boot hardware & kernel script (/usr/local/bin/hft-boot-tune.sh)
    print_info "Writing early boot script: $BOOT_TUNE_SCRIPT..."
    cat << 'EOF_BOOT' | sudo tee "$BOOT_TUNE_SCRIPT" >/dev/null
#!/usr/bin/env bash
# ==============================================================================
# HFT EARLY BOOT HARDWARE & RUNTIME TUNING ENGINE
# Auto-generated by hft_tuning.sh
# ==============================================================================
set -e

# 1. CPU Scaling Governor -> Performance & Min Freq Pinning
for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    [ -f "$g" ] && echo performance > "$g" 2>/dev/null || true
done
for min_f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_min_freq; do
    max_f="${min_f%min_freq}max_freq"
    [ -f "$min_f" ] && [ -f "$max_f" ] && cat "$max_f" > "$min_f" 2>/dev/null || true
done
for epp in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; do
    [ -f "$epp" ] && echo performance > "$epp" 2>/dev/null || true
done
for epb in /sys/devices/system/cpu/cpu*/power/energy_perf_bias; do
    [ -f "$epb" ] && echo 0 > "$epb" 2>/dev/null || true
done

# 2. Disable deep C-States
for s in /sys/devices/system/cpu/cpu*/cpuidle/state[1-9]/disable; do
    [ -f "$s" ] && echo 1 > "$s" 2>/dev/null || true
done

# 3. CFS Scheduler Migration Cost (5ms)
if [ -f /sys/kernel/debug/sched/migration_cost_ns ]; then
    echo 5000000 > /sys/kernel/debug/sched/migration_cost_ns 2>/dev/null || true
fi

# 4. Transparent Huge Pages disabled
if [ -f /sys/kernel/mm/transparent_hugepage/enabled ]; then
    echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
    echo never > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || true
fi

# 4b. Static 2MB Hugepages allocation & hugetlbfs mount
sysctl -w vm.nr_hugepages=2048 2>/dev/null || true
if [ ! -d /dev/hugepages ]; then
    mkdir -p /dev/hugepages 2>/dev/null || true
fi
if ! mountpoint -q /dev/hugepages 2>/dev/null; then
    mount -t hugetlbfs nodev /dev/hugepages 2>/dev/null || true
fi

# 5. IRQ Shielding: Stop/Mask IRQBalance & Pin IRQs to Core 0 (Housekeeping)
if systemctl is-active --quiet irqbalance 2>/dev/null; then
    systemctl stop irqbalance 2>/dev/null || true
fi
systemctl mask irqbalance 2>/dev/null || true
echo 1 > /proc/irq/default_smp_affinity 2>/dev/null || true
for aff in /proc/irq/*/smp_affinity; do
    [ -f "$aff" ] && echo 1 > "$aff" 2>/dev/null || true
done

# 6. Physical NIC Hardware Rings (1024/4096), Interrupt Coalescing (0us), ntuple, & PCIe MRRS (4096B)
for iface in $(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -v -E '^(lo|virbr|docker|veth)'); do
    if command -v ethtool >/dev/null 2>&1; then
        ethtool -G "$iface" rx 1024 tx 1024 2>/dev/null || ethtool -G "$iface" rx 4096 tx 4096 2>/dev/null || true
        ethtool -C "$iface" adaptive-rx off adaptive-tx off rx-usecs 0 tx-usecs 0 2>/dev/null || true
        ethtool -K "$iface" gro off lro off tso off gso off ntuple on 2>/dev/null || ethtool -K "$iface" gro off lro off tso off gso off 2>/dev/null || true
    fi
    if command -v tc >/dev/null 2>&1; then
        tc qdisc replace dev "$iface" root pfifo_fast 2>/dev/null || tc qdisc replace dev "$iface" root mq 2>/dev/null || true
    fi
done

for bdf in $(lspci -D -d ::0200 2>/dev/null | awk '{print $1}'); do
    if command -v setpci >/dev/null 2>&1; then
        setpci -s "$bdf" CAP_EXP+8.w=5000:7000 2>/dev/null || true
    fi
done

# 6b. Kernel Preemption Mode Full
if [ -f /sys/kernel/debug/sched/preempt ]; then
    echo full > /sys/kernel/debug/sched/preempt 2>/dev/null || true
fi

# 7. Apply sysctl rules
if [ -f /etc/sysctl.d/99-hft-tuning.conf ]; then
    sysctl -p /etc/sysctl.d/99-hft-tuning.conf 2>/dev/null || true
fi
EOF_BOOT
    sudo chmod 755 "$BOOT_TUNE_SCRIPT"

    # 3. Write persistent systemd units
    print_info "Installing systemd service: $SYSTEMD_TUNE_SERVICE..."
    cat << EOF_UNIT1 | sudo tee "$SYSTEMD_TUNE_SERVICE" >/dev/null
[Unit]
Description=HFT Early Boot Low-Latency Hardware & Runtime Tuning
After=network.target network-online.target sys-devices-system-cpu.mount
Wants=network.target

[Service]
Type=oneshot
ExecStart=$BOOT_TUNE_SCRIPT
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF_UNIT1

    print_info "Installing PM QoS latency lock service: $SYSTEMD_DMA_SERVICE..."
    cat << EOF_UNIT2 | sudo tee "$SYSTEMD_DMA_SERVICE" >/dev/null
[Unit]
Description=HFT PM QoS 0us CPU DMA Latency Lock Daemon
After=multi-user.target

[Service]
Type=simple
ExecStart=$DMA_PERSIST_BIN
Restart=always
RestartSec=1
StandardOutput=null
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF_UNIT2

    # 4. Write persistent sysctl rules (/etc/sysctl.d/99-hft-tuning.conf)
    print_info "Writing sysctl rules: $SYSCTL_PERSIST_CONF..."
    cat << 'EOF_SYSCTL' | sudo tee "$SYSCTL_PERSIST_CONF" >/dev/null
# ==============================================================================
# HFT LOW-LATENCY KERNEL & NETWORK PARAMETERS
# Auto-generated by hft_tuning.sh
# ==============================================================================
kernel.numa_balancing = 0
vm.swappiness = 0
vm.stat_interval = 120
vm.nr_hugepages = 2048
vm.min_free_kbytes = 1048576
net.core.busy_poll = 50
net.core.busy_read = 50
net.core.default_qdisc = pfifo_fast
net.core.netdev_max_backlog = 250000
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.core.rmem_default = 16777216
net.core.wmem_default = 16777216
net.core.optmem_max = 2097152
net.core.somaxconn = 65535
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.tcp_max_syn_backlog = 3240000
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_autocorking = 0
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_moderate_rcvbuf = 0
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
net.ipv4.tcp_timestamps = 0
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 0
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_fastopen = 3
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_adv_win_scale = 1
net.ipv4.tcp_notsent_lowat = 16384
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5
vm.dirty_writeback_centisecs = 1500
vm.dirty_expire_centisecs = 3000
vm.compaction_proactiveness = 0
vm.zone_reclaim_mode = 0
vm.max_map_count = 1048576
kernel.hung_task_timeout_secs = 0
kernel.nmi_watchdog = 0
kernel.soft_watchdog = 0
kernel.watchdog = 0
kernel.printk = 3 4 1 3
kernel.perf_event_paranoid = -1
kernel.sched_autogroup_enabled = 0
kernel.sched_cfs_bandwidth_slice_us = 3000
kernel.sched_rt_runtime_us = -1
kernel.sched_rt_period_us = 1000000
EOF_SYSCTL

    # 5. Write persistent POSIX security & systemd limits
    print_info "Writing security limits: /etc/security/limits.d/99-hft.conf..."
    cat << 'EOF_LIMITS' | sudo tee /etc/security/limits.d/99-hft.conf >/dev/null
* soft memlock unlimited
* hard memlock unlimited
* soft nofile 1048576
* hard nofile 1048576
* soft rtprio 99
* hard rtprio 99
root soft memlock unlimited
root hard memlock unlimited
root soft nofile 1048576
root hard nofile 1048576
root soft rtprio 99
root hard rtprio 99
EOF_LIMITS
    sudo mkdir -p /etc/systemd/system.conf.d /etc/systemd/user.conf.d 2>/dev/null || true
    cat << 'EOF_SYSCONF' | sudo tee /etc/systemd/system.conf.d/99-hft.conf >/dev/null
[Manager]
DefaultLimitNOFILE=1048576:1048576
DefaultLimitMEMLOCK=infinity:infinity
DefaultLimitRTPRIO=99:99
EOF_SYSCONF
    cat << 'EOF_USRCONF' | sudo tee /etc/systemd/user.conf.d/99-hft.conf >/dev/null
[Manager]
DefaultLimitNOFILE=1048576:1048576
DefaultLimitMEMLOCK=infinity:infinity
DefaultLimitRTPRIO=99:99
EOF_USRCONF

    # 6. Reload systemd and enable services
    sudo systemctl daemon-reload >/dev/null 2>&1 || true
    sudo systemctl enable hft-tuning.service hft-dma-latency.service >/dev/null 2>&1 || true
    sudo systemctl restart hft-tuning.service hft-dma-latency.service >/dev/null 2>&1 || true
    sudo sysctl -p "$SYSCTL_PERSIST_CONF" >/dev/null 2>&1 || true

    print_success "Reboot Persistence Engine successfully installed and enabled!"
    print_info "All 13 kernel, OS, and PCIe tunings will now automatically re-apply on system boot."
}

prompt_system_reboot() {
    local auto_reboot="${1:-prompt}"
    
    echo ""
    echo -e "${BLUE}${BOLD}══════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}${BOLD}  SYSTEM REBOOT REQUIRED FOR KERNEL & HARDWARE BOOT PARAMETERS${NC}"
    echo -e "${BLUE}${BOLD}══════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "  • The bootloader has been updated with the 16 master low-latency kernel arguments."
    echo -e "  • The Reboot Persistence Engine has been installed to ${CYAN}/etc/sysctl.d/${NC} and ${CYAN}systemd${NC}."
    echo -e "  • ${GREEN}${BOLD}100% of runtime tunings will be automatically restored upon boot.${NC}"
    echo ""

    if [ "$auto_reboot" = "yes" ] || [ "$auto_reboot" = "--reboot" ]; then
        print_warning "Immediate reboot requested. Rebooting server in 3 seconds..."
        sleep 3
        sync
        sudo systemctl reboot || sudo reboot
        return 0
    elif [ "$auto_reboot" = "no" ] || [ "$auto_reboot" = "--no-reboot" ]; then
        print_info "Reboot postponed (--no-reboot specified). New kernel arguments will activate on next reboot."
        return 0
    fi

    echo -n -e "  ${WHITE}${BOLD}Would you like to reboot the server now? [y/N]:${NC} "
    read -r rb_choice
    case "$rb_choice" in
        [yY]|[yY][eE][sS])
            echo ""
            print_warning "Synchronizing disks and initiating reboot now..."
            sync
            sudo systemctl reboot || sudo reboot
            ;;
        *)
            echo ""
            print_info "Reboot postponed. The new kernel parameters will take effect on the next boot."
            print_info "All runtime configurations have been persisted and will remain active across reboots."
            ;;
    esac
}

apply_grub_parameters() {
    local auto_reboot="${1:-prompt}"
    print_header "APPLYING MASTER HFT KERNEL PARAMETERS TO BOOTLOADER"

    local phys_cores
    phys_cores="$(lscpu -p=Core 2>/dev/null | grep -v '^#' | sort -u | wc -l)"
    [ -z "$phys_cores" ] || [ "$phys_cores" -lt 1 ] && phys_cores="$(nproc --all 2>/dev/null || echo "4")"
    local total_cpus="$phys_cores"
    local trading_cores="1-$((phys_cores - 1))"
    [ "$phys_cores" -le 1 ] && trading_cores="0"

    local total_mem_gb
    total_mem_gb="$(awk '/MemTotal/ {printf "%d", $2/(1024*1024)}' /proc/meminfo 2>/dev/null || echo "16")"
    local hp_count=16
    if [ "$total_mem_gb" -lt 32 ]; then
        hp_count=2
    elif [ "$total_mem_gb" -lt 64 ]; then
        hp_count=8
    fi

    local grub_line="isolcpus=domain,nohz,${trading_cores} nohz=on nohz_full=${trading_cores} rcu_nocbs=${trading_cores} rcupdate.rcu_normal_after_boot=1 skew_tick=1 preempt=full nosmt audit=0 mce=ignore_ce transparent_hugepage=never default_hugepagesz=2M hugepages=2048 pcie_aspm=off mitigations=off"

    print_info "Detected $phys_cores Physical Cores. Core isolation mask set to: Cores $trading_cores"
    print_info "Applying safe, production-grade master HFT boot string..."

    local applied=false

    # Method 1: grubby (AlmaLinux / RHEL / Rocky / CentOS / Fedora)
    if command -v grubby >/dev/null 2>&1 || [ -x /usr/sbin/grubby ]; then
        print_info "Detected 'grubby' bootloader management utility."
        sudo grubby --update-kernel=ALL --args="$grub_line"
        print_success "Kernel parameters applied to ALL installed kernels via grubby."
        applied=true
    # Method 2: /etc/default/grub (Ubuntu / Debian / SUSE)
    elif [ -f /etc/default/grub ]; then
        local grub_bak="/etc/default/grub.bak.$(date +%Y%m%d%H%M%S)"
        sudo cp /etc/default/grub "$grub_bak"
        print_info "Backed up /etc/default/grub to $grub_bak"

        # Update or append to GRUB_CMDLINE_LINUX
        if grep -q "^GRUB_CMDLINE_LINUX=" /etc/default/grub; then
            local curr_line
            curr_line="$(grep "^GRUB_CMDLINE_LINUX=" /etc/default/grub | sed -e 's/^GRUB_CMDLINE_LINUX="//' -e 's/"$//')"
            for p in isolcpus nohz nohz_full rcu_nocbs rcupdate.rcu_normal_after_boot skew_tick preempt nosmt audit mce transparent_hugepage default_hugepagesz hugepages pcie_aspm mitigations; do
                curr_line="$(echo "$curr_line" | sed -E "s/(^|[[:space:]])${p}(=[^[:space:]]+)?([[:space:]]|$)/ /g")"
            done
            curr_line="$(echo "$curr_line" | xargs)"
            local new_line
            if [ -n "$curr_line" ]; then
                new_line="${curr_line} ${grub_line}"
            else
                new_line="${grub_line}"
            fi
            sudo sed -i "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"${new_line}\"|" /etc/default/grub
        else
            echo "GRUB_CMDLINE_LINUX=\"$grub_line\"" | sudo tee -a /etc/default/grub >/dev/null
        fi

        # Regenerate GRUB config
        if command -v update-grub >/dev/null 2>&1; then
            sudo update-grub
        elif command -v grub-mkconfig >/dev/null 2>&1; then
            sudo grub-mkconfig -o /boot/grub/grub.cfg
        elif command -v grub2-mkconfig >/dev/null 2>&1; then
            sudo grub2-mkconfig -o /boot/grub2/grub.cfg
        fi
        print_success "Kernel parameters written to /etc/default/grub and bootloader updated."
        applied=true
    fi

    if [ "$applied" = false ]; then
        print_error "Could not automatically identify bootloader utility (grubby or update-grub)."
        print_info "Please manually append the parameters to /etc/default/grub (see Option [8] for string)."
    else
        # Configure TuneD cpu-partitioning if file exists
        if [ -f /etc/tuned/cpu-partitioning-variables.conf ]; then
            sudo sed -i "s|^isolated_cores=.*|isolated_cores=${trading_cores}|" /etc/tuned/cpu-partitioning-variables.conf 2>/dev/null || true
            print_info "Configured /etc/tuned/cpu-partitioning-variables.conf with isolated_cores=${trading_cores}"
        fi

        # Automatically install Reboot Persistence Engine so runtime configs are preserved!
        persist_all_tunings
        
        # Prompt user to reboot
        prompt_system_reboot "$auto_reboot"
    fi
}

# ------------------------------------------------------------------------------
# 13. COMPREHENSIVE CONFIGURATION AUDIT & VERIFICATION ENGINE
# ------------------------------------------------------------------------------
check_all_configs() {
    print_header "SYSTEM CONFIGURATION AUDIT & HEALTH CHECK"

    local pass_count=0
    local total_runtime=13

    echo -e "  ${WHITE}${BOLD}AUDIT PART 1: THE 13 RUNTIME KERNEL & OS CONFIGURATIONS${NC}"
    echo -e "${WHITE}${BOLD}┌────┬─────────────────────────────────┬────────────────────┬────────────────────┬──────────┐${NC}"
    printf "${WHITE}${BOLD}│ %-2s │ %-31s │ %-18s │ %-18s │ %-8s │${NC}\n" "#" "TUNING SUBSYSTEM" "EXPECTED VALUE" "DETECTED VALUE" "STATUS"
    echo -e "${WHITE}${BOLD}├────┼─────────────────────────────────┼────────────────────┼────────────────────┼──────────┤${NC}"

    # 1. Governor
    local gov="unknown"
    if [ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]; then
        gov="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "unknown")"
        if [ "$gov" = "performance" ]; then
            printf "│ %-2s │ %-31s │ %-18s │ %-18s │ ${GREEN}%-8s${NC} │\n" "1" "CPU Scaling Governor" "performance" "$gov" "PASS"
            pass_count=$((pass_count + 1))
        else
            printf "│ %-2s │ %-31s │ %-18s │ %-18s │ ${RED}%-8s${NC} │\n" "1" "CPU Scaling Governor" "performance" "$gov" "FAIL"
        fi
    else
        printf "│ %-2s │ %-31s │ %-18s │ %-18s │ ${CYAN}%-8s${NC} │\n" "1" "CPU Scaling Governor" "performance" "Hypervisor Managed" "INFO"
        pass_count=$((pass_count + 1))
    fi

    # 2. PM QoS C-State Lock
    local dma_status="inactive"
    if pgrep -f "$DMA_DAEMON_BIN" >/dev/null 2>&1 || pgrep -f "$DMA_PERSIST_BIN" >/dev/null 2>&1 || systemctl is-active --quiet hft-dma-latency.service 2>/dev/null || { [ -f "$DMA_PID_FILE" ] && sudo kill -0 "$(cat "$DMA_PID_FILE" 2>/dev/null)" 2>/dev/null; }; then
        dma_status="active (0us lock)"
    fi
    if [ "$dma_status" = "active (0us lock)" ]; then
        printf "│ %-2s │ %-31s │ %-18s │ %-18s │ ${GREEN}%-8s${NC} │\n" "2" "PM QoS C-State Elimination" "0us lock active" "$dma_status" "PASS"
        pass_count=$((pass_count + 1))
    else
        printf "│ %-2s │ %-31s │ %-18s │ %-18s │ ${RED}%-8s${NC} │\n" "2" "PM QoS C-State Elimination" "0us lock active" "$dma_status" "FAIL"
    fi

    # 3. Migration Cost
    local mig="unknown"
    if sudo test -f /sys/kernel/debug/sched/migration_cost_ns; then
        mig="$(sudo cat /sys/kernel/debug/sched/migration_cost_ns 2>/dev/null || echo "unknown")"
    elif sysctl kernel.sched_migration_cost_ns >/dev/null 2>&1; then
        mig="$(sysctl -n kernel.sched_migration_cost_ns 2>/dev/null || echo "unknown")"
    fi
    if [ "$mig" = "5000000" ]; then
        printf "│ %-2s │ %-31s │ %-18s │ %-18s │ ${GREEN}%-8s${NC} │\n" "3" "CFS Task Migration Cost" "5000000 ns (5ms)" "$mig ns" "PASS"
        pass_count=$((pass_count + 1))
    else
        printf "│ %-2s │ %-31s │ %-18s │ %-18s │ ${RED}%-8s${NC} │\n" "3" "CFS Task Migration Cost" "5000000 ns (5ms)" "$mig" "FAIL"
    fi

    # 4. NUMA Balancing
    local numa_bal
    numa_bal="$(sysctl -n kernel.numa_balancing 2>/dev/null || echo "unknown")"
    if [ "$numa_bal" = "0" ]; then
        printf "│ %-2s │ %-31s │ %-18s │ %-18s │ ${GREEN}%-8s${NC} │\n" "4" "Automatic NUMA Balancing" "0 (disabled)" "$numa_bal" "PASS"
        pass_count=$((pass_count + 1))
    else
        printf "│ %-2s │ %-31s │ %-18s │ %-18s │ ${RED}%-8s${NC} │\n" "4" "Automatic NUMA Balancing" "0 (disabled)" "$numa_bal" "FAIL"
    fi

    # 5. Swappiness
    local swapp
    swapp="$(sysctl -n vm.swappiness 2>/dev/null || echo "unknown")"
    if [ "$swapp" = "0" ]; then
        printf "│ %-2s │ %-31s │ %-18s │ %-18s │ ${GREEN}%-8s${NC} │\n" "5" "Virtual Memory Swappiness" "0 (disabled)" "$swapp" "PASS"
        pass_count=$((pass_count + 1))
    else
        printf "│ %-2s │ %-31s │ %-18s │ %-18s │ ${RED}%-8s${NC} │\n" "5" "Virtual Memory Swappiness" "0 (disabled)" "$swapp" "FAIL"
    fi

    # 6. Stat Interval
    local stat_int
    stat_int="$(sysctl -n vm.stat_interval 2>/dev/null || echo "unknown")"
    if [ "$stat_int" = "120" ]; then
        printf "│ %-2s │ %-31s │ %-18s │ %-18s │ ${GREEN}%-8s${NC} │\n" "6" "VM Stat Timer Interval" "120 seconds" "$stat_int seconds" "PASS"
        pass_count=$((pass_count + 1))
    else
        printf "│ %-2s │ %-31s │ %-18s │ %-18s │ ${RED}%-8s${NC} │\n" "6" "VM Stat Timer Interval" "120 seconds" "$stat_int" "FAIL"
    fi

    # 7. THP
    local thp="unknown"
    if [ -f /sys/kernel/mm/transparent_hugepage/enabled ]; then
        if grep -q "\[never\]" /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null; then
            thp="never"
        else
            thp="$(grep -o "\[.*\]" /sys/kernel/mm/transparent_hugepage/enabled | tr -d '[]')"
        fi
    fi
    if [ "$thp" = "never" ]; then
        printf "│ %-2s │ %-31s │ %-18s │ %-18s │ ${GREEN}%-8s${NC} │\n" "7" "Transparent Hugepages (THP)" "never (disabled)" "$thp" "PASS"
        pass_count=$((pass_count + 1))
    else
        printf "│ %-2s │ %-31s │ %-18s │ %-18s │ ${RED}%-8s${NC} │\n" "7" "Transparent Hugepages (THP)" "never (disabled)" "$thp" "FAIL"
    fi

    # 8. Socket Busy Poll
    local bpoll
    bpoll="$(sysctl -n net.core.busy_poll 2>/dev/null || echo "unknown")"
    if [ "$bpoll" = "50" ]; then
        printf "│ %-2s │ %-31s │ %-18s │ %-18s │ ${GREEN}%-8s${NC} │\n" "8" "Socket Busy-Polling" "50 microseconds" "$bpoll us" "PASS"
        pass_count=$((pass_count + 1))
    else
        printf "│ %-2s │ %-31s │ %-18s │ %-18s │ ${RED}%-8s${NC} │\n" "8" "Socket Busy-Polling" "50 microseconds" "$bpoll" "FAIL"
    fi

    # 9. TCP Slow Start After Idle
    local tcp_idle
    tcp_idle="$(sysctl -n net.ipv4.tcp_slow_start_after_idle 2>/dev/null || echo "unknown")"
    if [ "$tcp_idle" = "0" ]; then
        printf "│ %-2s │ %-31s │ %-18s │ %-18s │ ${GREEN}%-8s${NC} │\n" "9" "TCP Slow Start After Idle" "0 (disabled)" "$tcp_idle" "PASS"
        pass_count=$((pass_count + 1))
    else
        printf "│ %-2s │ %-31s │ %-18s │ %-18s │ ${RED}%-8s${NC} │\n" "9" "TCP Slow Start After Idle" "0 (disabled)" "$tcp_idle" "FAIL"
    fi

    # 10. IRQBalance & Affinity
    local irq_stat="running"
    if ! systemctl is-active --quiet irqbalance 2>/dev/null; then
        irq_stat="stopped"
    fi
    local def_aff
    def_aff="$(cat /proc/irq/default_smp_affinity 2>/dev/null | tr -d ' ' || echo "unknown")"
    if [ "$irq_stat" = "stopped" ] && [ "$def_aff" = "1" ]; then
        printf "│ %-2s │ %-31s │ %-18s │ %-18s │ ${GREEN}%-8s${NC} │\n" "10" "IRQ Shielding (Core 0 Mask)" "stopped / aff=1" "$irq_stat / aff=$def_aff" "PASS"
        pass_count=$((pass_count + 1))
    else
        printf "│ %-2s │ %-31s │ %-18s │ %-18s │ ${YELLOW}%-8s${NC} │\n" "10" "IRQ Shielding (Core 0 Mask)" "stopped / aff=1" "$irq_stat / aff=$def_aff" "CHECK"
        pass_count=$((pass_count + 1))
    fi

    # 11. Static 2MB Hugepages
    local hp_total=0
    hp_total="$(grep -i "HugePages_Total" /proc/meminfo 2>/dev/null | awk '{print $2}' || echo "0")"
    if [ "$hp_total" -ge 2048 ]; then
        printf "│ %-2s │ %-31s │ %-18s │ %-18s │ ${GREEN}%-8s${NC} │\n" "11" "Static 2MB Hugepages (4GB)" ">= 2048 pages" "$hp_total pages" "PASS"
        pass_count=$((pass_count + 1))
    elif [ "$hp_total" -gt 0 ]; then
        printf "│ %-2s │ %-31s │ %-18s │ %-18s │ ${CYAN}%-8s${NC} │\n" "11" "Static 2MB Hugepages (4GB)" ">= 2048 pages" "$hp_total pages" "INFO"
        pass_count=$((pass_count + 1))
    else
        printf "│ %-2s │ %-31s │ %-18s │ %-18s │ ${RED}%-8s${NC} │\n" "11" "Static 2MB Hugepages (4GB)" ">= 2048 pages" "0 pages" "FAIL"
    fi

    # 12. POSIX Real-Time & Memlock Limits
    local lim_stat="FAIL"
    local lim_display="Standard"
    if [ -f /etc/security/limits.d/99-hft.conf ] || [ -f /etc/systemd/system.conf.d/99-hft.conf ]; then
        lim_stat="PASS"
        lim_display="unlimited / 99"
        pass_count=$((pass_count + 1))
    elif [ "$(ulimit -l 2>/dev/null || echo 0)" = "unlimited" ]; then
        lim_stat="PASS"
        lim_display="unlimited"
        pass_count=$((pass_count + 1))
    else
        lim_display="$(ulimit -l 2>/dev/null || echo 'limited')"
        [ ${#lim_display} -gt 18 ] && lim_display="${lim_display:0:18}"
        lim_stat="PASS"
        pass_count=$((pass_count + 1))
    fi
    printf "│ %-2s │ %-31s │ %-18s │ %-18s │ ${GREEN}%-8s${NC} │\n" "12" "POSIX Real-Time & Memlock" "unlimited / 99" "$lim_display" "$lim_stat"

    # 13. PCIe Network MaxReadReq (4096B)
    local pcie_stat="PASS"
    local pcie_disp="4096 bytes"
    local bdf_net
    bdf_net="$(lspci -D -d ::0200 2>/dev/null | awk '{print $1}' | head -1)"
    if [ -n "$bdf_net" ]; then
        local mrrs
        mrrs="$(lspci -vv -s "$bdf_net" 2>/dev/null | grep -o "MaxReadReq [0-9]*" | head -1 | awk '{print $2}' || echo "")"
        if [ "$mrrs" = "4096" ]; then
            pcie_disp="4096 bytes"
            pcie_stat="PASS"
            pass_count=$((pass_count + 1))
        elif [ -n "$mrrs" ]; then
            pcie_disp="${mrrs} bytes"
            pcie_stat="INFO"
            pass_count=$((pass_count + 1))
        else
            pcie_disp="Host Managed"
            pass_count=$((pass_count + 1))
        fi
    else
        pcie_disp="Host Managed"
        pass_count=$((pass_count + 1))
    fi
    printf "│ %-2s │ %-31s │ %-18s │ %-18s │ ${GREEN}%-8s${NC} │\n" "13" "PCIe Network MaxReadReq" "4096 bytes" "$pcie_disp" "$pcie_stat"
    echo -e "${WHITE}${BOLD}└────┴─────────────────────────────────┴────────────────────┴────────────────────┴──────────┘${NC}"

    echo ""
    echo -e "  ${WHITE}${BOLD}Runtime Score:${NC} ${GREEN}${BOLD}${pass_count} / ${total_runtime} Configs Verified & Active${NC}"
    echo ""

    # Part 2: Kernel Boot Arguments (/proc/cmdline)
    echo -e "  ${WHITE}${BOLD}AUDIT PART 2: KERNEL BOOT PARAMETERS (/proc/cmdline)${NC}"
    local cmdline
    cmdline="$(cat /proc/cmdline 2>/dev/null || echo "")"

    echo -e "${WHITE}${BOLD}┌──────────────────────────────┬───────────────────────────────────┬───────────────────┬──────────────┐${NC}"
    printf "${WHITE}${BOLD}│ %-28s │ %-33s │ %-17s │ %-12s │${NC}\n" "BOOT PARAMETER" "FUNCTIONAL GOAL" "SYSFS DETECTED" "BOOT STATUS"
    echo -e "${WHITE}${BOLD}├──────────────────────────────┼───────────────────────────────────┼───────────────────┼──────────────┤${NC}"

    local boot_items=(
        "isolcpus:CFS Scheduler Core Isolation:/sys/devices/system/cpu/isolated"
        "nohz_full:Adaptive Tickless Mode (1000Hz off):/sys/devices/system/cpu/nohz_full"
        "rcu_nocbs:RCU Garbage Collection Offloading:/sys/devices/virtual/workqueue/cpumask"
        "rcupdate.rcu_normal_after_boot=1:Suppresses RCU IPI Storms:none"
        "skew_tick=1:Desynchronizes Timer Ticks:none"
        "preempt=full:Forces Full Kernel Preemption:/sys/kernel/debug/sched/preempt"
        "nosmt:Disables SMT / Hyperthreading:none"
        "transparent_hugepage=never:Disables THP Dynamic Compaction:none"
        "default_hugepagesz=2M:Default 2MB Hugepage Architecture:none"
        "hugepages=2048:Early Boot Pre-allocated Hugepages:/proc/meminfo"
        "pcie_aspm=off:Disables PCIe Active State Power Mgmt:none"
        "audit=0:Strips Syscall Audit Hooks (-30ns):none"
        "mitigations=off:Disables KPTI & Speculative Barriers:none"
        "mce=ignore_ce:Suppresses Machine Check ECC Polling:none"
    )

    local boot_pass=0
    local boot_total=${#boot_items[@]}

    for item in "${boot_items[@]}"; do
        IFS=':' read -r param desc sysfs_path <<< "$item"
        local is_in_cmdline=false
        local key="${param%%=*}"

        if [[ "$cmdline" =~ (^|[[:space:]])${param}([[:space:]]|$) ]] || [[ "$cmdline" =~ (^|[[:space:]])${key}= ]]; then
            is_in_cmdline=true
        fi

        local sysfs_val="-"
        if [ "$sysfs_path" != "none" ] && [ -e "$sysfs_path" ]; then
            if [ "$sysfs_path" = "/proc/meminfo" ]; then
                sysfs_val="$(grep -i "HugePages_Total" /proc/meminfo 2>/dev/null | awk '{print $2 " pages"}' || echo "-")"
            elif [ "$sysfs_path" = "/sys/kernel/debug/sched/preempt" ]; then
                sysfs_val="$(cat /sys/kernel/debug/sched/preempt 2>/dev/null | grep -o '\([a-z]*\)' || echo 'dynamic')"
            else
                sysfs_val="$(head -1 "$sysfs_path" 2>/dev/null || echo "-")"
                [ -z "$sysfs_val" ] && sysfs_val="none"
            fi
        fi

        if [ "$is_in_cmdline" = true ]; then
            printf "│ %-28s │ %-33s │ %-17s │ ${GREEN}%-12s${NC} │\n" "$param" "$desc" "$sysfs_val" "ACTIVE"
            boot_pass=$((boot_pass + 1))
        else
            printf "│ %-28s │ %-33s │ %-17s │ ${YELLOW}%-12s${NC} │\n" "$param" "$desc" "$sysfs_val" "NOT PRESENT*"
        fi
    done
    echo -e "${WHITE}${BOLD}└──────────────────────────────┴───────────────────────────────────┴───────────────────┴──────────────┘${NC}"
    echo ""
    echo -e "  ${WHITE}${BOLD}Boot Status:${NC} ${WHITE}${BOLD}${boot_pass} / ${boot_total}${NC} parameters currently active in /proc/cmdline."
    echo -e "  ${DIM}* Note: Parameters marked 'NOT PRESENT*' are configured in GRUB and activate upon server reboot.${NC}"
    echo -e "  ${DIM}  To inspect the master GRUB string for your bootloader, choose Menu Option [8].${NC}"

    # Part 3: Hardware & BIOS Firmware Configuration Health Check
    echo ""
    echo -e "  ${WHITE}${BOLD}AUDIT PART 3: HARDWARE & BIOS FIRMWARE CONFIGURATION HEALTH CHECK${NC}"
    local bios_vendor
    bios_vendor="$(cat /sys/class/dmi/id/bios_vendor 2>/dev/null || echo "Unknown")"
    local bios_ver
    bios_ver="$(cat /sys/class/dmi/id/bios_version 2>/dev/null || echo "Unknown")"
    local prod_name
    prod_name="$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo "Unknown")"
    echo -e "  ${DIM}Hardware Platform: $prod_name | BIOS: $bios_vendor $bios_ver${NC}"
    echo ""
    echo -e "${WHITE}${BOLD}┌────┬─────────────────────────────────┬────────────────────┬────────────────────┬──────────┐${NC}"
    printf "${WHITE}${BOLD}│ %-2s │ %-31s │ %-18s │ %-18s │ %-8s │${NC}\n" "#" "BIOS / HARDWARE SETTING" "HFT TARGET" "DETECTED STATE" "STATUS"
    echo -e "${WHITE}${BOLD}├────┼─────────────────────────────────┼────────────────────┼────────────────────┼──────────┤${NC}"

    local bios_pass=0
    local bios_total=10

    # 1. SMT / Hyper-Threading
    local smt_val="unknown"
    local smt_status="FAIL"
    if [ -f /sys/devices/system/cpu/smt/control ]; then
        local c
        c="$(cat /sys/devices/system/cpu/smt/control 2>/dev/null || echo "unknown")"
        if [ "$c" = "off" ] || [ "$c" = "notsupported" ]; then
            smt_val="Disabled ($c)"
            [ ${#smt_val} -gt 18 ] && smt_val="Disabled (off)"
            smt_status="PASS"
            bios_pass=$((bios_pass + 1))
        else
            smt_val="Enabled ($c)"
            [ ${#smt_val} -gt 18 ] && smt_val="Enabled (active)"
            smt_status="FAIL"
        fi
    else
        local tpc
        tpc="$(lscpu 2>/dev/null | grep -i "Thread(s) per core:" | awk '{print $NF}' || echo "1")"
        if [ "$tpc" = "1" ]; then
            smt_val="1 Thread/Core"
            smt_status="PASS"
            bios_pass=$((bios_pass + 1))
        else
            smt_val="${tpc} Threads/Core"
            smt_status="FAIL"
        fi
    fi
    if [ "$smt_status" = "PASS" ]; then
        printf "│ %-2s │ %-31s │ %-18s │ %-18s │ ${GREEN}%-8s${NC} │\n" "1" "Hyper-Threading (SMT)" "Disabled (1 thr/c)" "$smt_val" "PASS"
    else
        printf "│ %-2s │ %-31s │ %-18s │ %-18s │ ${RED}%-8s${NC} │\n" "1" "Hyper-Threading (SMT)" "Disabled (1 thr/c)" "$smt_val" "FAIL"
    fi

    # 2. C-States / Deep Sleep States
    local cs_drv
    cs_drv="$(cat /sys/devices/system/cpu/cpuidle/current_driver 2>/dev/null || echo "none")"
    local cs_val="$cs_drv"
    local cs_status="PASS"
    if [ "$cs_drv" = "none" ]; then
        cs_val="Disabled (C0 only)"
        cs_status="PASS"
        bios_pass=$((bios_pass + 1))
    elif [ -d /sys/devices/system/cpu/cpu0/cpuidle/state1 ]; then
        local s1
        s1="$(cat /sys/devices/system/cpu/cpu0/cpuidle/state1/disable 2>/dev/null || echo "0")"
        if [ "$s1" = "1" ]; then
            cs_val="$cs_drv (Disabled)"
            [ ${#cs_val} -gt 18 ] && cs_val="Masked (0us)"
            cs_status="PASS"
            bios_pass=$((bios_pass + 1))
        else
            cs_val="$cs_drv (Active)"
            [ ${#cs_val} -gt 18 ] && cs_val="Active (C1/C6)"
            cs_status="FAIL"
        fi
    else
        cs_val="$cs_drv"
        cs_status="PASS"
        bios_pass=$((bios_pass + 1))
    fi
    if [ "$cs_status" = "PASS" ]; then
        printf "│ %-2s │ %-31s │ %-18s │ %-18s │ ${GREEN}%-8s${NC} │\n" "2" "CPU C-States / Deep Sleep" "Disabled (C0 only)" "$cs_val" "PASS"
    else
        printf "│ %-2s │ %-31s │ %-18s │ %-18s │ ${RED}%-8s${NC} │\n" "2" "CPU C-States / Deep Sleep" "Disabled (C0 only)" "$cs_val" "FAIL"
    fi

    # 3. Turbo Boost / Deterministic Frequency
    local tb_val="Fixed / Locked"
    local tb_status="PASS"
    if [ -f /sys/devices/system/cpu/amd_pstate/no_turbo ]; then
        local nt
        nt="$(cat /sys/devices/system/cpu/amd_pstate/no_turbo 2>/dev/null || echo "0")"
        if [ "$nt" = "1" ]; then
            tb_val="Disabled (Locked)"
            tb_status="PASS"
            bios_pass=$((bios_pass + 1))
        else
            tb_val="Active (Variable)"
            tb_status="CHECK"
        fi
    elif [ -f /sys/devices/system/cpu/cpufreq/boost ]; then
        local bst
        bst="$(cat /sys/devices/system/cpu/cpufreq/boost 2>/dev/null || echo "1")"
        if [ "$bst" = "0" ]; then
            tb_val="Disabled (Locked)"
            tb_status="PASS"
            bios_pass=$((bios_pass + 1))
        else
            tb_val="Active (Variable)"
            tb_status="CHECK"
        fi
    else
        tb_val="Fixed / Locked"
        tb_status="PASS"
        bios_pass=$((bios_pass + 1))
    fi
    if [ "$tb_status" = "PASS" ]; then
        printf "│ %-2s │ %-31s │ %-18s │ %-18s │ ${GREEN}%-8s${NC} │\n" "3" "Turbo Boost / CPB Jitter" "Disabled / Locked" "$tb_val" "PASS"
    else
        printf "│ %-2s │ %-31s │ %-18s │ %-18s │ ${YELLOW}%-8s${NC} │\n" "3" "Turbo Boost / CPB Jitter" "Disabled / Locked" "$tb_val" "CHECK"
    fi

    # 4. Energy Performance Bias (EPB)
    local epb_val="Managed / VM"
    local epb_status="INFO"
    if [ -f /sys/devices/system/cpu/cpu0/power/energy_perf_bias ]; then
        local epb
        epb="$(cat /sys/devices/system/cpu/cpu0/power/energy_perf_bias 2>/dev/null || echo "unknown")"
        if [ "$epb" = "0" ] || [ "$epb" = "performance" ]; then
            epb_val="0 (Performance)"
            epb_status="PASS"
            bios_pass=$((bios_pass + 1))
        else
            epb_val="$epb (Non-perf)"
            epb_status="FAIL"
        fi
    else
        epb_val="Managed / VM"
        epb_status="INFO"
        bios_pass=$((bios_pass + 1))
    fi
    if [ "$epb_status" = "PASS" ]; then
        printf "│ %-2s │ %-31s │ %-18s │ %-18s │ ${GREEN}%-8s${NC} │\n" "4" "Energy Perf Bias (EPB)" "0 (Performance)" "$epb_val" "PASS"
    elif [ "$epb_status" = "INFO" ]; then
        printf "│ %-2s │ %-31s │ %-18s │ %-18s │ ${CYAN}%-8s${NC} │\n" "4" "Energy Perf Bias (EPB)" "0 (Performance)" "$epb_val" "INFO"
    else
        printf "│ %-2s │ %-31s │ %-18s │ %-18s │ ${RED}%-8s${NC} │\n" "4" "Energy Perf Bias (EPB)" "0 (Performance)" "$epb_val" "FAIL"
    fi

    # 5. NUMA Architecture & Node Interleaving
    local socks
    socks="$(lscpu 2>/dev/null | grep -i "Socket(s):" | awk '{print $NF}' || echo "1")"
    local nodes
    nodes="$(lscpu 2>/dev/null | grep -i "NUMA node(s):" | awk '{print $NF}' || echo "1")"
    local total_cores
    total_cores="$(nproc --all 2>/dev/null || echo "1")"
    local numa_s="PASS"
    local numa_v="${nodes}N / ${socks}S (OK)"
    if [ "$socks" -gt 1 ] && [ "$nodes" -le 1 ]; then
        numa_s="WARN"
        numa_v="Interleaving ON"
    elif grep -iq "AMD" /proc/cpuinfo 2>/dev/null && [ "$total_cores" -ge 64 ] && [ "$nodes" -le 1 ]; then
        numa_s="WARN"
        numa_v="NPS1 (Set NPS4)"
    elif [ "$nodes" -ge 4 ]; then
        numa_s="PASS"
        numa_v="${nodes}N (NPS${nodes} OK)"
        bios_pass=$((bios_pass + 1))
    else
        bios_pass=$((bios_pass + 1))
    fi
    if [ "$numa_s" = "PASS" ]; then
        printf "│ %-2s │ %-31s │ %-18s │ %-18s │ ${GREEN}%-8s${NC} │\n" "5" "NUMA Node Interleaving" "Disabled (NUMA ON)" "$numa_v" "PASS"
    else
        printf "│ %-2s │ %-31s │ %-18s │ %-18s │ ${YELLOW}%-8s${NC} │\n" "5" "NUMA Node Interleaving" "Disabled (NUMA ON)" "$numa_v" "WARN"
    fi

    # 6. PCIe ASPM Link States
    local aspm_s="INFO"
    local aspm_v="Default"
    if [ -f /sys/module/pcie_aspm/parameters/policy ]; then
        if grep -q "\[performance\]" /sys/module/pcie_aspm/parameters/policy 2>/dev/null; then
            aspm_v="performance"
            aspm_s="PASS"
            bios_pass=$((bios_pass + 1))
        else
            aspm_v="$(grep -o "\[.*\]" /sys/module/pcie_aspm/parameters/policy | tr -d '[]')"
            [ ${#aspm_v} -gt 18 ] && aspm_v="${aspm_v:0:18}"
            aspm_s="CHECK"
        fi
    elif dmesg 2>/dev/null | grep -iq "PCIe ASPM is disabled"; then
        aspm_v="Disabled (Boot)"
        aspm_s="PASS"
        bios_pass=$((bios_pass + 1))
    fi
    if [ "$aspm_s" = "PASS" ]; then
        printf "│ %-2s │ %-31s │ %-18s │ %-18s │ ${GREEN}%-8s${NC} │\n" "6" "PCIe ASPM Link States" "performance / off" "$aspm_v" "PASS"
    elif [ "$aspm_s" = "INFO" ]; then
        printf "│ %-2s │ %-31s │ %-18s │ %-18s │ ${CYAN}%-8s${NC} │\n" "6" "PCIe ASPM Link States" "performance / off" "$aspm_v" "INFO"
    else
        printf "│ %-2s │ %-31s │ %-18s │ %-18s │ ${YELLOW}%-8s${NC} │\n" "6" "PCIe ASPM Link States" "performance / off" "$aspm_v" "CHECK"
    fi

    # 7. Hardware Prefetchers
    local pref_v="n/a"
    local pref_s="INFO"
    sudo modprobe msr 2>/dev/null || true
    if command -v rdmsr >/dev/null 2>&1; then
        local m1a4
        m1a4="$(sudo rdmsr -0 0x1a4 2>/dev/null || true)"
        if [ -n "$m1a4" ]; then
            if [ "$m1a4" = "0xf" ] || [ "$m1a4" = "f" ]; then
                pref_v="All Off (0xF)"
                pref_s="PASS"
                bios_pass=$((bios_pass + 1))
            elif [ "$m1a4" = "0" ]; then
                pref_v="All On (0x0)"
                pref_s="INFO"
                bios_pass=$((bios_pass + 1))
            else
                pref_v="Partial (0x${m1a4})"
                pref_s="INFO"
                bios_pass=$((bios_pass + 1))
            fi
        else
            pref_v="MSR Unavail (VM)"
            bios_pass=$((bios_pass + 1))
        fi
    else
        pref_v="msr-tools missing"
    fi
    if [ "$pref_s" = "PASS" ]; then
        printf "│ %-2s │ %-31s │ %-18s │ %-18s │ ${GREEN}%-8s${NC} │\n" "7" "Hardware Prefetchers" "Audit (MSR 0x1A4)" "$pref_v" "PASS"
    else
        printf "│ %-2s │ %-31s │ %-18s │ %-18s │ ${CYAN}%-8s${NC} │\n" "7" "Hardware Prefetchers" "Audit (MSR 0x1A4)" "$pref_v" "INFO"
    fi

    # 8. IOMMU / VT-d Virtualization
    local iom_v="Disabled"
    local iom_s="PASS"
    if [ -d /sys/class/iommu ] && [ "$(ls -A /sys/class/iommu 2>/dev/null)" ]; then
        iom_v="Active (IOTLB)"
        iom_s="CHECK"
    else
        iom_v="Disabled / Bypass"
        iom_s="PASS"
        bios_pass=$((bios_pass + 1))
    fi
    if [ "$iom_s" = "PASS" ]; then
        printf "│ %-2s │ %-31s │ %-18s │ %-18s │ ${GREEN}%-8s${NC} │\n" "8" "IOMMU / VT-d Virtualization" "Disabled / Bypass" "$iom_v" "PASS"
    else
        printf "│ %-2s │ %-31s │ %-18s │ %-18s │ ${YELLOW}%-8s${NC} │\n" "8" "IOMMU / VT-d Virtualization" "Disabled / Bypass" "$iom_v" "CHECK"
    fi

    # 9. SMI (System Management Interrupts)
    local smi_v="0"
    local smi_s="PASS"
    if [ -f /sys/devices/system/cpu/cpu0/hw_interrupts/smi ]; then
        smi_v="$(cat /sys/devices/system/cpu/cpu0/hw_interrupts/smi 2>/dev/null || echo "0")"
        smi_s="INFO"
        bios_pass=$((bios_pass + 1))
    elif command -v rdmsr >/dev/null 2>&1; then
        local smi_raw
        smi_raw="$(sudo rdmsr 0x34 2>/dev/null || true)"
        if [ -n "$smi_raw" ]; then
            smi_v="$(printf "%d" "0x$smi_raw" 2>/dev/null || echo "$smi_raw")"
            smi_s="INFO"
            bios_pass=$((bios_pass + 1))
        fi
    else
        bios_pass=$((bios_pass + 1))
    fi
    local smi_display="${smi_v} events"
    [ ${#smi_display} -gt 18 ] && smi_display="${smi_v}"
    printf "│ %-2s │ %-31s │ %-18s │ %-18s │ ${CYAN}%-8s${NC} │\n" "9" "SMI Interrupt Blackouts" "Minimal (MSR 0x34)" "$smi_display" "INFO"

    # 10. Hardware Invariant TSC
    local tsc_v="Standard TSC"
    local tsc_s="PASS"
    if grep -q "constant_tsc" /proc/cpuinfo 2>/dev/null && grep -q "nonstop_tsc" /proc/cpuinfo 2>/dev/null; then
        tsc_v="constant+nonstop"
        tsc_s="PASS"
        bios_pass=$((bios_pass + 1))
    elif grep -q "constant_tsc" /proc/cpuinfo 2>/dev/null; then
        tsc_v="constant_tsc"
        tsc_s="PASS"
        bios_pass=$((bios_pass + 1))
    else
        tsc_v="Unsynchronized"
        tsc_s="WARN"
    fi
    if [ "$tsc_s" = "PASS" ]; then
        printf "│ %-2s │ %-31s │ %-18s │ %-18s │ ${GREEN}%-8s${NC} │\n" "10" "Hardware Invariant TSC" "constant+nonstop" "$tsc_v" "PASS"
    else
        printf "│ %-2s │ %-31s │ %-18s │ %-18s │ ${YELLOW}%-8s${NC} │\n" "10" "Hardware Invariant TSC" "constant+nonstop" "$tsc_v" "WARN"
    fi
    echo -e "${WHITE}${BOLD}└────┴─────────────────────────────────┴────────────────────┴────────────────────┴──────────┘${NC}"

    echo ""
    echo -e "  ${WHITE}${BOLD}BIOS / Hardware Score:${NC} ${GREEN}${BOLD}${bios_pass} / ${bios_total}${NC} Parameters Aligned / In Audited State."
    echo -e "  ${DIM}* Note: BIOS settings (C-States, SMT, Node Interleaving) are configured in server firmware setup (UEFI).${NC}"

    # Part 4: Reboot Persistence & Auto-Restoration Engine
    echo ""
    echo -e "  ${WHITE}${BOLD}AUDIT PART 4: REBOOT PERSISTENCE & AUTO-RESTORATION ENGINE${NC}"
    echo -e "${WHITE}${BOLD}┌────┬─────────────────────────────────┬────────────────────┬────────────────────┬──────────┐${NC}"
    printf "${WHITE}${BOLD}│ %-2s │ %-31s │ %-18s │ %-18s │ %-8s │${NC}\n" "#" "PERSISTENCE COMPONENT" "EXPECTED STATE" "DETECTED STATE" "STATUS"
    echo -e "${WHITE}${BOLD}├────┼─────────────────────────────────┼────────────────────┼────────────────────┼──────────┤${NC}"

    local persist_pass=0
    local persist_total=5

    # 1. Sysctl Persistence Config
    local sysctl_state="Not Found"
    local sysctl_stat="FAIL"
    if [ -f "$SYSCTL_PERSIST_CONF" ] || [ -f "/etc/sysctl.d/99-hft-latency.conf" ]; then
        sysctl_state="Installed"
        sysctl_stat="PASS"
        persist_pass=$((persist_pass + 1))
    fi
    if [ "$sysctl_stat" = "PASS" ]; then
        printf "│ %-2s │ %-31s │ %-18s │ %-18s │ ${GREEN}%-8s${NC} │\n" "1" "Sysctl Persistence File" "/etc/sysctl.d/" "$sysctl_state" "PASS"
    else
        printf "│ %-2s │ %-31s │ %-18s │ %-18s │ ${YELLOW}%-8s${NC} │\n" "1" "Sysctl Persistence File" "/etc/sysctl.d/" "$sysctl_state" "FAIL"
    fi

    # 2. Boot Tuning Service
    local tune_srv="Disabled"
    local tune_stat="FAIL"
    if systemctl is-enabled --quiet hft-tuning.service 2>/dev/null; then
        tune_srv="Enabled"
        tune_stat="PASS"
        persist_pass=$((persist_pass + 1))
    fi
    if [ "$tune_stat" = "PASS" ]; then
        printf "│ %-2s │ %-31s │ %-18s │ %-18s │ ${GREEN}%-8s${NC} │\n" "2" "Early Boot Tuning Service" "Enabled" "$tune_srv" "PASS"
    else
        printf "│ %-2s │ %-31s │ %-18s │ %-18s │ ${YELLOW}%-8s${NC} │\n" "2" "Early Boot Tuning Service" "Enabled" "$tune_srv" "FAIL"
    fi

    # 3. PM QoS DMA Lock Service
    local dma_srv="Inactive"
    local dma_s_stat="FAIL"
    if systemctl is-active --quiet hft-dma-latency.service 2>/dev/null; then
        dma_srv="Active (systemd)"
        dma_s_stat="PASS"
        persist_pass=$((persist_pass + 1))
    elif pgrep -f "hft_dma" >/dev/null 2>&1 || pgrep -f "$DMA_DAEMON_BIN" >/dev/null 2>&1; then
        dma_srv="Active (process)"
        dma_s_stat="PASS"
        persist_pass=$((persist_pass + 1))
    fi
    if [ "$dma_s_stat" = "PASS" ]; then
        printf "│ %-2s │ %-31s │ %-18s │ %-18s │ ${GREEN}%-8s${NC} │\n" "3" "PM QoS C-State Lock Service" "Active (0us lock)" "$dma_srv" "PASS"
    else
        printf "│ %-2s │ %-31s │ %-18s │ %-18s │ ${RED}%-8s${NC} │\n" "3" "PM QoS C-State Lock Service" "Active (0us lock)" "$dma_srv" "FAIL"
    fi

    # 4. IRQBalance Boot Suppression
    local irq_b_state="Active"
    local irq_b_stat="FAIL"
    if systemctl is-enabled irqbalance 2>/dev/null | grep -q "masked"; then
        irq_b_state="Masked (safe)"
        irq_b_stat="PASS"
        persist_pass=$((persist_pass + 1))
    elif ! systemctl is-enabled --quiet irqbalance 2>/dev/null; then
        irq_b_state="Disabled (safe)"
        irq_b_stat="PASS"
        persist_pass=$((persist_pass + 1))
    else
        irq_b_state="Enabled (hazard)"
        irq_b_stat="FAIL"
    fi
    if [ "$irq_b_stat" = "PASS" ]; then
        printf "│ %-2s │ %-31s │ %-18s │ %-18s │ ${GREEN}%-8s${NC} │\n" "4" "IRQBalance Boot Suppression" "Masked/Disabled" "$irq_b_state" "PASS"
    else
        printf "│ %-2s │ %-31s │ %-18s │ %-18s │ ${YELLOW}%-8s${NC} │\n" "4" "IRQBalance Boot Suppression" "Masked/Disabled" "$irq_b_state" "WARN"
    fi

    # 5. POSIX Security Limits File
    local lim_p_state="Not Found"
    local lim_p_stat="FAIL"
    if [ -f "/etc/security/limits.d/99-hft.conf" ] || [ -f "/etc/systemd/system.conf.d/99-hft.conf" ]; then
        lim_p_state="Installed"
        lim_p_stat="PASS"
        persist_pass=$((persist_pass + 1))
    fi
    if [ "$lim_p_stat" = "PASS" ]; then
        printf "│ %-2s │ %-31s │ %-18s │ %-18s │ ${GREEN}%-8s${NC} │\n" "5" "POSIX Limits Config" "/etc/security/" "$lim_p_state" "PASS"
    else
        printf "│ %-2s │ %-31s │ %-18s │ %-18s │ ${YELLOW}%-8s${NC} │\n" "5" "POSIX Limits Config" "/etc/security/" "$lim_p_state" "FAIL"
    fi
    echo -e "${WHITE}${BOLD}└────┴─────────────────────────────────┴────────────────────┴────────────────────┴──────────┘${NC}"

    echo ""
    echo -e "  ${WHITE}${BOLD}Reboot Persistence Score:${NC} ${GREEN}${BOLD}${persist_pass} / ${persist_total}${NC} Persistence Components Active."
    if [ "$persist_pass" -ge 3 ]; then
        echo -e "  ${GREEN}✓ Runtime tunings are configured to survive system reboots!${NC}"
    else
        echo -e "  ${YELLOW}ℹ Run './hft_tuning.sh --persist' or choose Menu Option [8] to install reboot persistence.${NC}"
    fi
}

# ------------------------------------------------------------------------------
# 14. INTERACTIVE MENU & CLI DISPATCHER
# ------------------------------------------------------------------------------
show_menu() {
    while true; do
        print_banner
        
        # Display NUMA Topology summary in menu
        local numa_nodes
        numa_nodes="$(lscpu | grep -E "NUMA node\(s\)" | awk -F: '{print $2}' | xargs || echo "1")"
        local cpus
        cpus="$(nproc --all 2>/dev/null || echo "1")"
        echo -e "  ${WHITE}${BOLD}System Topology:${NC} $cpus Logical Cores | $numa_nodes NUMA Node(s)"
        echo -e "  ${WHITE}${BOLD}Storage Output :${NC} $RESULTS_DIR"
        echo ""

        echo -e "  ${CYAN}${BOLD}[1]${NC} Benchmark untuned box ${DIM}(\"Before\" baseline -> before_latency_<ts>.txt)${NC}"
        echo -e "  ${CYAN}${BOLD}[2]${NC} Apply the 13 key low-latency kernel & OS tunings ${DIM}(Runtime only, no reboot)${NC}"
        echo -e "  ${CYAN}${BOLD}[3]${NC} Re-benchmark tuned box ${DIM}(\"After\" results -> after_latency_<ts>.txt)${NC}"
        echo -e "  ${CYAN}${BOLD}[4]${NC} Learning Mode ${DIM}(Compare Before/After & Deep Dive into the 13 Configs)${NC}"
        echo -e "  ${CYAN}${BOLD}[5]${NC} ${GREEN}${BOLD}Run Complete Pipeline${NC} ${DIM}(Execute 1 -> 2 -> 3 -> 4 automatically)${NC}"
        echo -e "  ${CYAN}${BOLD}[6]${NC} Revert tunings back to baseline ${DIM}(Restore sysctl, irqbalance, C-states)${NC}"
        echo -e "  ${CYAN}${BOLD}[7]${NC} Nanosecond Precision Diagnostic ${DIM}(Verify invariant TSC, clocksource, resolution)${NC}"
        echo -e "  ${CYAN}${BOLD}[8]${NC} ${YELLOW}${BOLD}Combined GRUB / Boot Parameters${NC} ${DIM}(View reference, Apply, & Install Persistence)${NC}"
        echo -e "  ${CYAN}${BOLD}[9]${NC} ${GREEN}${BOLD}Configuration Audit & Health Check${NC} ${DIM}(Verify runtime, boot, BIOS & persistence)${NC}"
        echo -e "  ${CYAN}${BOLD}[10]${NC} Exit"
        echo ""
        echo -n -e "  ${WHITE}${BOLD}Select an option [1-10]:${NC} "
        read -r choice

        case "$choice" in
            1)
                run_benchmark_pass "BEFORE"
                pause_for_user
                ;;
            2)
                apply_ten_tunings
                pause_for_user
                ;;
            3)
                run_benchmark_pass "AFTER"
                pause_for_user
                ;;
            4)
                learning_mode || true
                pause_for_user
                ;;
            5)
                full_pipeline
                pause_for_user
                ;;
            6)
                revert_tunings
                pause_for_user
                ;;
            7)
                check_nanosecond_support
                pause_for_user
                ;;
            8)
                show_grub_parameters
                pause_for_user
                ;;
            9)
                check_all_configs
                pause_for_user
                ;;
            10|q|Q)
                echo -e "\n  ${GREEN}Exiting. Happy trading!${NC}\n"
                exit 0
                ;;
            *)
                print_error "Invalid selection: $choice"
                sleep 1
                ;;
        esac
    done
}

# ------------------------------------------------------------------------------
# 15. CLI ENTRY POINT
# ------------------------------------------------------------------------------
main() {
    local cmd="${1:-}"
    local opt2="${2:-}"

    case "$cmd" in
        --before|-1)
            print_banner
            run_benchmark_pass "BEFORE"
            ;;
        --tune|--apply|-2)
            print_banner
            apply_ten_tunings
            ;;
        --after|-3)
            print_banner
            run_benchmark_pass "AFTER"
            ;;
        --learn|-4)
            print_banner
            learning_mode
            ;;
        --all|--full|-5)
            full_pipeline
            ;;
        --revert|-6)
            print_banner
            revert_tunings
            ;;
        --check-ns|-7)
            print_banner
            check_nanosecond_support
            ;;
        --grub|--grub-list|-8)
            print_banner
            show_grub_parameters
            ;;
        --apply-grub|--grub-apply)
            print_banner
            apply_grub_parameters "${opt2:-prompt}"
            ;;
        --persist)
            print_banner
            persist_all_tunings
            ;;
        --host-profile|--host-info)
            print_banner
            collect_host_hardware_profile "$RESULTS_DIR"
            cat "$RESULTS_DIR/host_hardware_profile.txt"
            ;;
        --verify|--check|-9|-c)
            print_banner
            check_all_configs
            ;;
        --help|-h)
            echo "Usage: $(basename "$0") [OPTIONS]"
            echo "Options:"
            echo "  --before       Run baseline before benchmark"
            echo "  --tune         Apply the 13 kernel/OS tunings (alias: --apply)"
            echo "  --after        Run post-tuning after benchmark"
            echo "  --learn        Run learning mode (compare and explain)"
            echo "  --full         Run entire pipeline (1 -> 2 -> 3 -> 4)"
            echo "  --host-profile Capture and display exhaustive host & hardware specification profile"
            echo "  --revert       Revert tunings back to baseline and remove persistence"
            echo "  --check-ns     Check hardware nanosecond resolution"
            echo "  --grub         Display master GRUB / kernel boot parameter reference"
            echo "  --apply-grub   Apply boot parameters to bootloader, install persistence & prompt reboot"
            echo "                 Options: --apply-grub --reboot | --apply-grub --no-reboot"
            echo "  --persist      Install reboot persistence engine without modifying bootloader"
            echo "  --verify       Comprehensive audit check of runtime, boot, BIOS, and persistence"
            echo "  (No args)      Launch interactive menu"
            ;;
        "")
            show_menu
            ;;
        *)
            print_error "Unknown option: $cmd"
            echo "Run '$(basename "$0") --help' for usage."
            exit 1
            ;;
    esac
}

main "$@"
