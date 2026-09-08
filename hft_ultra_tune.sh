#!/usr/bin/env bash
# ==============================================================================
# HFT ULTRA-LOW-LATENCY LINUX TUNING & BENCHMARKING SUITE
# ==============================================================================
# Precision: Nanosecond (ns) resolution across all latency benchmarks
# Platform : AlmaLinux 9 / RHEL 9 / CentOS Stream / Debian / Ubuntu / Bare-Metal
# Author   : Google Antigravity Advanced Agentic Systems Architecture
# ==============================================================================

set -eo pipefail

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
# 2. RUNTIME ENVIRONMENT & FILE LOCATIONS
# ------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"

# Determine output directory
if [ -d "$HOME/results" ]; then
    OUT_DIR="$HOME/results"
elif [ -d "$SCRIPT_DIR/results" ]; then
    OUT_DIR="$SCRIPT_DIR/results"
else
    OUT_DIR="$HOME/results"
    mkdir -p "$OUT_DIR" 2>/dev/null || OUT_DIR="/tmp"
fi
mkdir -p "$OUT_DIR" 2>/dev/null || true

REPORT_BEFORE="$OUT_DIR/hft_before_report_${TIMESTAMP}.txt"
REPORT_TXT="$OUT_DIR/hft_tuning_report_${TIMESTAMP}.txt"
REPORT_JSON="$OUT_DIR/hft_tuning_report_${TIMESTAMP}.json"
LOG_FILE="$OUT_DIR/hft_tuning_${TIMESTAMP}.log"
BACKUP_SYSCTL="/tmp/sysctl_hft_backup_${TIMESTAMP}.conf"
BENCH_SRC="/tmp/hft_microbench_${TIMESTAMP}.c"
BENCH_BIN="/tmp/hft_microbench_${TIMESTAMP}"
DMA_DAEMON_SRC="/tmp/hft_dma_pm_qos_${TIMESTAMP}.c"
DMA_DAEMON_BIN="/tmp/hft_dma_pm_qos_${TIMESTAMP}"
DMA_DAEMON_PID_FILE="/tmp/hft_dma_pm_qos.pid"

# Duplicate all output to LOG_FILE while preserving terminal colors
exec > >(tee -a "$LOG_FILE") 2>&1

# ------------------------------------------------------------------------------
# 3. METRIC STORAGE ARRAYS
# ------------------------------------------------------------------------------
declare -A BEFORE_METRICS
declare -A AFTER_METRICS
declare -A IMPROVEMENTS
declare -A SYSTEM_INFO

# ------------------------------------------------------------------------------
# 4. LOGGING & OUTPUT UTILITIES
# ------------------------------------------------------------------------------
print_banner() {
    echo -e "${BLUE}${BOLD}"
    cat << "EOF_BANNER"
  ╔══════════════════════════════════════════════════════════════════════════╗
  ║    ⚡ HFT ULTRA-LOW-LATENCY KERNEL & SYSTEM OPTIMIZATION SUITE ⚡        ║
  ║               NANOSECOND BENCHMARK & TUNING ENGINE                       ║
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

print_metric_row() {
    local label="$1"
    local val="$2"
    local unit="${3:-}"
    printf "  %-32s : ${WHITE}${BOLD}%s${NC} %s\n" "$label" "$val" "$unit"
}

# ------------------------------------------------------------------------------
# 5. HARDWARE & ENVIRONMENT DISCOVERY
# ------------------------------------------------------------------------------
discover_system() {
    print_header "SYSTEM & TOPOLOGY DISCOVERY"

    SYSTEM_INFO["hostname"]="$(hostname)"
    SYSTEM_INFO["kernel"]="$(uname -r)"
    SYSTEM_INFO["arch"]="$(uname -m)"
    
    # OS Release
    if [ -f /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        SYSTEM_INFO["os_name"]="${PRETTY_NAME:-$NAME}"
    else
        SYSTEM_INFO["os_name"]="Linux Unknown"
    fi

    # Virtualization check
    local virt="Bare-Metal"
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        local detected
        detected="$(systemd-detect-virt 2>/dev/null || echo "none")"
        if [ "$detected" != "none" ]; then
            virt="Virtual ($detected)"
        fi
    elif [ -f /sys/hypervisor/type ]; then
        virt="Virtual ($(cat /sys/hypervisor/type))"
    fi
    SYSTEM_INFO["virt"]="$virt"

    # CPU information
    local cpu_model
    cpu_model="$(lscpu | grep -E "Model name" | awk -F: '{print $2}' | xargs || echo "Unknown CPU")"
    SYSTEM_INFO["cpu_model"]="$cpu_model"

    local cpus
    cpus="$(nproc --all 2>/dev/null || grep -c ^processor /proc/cpuinfo)"
    SYSTEM_INFO["cpus"]="$cpus"

    local sockets
    sockets="$(lscpu | grep -E "Socket\(s\)" | awk -F: '{print $2}' | xargs || echo "1")"
    SYSTEM_INFO["sockets"]="$sockets"

    local numa_nodes
    numa_nodes="$(lscpu | grep -E "NUMA node\(s\)" | awk -F: '{print $2}' | xargs || echo "1")"
    SYSTEM_INFO["numa_nodes"]="$numa_nodes"

    # Primary network interface
    local primary_iface
    primary_iface="$(ip route show default 2>/dev/null | awk '/default/ {print $5}' | head -1)"
    if [ -z "$primary_iface" ]; then
        primary_iface="$(ip -o link show | awk -F': ' '$2 !~ /lo|veth|docker|br-/ {print $2}' | head -1)"
    fi
    SYSTEM_INFO["primary_iface"]="${primary_iface:-unknown}"

    print_metric_row "Host Name" "${SYSTEM_INFO["hostname"]}"
    print_metric_row "Operating System" "${SYSTEM_INFO["os_name"]}"
    print_metric_row "Kernel Release" "${SYSTEM_INFO["kernel"]}"
    print_metric_row "Environment Type" "${SYSTEM_INFO["virt"]}"
    print_metric_row "CPU Architecture" "${SYSTEM_INFO["arch"]}"
    print_metric_row "Processor Model" "${SYSTEM_INFO["cpu_model"]}"
    print_metric_row "Logical Cores (vCPUs)" "${SYSTEM_INFO["cpus"]}"
    print_metric_row "Physical Sockets" "${SYSTEM_INFO["sockets"]}"
    print_metric_row "NUMA Nodes" "${SYSTEM_INFO["numa_nodes"]}"
    print_metric_row "Primary Network IF" "${SYSTEM_INFO["primary_iface"]}"
}

# ------------------------------------------------------------------------------
# 6. PREREQUISITE PACKAGE MANAGEMENT
# ------------------------------------------------------------------------------
ensure_dependencies() {
    print_subheader "Verifying Benchmark & Tuning Dependencies"
    
    local missing=()
    for tool in gcc make cyclictest numactl ethtool bc; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing+=("$tool")
        fi
    done

    if [ ${#missing[@]} -eq 0 ]; then
        print_success "All build tools and latency measurement utilities are installed."
        return 0
    fi

    print_info "Missing required dependencies: ${missing[*]}"
    print_info "Installing missing tools via package manager..."

    if command -v dnf >/dev/null 2>&1; then
        sudo dnf install -y gcc make numactl realtime-tests ethtool bc tuned >/dev/null 2>&1 || {
            print_error "Failed to install packages via dnf. Ensure repositories are accessible."
            exit 1
        }
    elif command -v apt-get >/dev/null 2>&1; then
        sudo apt-get update -qq >/dev/null 2>&1 || true
        sudo apt-get install -y -qq build-essential rt-tests numactl ethtool bc tuned >/dev/null 2>&1 || {
            print_error "Failed to install packages via apt-get."
            exit 1
        }
    else
        print_error "Unsupported package manager. Please install: gcc, make, cyclictest, numactl, ethtool, bc."
        exit 1
    fi

    print_success "Dependencies successfully installed and verified."
}

# ------------------------------------------------------------------------------
# 7. EMBEDDED C NANOSECOND MICROBENCHMARK ENGINE
# ------------------------------------------------------------------------------
build_microbenchmark() {
    print_subheader "Compiling High-Resolution Microbenchmark Suite"

    cat << 'EOF_C' > "$BENCH_SRC"
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
#include <x86intrin.h>
#include <errno.h>

static double tsc_ghz = 0.0;
static int target_core = 0;

static void pin_current_thread(int core_id) {
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
    if (tsc_ghz < 0.5) tsc_ghz = 2.0; // safe fallback
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
    double median;
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
    st.median = samples[n / 2];
    st.p90 = samples[(size_t)(n * 0.90)];
    st.p99 = samples[(size_t)(n * 0.99)];
    double sum = 0.0;
    for (size_t i = 0; i < n; i++) sum += samples[i];
    st.mean = sum / n;
    return st;
}

// 1. Clock monotonic
static void bench_clock_monotonic(LatencyStats *stats) {
    const int N = 300000;
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
    *stats = compute_stats(s, N);
    free(s);
}

// 2. Clock raw
static void bench_clock_raw(LatencyStats *stats) {
    const int N = 300000;
    double *s = malloc(N * sizeof(double));
    struct timespec ts;
    for (int i = 0; i < N; i++) {
        _mm_lfence();
        uint64_t t0 = _rdtsc();
        _mm_lfence();
        clock_gettime(CLOCK_MONOTONIC_RAW, &ts);
        _mm_lfence();
        uint64_t t1 = _rdtsc();
        s[i] = cycles_to_ns(t1 - t0);
    }
    *stats = compute_stats(s, N);
    free(s);
}

// 3. Syscall getpid
static void bench_syscall_getpid(LatencyStats *stats) {
    const int N = 150000;
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
    *stats = compute_stats(s, N);
    free(s);
}

// 4. Context switch via pipes
typedef struct {
    int p1[2];
    int p2[2];
    int iterations;
} PipeCtx;

static void *pipe_worker(void *arg) {
    PipeCtx *ctx = (PipeCtx *)arg;
    pin_current_thread(target_core);
    uint64_t val = 0;
    for (int i = 0; i < ctx->iterations; i++) {
        if (read(ctx->p1[0], &val, sizeof(val)) != sizeof(val)) break;
        if (write(ctx->p2[1], &val, sizeof(val)) != sizeof(val)) break;
    }
    return NULL;
}

static void bench_context_switch(LatencyStats *stats) {
    const int N = 15000;
    PipeCtx ctx;
    if (pipe(ctx.p1) < 0 || pipe(ctx.p2) < 0) return;
    ctx.iterations = N;

    pthread_t th;
    pthread_create(&th, NULL, pipe_worker, &ctx);

    double *s = malloc(N * sizeof(double));
    uint64_t val = 1;
    for (int i = 0; i < N; i++) {
        _mm_lfence();
        uint64_t t0 = _rdtsc();
        _mm_lfence();
        if (write(ctx.p1[1], &val, sizeof(val)) != sizeof(val)) break;
        if (read(ctx.p2[0], &val, sizeof(val)) != sizeof(val)) break;
        _mm_lfence();
        uint64_t t1 = _rdtsc();
        s[i] = cycles_to_ns(t1 - t0) / 2.0; // 2 switches per round-trip
    }
    pthread_join(th, NULL);
    close(ctx.p1[0]); close(ctx.p1[1]);
    close(ctx.p2[0]); close(ctx.p2[1]);

    *stats = compute_stats(s, N);
    free(s);
}

// 5. TCP Loopback Ping-Pong (64 Bytes)
typedef struct {
    int port;
    int iterations;
} NetCtx;

static void *tcp_server_thread(void *arg) {
    NetCtx *ctx = (NetCtx *)arg;
    pin_current_thread(target_core);
    int srv = socket(AF_INET, SOCK_STREAM, 0);
    int opt = 1;
    setsockopt(srv, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = htons(ctx->port);
    bind(srv, (struct sockaddr *)&addr, sizeof(addr));
    listen(srv, 1);

    int client = accept(srv, NULL, NULL);
    setsockopt(client, IPPROTO_TCP, TCP_NODELAY, &opt, sizeof(opt));
    int poll_val = 50;
    setsockopt(client, SOL_SOCKET, SO_BUSY_POLL, &poll_val, sizeof(poll_val));

    char buf[64];
    for (int i = 0; i < ctx->iterations; i++) {
        ssize_t r = recv(client, buf, sizeof(buf), MSG_WAITALL);
        if (r <= 0) break;
        send(client, buf, sizeof(buf), 0);
    }
    close(client);
    close(srv);
    return NULL;
}

static void bench_tcp_loopback(LatencyStats *stats) {
    const int N = 10000;
    int port = 26543;
    NetCtx ctx = { .port = port, .iterations = N };
    pthread_t th;
    pthread_create(&th, NULL, tcp_server_thread, &ctx);
    usleep(50000); // 50ms

    int sock = socket(AF_INET, SOCK_STREAM, 0);
    int opt = 1;
    setsockopt(sock, IPPROTO_TCP, TCP_NODELAY, &opt, sizeof(opt));
    int poll_val = 50;
    setsockopt(sock, SOL_SOCKET, SO_BUSY_POLL, &poll_val, sizeof(poll_val));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = htons(port);
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

    *stats = compute_stats(s, N);
    free(s);
}

// 6. UDP Loopback Ping-Pong (64 Bytes)
static void *udp_server_thread(void *arg) {
    NetCtx *ctx = (NetCtx *)arg;
    pin_current_thread(target_core);
    int srv = socket(AF_INET, SOCK_DGRAM, 0);
    int opt = 1;
    setsockopt(srv, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
    int poll_val = 50;
    setsockopt(srv, SOL_SOCKET, SO_BUSY_POLL, &poll_val, sizeof(poll_val));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = htons(ctx->port);
    bind(srv, (struct sockaddr *)&addr, sizeof(addr));

    char buf[64];
    struct sockaddr_in client_addr;
    socklen_t addrlen = sizeof(client_addr);

    for (int i = 0; i < ctx->iterations; i++) {
        ssize_t r = recvfrom(srv, buf, sizeof(buf), 0, (struct sockaddr *)&client_addr, &addrlen);
        if (r <= 0) break;
        sendto(srv, buf, sizeof(buf), 0, (struct sockaddr *)&client_addr, addrlen);
    }
    close(srv);
    return NULL;
}

static void bench_udp_loopback(LatencyStats *stats) {
    const int N = 10000;
    int port = 26544;
    NetCtx ctx = { .port = port, .iterations = N };
    pthread_t th;
    pthread_create(&th, NULL, udp_server_thread, &ctx);
    usleep(50000); // 50ms

    int sock = socket(AF_INET, SOCK_DGRAM, 0);
    int poll_val = 50;
    setsockopt(sock, SOL_SOCKET, SO_BUSY_POLL, &poll_val, sizeof(poll_val));

    struct sockaddr_in srv_addr;
    memset(&srv_addr, 0, sizeof(srv_addr));
    srv_addr.sin_family = AF_INET;
    srv_addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    srv_addr.sin_port = htons(port);

    char buf[64] = {0};
    double *s = malloc(N * sizeof(double));
    socklen_t addrlen = sizeof(srv_addr);

    for (int i = 0; i < N; i++) {
        _mm_lfence();
        uint64_t t0 = _rdtsc();
        _mm_lfence();
        sendto(sock, buf, sizeof(buf), 0, (struct sockaddr *)&srv_addr, addrlen);
        recvfrom(sock, buf, sizeof(buf), 0, NULL, NULL);
        _mm_lfence();
        uint64_t t1 = _rdtsc();
        s[i] = cycles_to_ns(t1 - t0);
    }
    close(sock);
    pthread_join(th, NULL);

    *stats = compute_stats(s, N);
    free(s);
}

// 7. UNIX Domain Socket Stream Ping-Pong (64 Bytes)
static void *uds_server_thread(void *arg) {
    NetCtx *ctx = (NetCtx *)arg;
    pin_current_thread(target_core);
    unlink("/tmp/hft_uds.sock");
    int srv = socket(AF_UNIX, SOCK_STREAM, 0);
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, "/tmp/hft_uds.sock", sizeof(addr.sun_path) - 1);
    bind(srv, (struct sockaddr *)&addr, sizeof(addr));
    listen(srv, 1);

    int client = accept(srv, NULL, NULL);
    char buf[64];
    for (int i = 0; i < ctx->iterations; i++) {
        ssize_t r = recv(client, buf, sizeof(buf), MSG_WAITALL);
        if (r <= 0) break;
        send(client, buf, sizeof(buf), 0);
    }
    close(client);
    close(srv);
    unlink("/tmp/hft_uds.sock");
    return NULL;
}

static void bench_uds_loopback(LatencyStats *stats) {
    const int N = 10000;
    NetCtx ctx = { .port = 0, .iterations = N };
    pthread_t th;
    pthread_create(&th, NULL, uds_server_thread, &ctx);
    usleep(50000); // 50ms

    int sock = socket(AF_UNIX, SOCK_STREAM, 0);
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, "/tmp/hft_uds.sock", sizeof(addr.sun_path) - 1);
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

    *stats = compute_stats(s, N);
    free(s);
}

// 8. Cache / Memory Pointer Chasing (Random 16MB)
static void bench_mem_pointer_chase(double *ns_per_access) {
    const size_t sz = 16 * 1024 * 1024 / sizeof(void *);
    void **arr = malloc(sz * sizeof(void *));
    size_t *indices = malloc(sz * sizeof(size_t));
    for (size_t i = 0; i < sz; i++) indices[i] = i;
    srand(12345);
    for (size_t i = sz - 1; i > 0; i--) {
        size_t j = rand() % (i + 1);
        size_t tmp = indices[i];
        indices[i] = indices[j];
        indices[j] = tmp;
    }
    for (size_t i = 0; i < sz - 1; i++) {
        arr[indices[i]] = (void *)&arr[indices[i + 1]];
    }
    arr[indices[sz - 1]] = (void *)&arr[indices[0]];
    free(indices);

    const int loops = 2000000;
    void **p = &arr[0];
    _mm_lfence();
    uint64_t t0 = _rdtsc();
    _mm_lfence();
    for (int i = 0; i < loops; i++) {
        p = (void **)*p;
    }
    _mm_lfence();
    uint64_t t1 = _rdtsc();
    _mm_lfence();

    if ((uintptr_t)p == 0xdeadbeef) printf("magic\n");
    *ns_per_access = cycles_to_ns(t1 - t0) / loops;
    free(arr);
}

// 9. Atomic CAS Contention
typedef struct {
    volatile uint64_t *val;
    int iterations;
} CasCtx;

static void *cas_worker(void *arg) {
    CasCtx *ctx = (CasCtx *)arg;
    pin_current_thread(target_core);
    for (int i = 0; i < ctx->iterations; i++) {
        uint64_t old;
        do {
            old = *ctx->val;
        } while (!__sync_bool_compare_and_swap(ctx->val, old, old + 1));
    }
    return NULL;
}

static void bench_atomic_cas(double *ns_per_op) {
    volatile uint64_t val = 0;
    const int N = 150000;
    CasCtx ctx = { .val = &val, .iterations = N };
    pthread_t th;
    _mm_lfence();
    uint64_t t0 = _rdtsc();
    _mm_lfence();
    pthread_create(&th, NULL, cas_worker, &ctx);
    cas_worker(&ctx);
    pthread_join(th, NULL);
    _mm_lfence();
    uint64_t t1 = _rdtsc();
    _mm_lfence();
    *ns_per_op = cycles_to_ns(t1 - t0) / (2 * N);
}

// 10. OS Jitter Spin-loop (1 second test)
static void bench_os_jitter(double *max_spike_ns, uint64_t *total_spikes) {
    const uint64_t duration_ns = 1000000000ULL; // 1 second
    uint64_t duration_cycles = (uint64_t)(duration_ns * tsc_ghz);
    uint64_t threshold_cycles = (uint64_t)(1000.0 * tsc_ghz); // 1000ns threshold
    
    uint64_t start = _rdtsc();
    uint64_t prev = start;
    uint64_t spikes = 0;
    uint64_t max_gap = 0;

    while (1) {
        _mm_lfence();
        uint64_t curr = _rdtsc();
        uint64_t delta = curr - prev;
        if (delta > threshold_cycles) {
            spikes++;
            if (delta > max_gap) max_gap = delta;
        }
        prev = curr;
        if (curr - start >= duration_cycles) break;
    }

    *max_spike_ns = cycles_to_ns(max_gap);
    *total_spikes = spikes;
}

int main(int argc, char **argv) {
    if (argc > 1) {
        target_core = atoi(argv[1]);
    }
    pin_current_thread(target_core);
    calibrate_tsc();
    printf("TSC_CALIBRATED_GHZ=%.4f\n", tsc_ghz);
    printf("PINNED_CORE=%d\n", target_core);

    LatencyStats clock_mono, clock_raw, sys_st, ctx_st, tcp_st, udp_st, uds_st;
    double mem_chase_ns = 0.0, cas_ns = 0.0, max_jitter_ns = 0.0;
    uint64_t total_spikes = 0;

    bench_clock_monotonic(&clock_mono);
    bench_clock_raw(&clock_raw);
    bench_syscall_getpid(&sys_st);
    bench_context_switch(&ctx_st);
    bench_tcp_loopback(&tcp_st);
    bench_udp_loopback(&udp_st);
    bench_uds_loopback(&uds_st);
    bench_mem_pointer_chase(&mem_chase_ns);
    bench_atomic_cas(&cas_ns);
    bench_os_jitter(&max_jitter_ns, &total_spikes);

    printf("CLOCK_MONO_MIN=%.1f\nCLOCK_MONO_AVG=%.1f\nCLOCK_MONO_P90=%.1f\nCLOCK_MONO_P99=%.1f\nCLOCK_MONO_MAX=%.1f\n",
           clock_mono.min, clock_mono.mean, clock_mono.p90, clock_mono.p99, clock_mono.max);
    printf("CLOCK_RAW_MIN=%.1f\nCLOCK_RAW_AVG=%.1f\nCLOCK_RAW_P90=%.1f\nCLOCK_RAW_P99=%.1f\nCLOCK_RAW_MAX=%.1f\n",
           clock_raw.min, clock_raw.mean, clock_raw.p90, clock_raw.p99, clock_raw.max);
    printf("SYSCALL_MIN=%.1f\nSYSCALL_AVG=%.1f\nSYSCALL_P90=%.1f\nSYSCALL_P99=%.1f\nSYSCALL_MAX=%.1f\n",
           sys_st.min, sys_st.mean, sys_st.p90, sys_st.p99, sys_st.max);
    printf("CTXSWITCH_MIN=%.1f\nCTXSWITCH_AVG=%.1f\nCTXSWITCH_P90=%.1f\nCTXSWITCH_P99=%.1f\nCTXSWITCH_MAX=%.1f\n",
           ctx_st.min, ctx_st.mean, ctx_st.p90, ctx_st.p99, ctx_st.max);
    printf("TCPLOOP_MIN=%.1f\nTCPLOOP_AVG=%.1f\nTCPLOOP_P90=%.1f\nTCPLOOP_P99=%.1f\nTCPLOOP_MAX=%.1f\n",
           tcp_st.min, tcp_st.mean, tcp_st.p90, tcp_st.p99, tcp_st.max);
    printf("UDPLOOP_MIN=%.1f\nUDPLOOP_AVG=%.1f\nUDPLOOP_P90=%.1f\nUDPLOOP_P99=%.1f\nUDPLOOP_MAX=%.1f\n",
           udp_st.min, udp_st.mean, udp_st.p90, udp_st.p99, udp_st.max);
    printf("UDSLOOP_MIN=%.1f\nUDSLOOP_AVG=%.1f\nUDSLOOP_P90=%.1f\nUDSLOOP_P99=%.1f\nUDSLOOP_MAX=%.1f\n",
           uds_st.min, uds_st.mean, uds_st.p90, uds_st.p99, uds_st.max);
    printf("MEM_CHASE_AVG=%.2f\n", mem_chase_ns);
    printf("CAS_CONTENTION_AVG=%.2f\n", cas_ns);
    printf("JITTER_SPIKES=%lu\nJITTER_MAX=%.1f\n", total_spikes, max_jitter_ns);

    return 0;
}
EOF_C

    gcc -O3 -march=native -pthread "$BENCH_SRC" -o "$BENCH_BIN" 2>/dev/null || \
    gcc -O3 -pthread "$BENCH_SRC" -o "$BENCH_BIN"
    
    chmod +x "$BENCH_BIN"
    print_success "Microbenchmark binary compiled at $BENCH_BIN"
}

# ------------------------------------------------------------------------------
# 8. PM QoS BACKGROUND DAEMON (Keeps /dev/cpu_dma_latency locked at 0)
# ------------------------------------------------------------------------------
build_dma_latency_daemon() {
    cat << 'EOF_DMA' > "$DMA_DAEMON_SRC"
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <unistd.h>

int main(void) {
    int fd = open("/dev/cpu_dma_latency", O_RDWR);
    if (fd < 0) return 1;
    int32_t target_latency = 0; // 0 microseconds
    if (write(fd, &target_latency, sizeof(target_latency)) != sizeof(target_latency)) {
        close(fd);
        return 1;
    }
    while (1) pause();
    return 0;
}
EOF_DMA

    gcc -O2 "$DMA_DAEMON_SRC" -o "$DMA_DAEMON_BIN" 2>/dev/null || true
}

start_dma_latency_lock() {
    if [ -f "$DMA_DAEMON_BIN" ] && [ -w /dev/cpu_dma_latency ]; then
        stop_dma_latency_lock
        sudo "$DMA_DAEMON_BIN" >/dev/null 2>&1 &
        local pid=$!
        echo "$pid" | sudo tee "$DMA_DAEMON_PID_FILE" >/dev/null 2>&1
        print_success "PM QoS exit latency locked to 0us via /dev/cpu_dma_latency (PID $pid)."
    fi
}

stop_dma_latency_lock() {
    if [ -f "$DMA_DAEMON_PID_FILE" ]; then
        local pid
        pid="$(cat "$DMA_DAEMON_PID_FILE" 2>/dev/null || true)"
        if [ -n "$pid" ]; then
            sudo kill "$pid" 2>/dev/null || true
        fi
        sudo rm -f "$DMA_DAEMON_PID_FILE" 2>/dev/null || true
    fi
}

# ------------------------------------------------------------------------------
# 9. BENCHMARK EXECUTION HARNESS
# ------------------------------------------------------------------------------
run_benchmarks() {
    local phase="$1" # "BEFORE" or "AFTER"
    print_header "RUNNING BENCHMARK SUITE: $phase TUNING (NANOSECOND RESOLUTION)"
    
    local bench_core="0"
    if [ "${SYSTEM_INFO["cpus"]}" -ge 2 ]; then
        bench_core="1"
    fi
    print_info "Executing microbenchmarks pinned to Core $bench_core..."

    local output
    output="$("$BENCH_BIN" "$bench_core")"

    # Parse and record key-value pairs
    while IFS='=' read -r key val; do
        if [ -n "$key" ] && [ -n "$val" ]; then
            if [ "$phase" = "BEFORE" ]; then
                BEFORE_METRICS["$key"]="$val"
            else
                AFTER_METRICS["$key"]="$val"
            fi
        fi
    done <<< "$output"

    # Run Cyclictest (Real-Time Timer Wakeup Latency in ns)
    print_info "Running cyclictest on Core $bench_core (25,000 cycles, 200us interval, prio 99, mlockall)..."
    local cyclic_out
    if [ "${SYSTEM_INFO["cpus"]}" -ge 2 ]; then
        cyclic_out="$(sudo cyclictest -m -p99 -i 200 -l 25000 -q -N -a "$bench_core" -t 1 2>/dev/null | tail -1 || true)"
    else
        cyclic_out="$(sudo cyclictest -m -p99 -i 200 -l 25000 -q -N 2>/dev/null | tail -1 || true)"
    fi
    
    local c_min="0" c_avg="0" c_max="0"
    if [[ "$cyclic_out" =~ Min:[[:space:]]*([0-9]+)[[:space:]]+Act:[[:space:]]*[0-9]+[[:space:]]+Avg:[[:space:]]*([0-9]+)[[:space:]]+Max:[[:space:]]*([0-9]+) ]]; then
        c_min="${BASH_REMATCH[1]}"
        c_avg="${BASH_REMATCH[2]}"
        c_max="${BASH_REMATCH[3]}"
    fi

    if [ "$phase" = "BEFORE" ]; then
        BEFORE_METRICS["CYCLIC_MIN"]="$c_min"
        BEFORE_METRICS["CYCLIC_AVG"]="$c_avg"
        BEFORE_METRICS["CYCLIC_MAX"]="$c_max"
    else
        AFTER_METRICS["CYCLIC_MIN"]="$c_min"
        AFTER_METRICS["CYCLIC_AVG"]="$c_avg"
        AFTER_METRICS["CYCLIC_MAX"]="$c_max"
    fi

    print_subheader "$phase State Nanosecond Measurements Summary"
    local m_ref="BEFORE_METRICS"
    [ "$phase" = "AFTER" ] && m_ref="AFTER_METRICS"

    eval "local clk_avg=\${${m_ref}[CLOCK_MONO_AVG]}"
    eval "local clk_p99=\${${m_ref}[CLOCK_MONO_P99]}"
    eval "local sys_avg=\${${m_ref}[SYSCALL_AVG]}"
    eval "local sys_p99=\${${m_ref}[SYSCALL_P99]}"
    eval "local ctx_avg=\${${m_ref}[CTXSWITCH_AVG]}"
    eval "local ctx_p99=\${${m_ref}[CTXSWITCH_P99]}"
    eval "local tcp_avg=\${${m_ref}[TCPLOOP_AVG]}"
    eval "local tcp_p99=\${${m_ref}[TCPLOOP_P99]}"
    eval "local udp_avg=\${${m_ref}[UDPLOOP_AVG]}"
    eval "local udp_p99=\${${m_ref}[UDPLOOP_P99]}"
    eval "local uds_avg=\${${m_ref}[UDSLOOP_AVG]}"
    eval "local uds_p99=\${${m_ref}[UDSLOOP_P99]}"
    eval "local mem_avg=\${${m_ref}[MEM_CHASE_AVG]}"
    eval "local cas_avg=\${${m_ref}[CAS_CONTENTION_AVG]}"
    eval "local jit_spk=\${${m_ref}[JITTER_SPIKES]}"
    eval "local jit_max=\${${m_ref}[JITTER_MAX]}"
    eval "local cyc_min=\${${m_ref}[CYCLIC_MIN]}"
    eval "local cyc_avg=\${${m_ref}[CYCLIC_AVG]}"
    eval "local cyc_max=\${${m_ref}[CYCLIC_MAX]}"

    print_metric_row "Clock Monotonic Latency" "$clk_avg" "ns (P99: ${clk_p99} ns)"
    print_metric_row "Minimal Syscall (getpid)" "$sys_avg" "ns (P99: ${sys_p99} ns)"
    print_metric_row "Thread Context Switch" "$ctx_avg" "ns (P99: ${ctx_p99} ns)"
    print_metric_row "TCP Loopback RTT (64B)" "$tcp_avg" "ns (P99: ${tcp_p99} ns)"
    print_metric_row "UDP Loopback RTT (64B)" "$udp_avg" "ns (P99: ${udp_p99} ns)"
    print_metric_row "UNIX Domain Socket RTT" "$uds_avg" "ns (P99: ${uds_p99} ns)"
    print_metric_row "LLC / Memory Pointer Chase" "$mem_avg" "ns / access"
    print_metric_row "Atomic CAS Contention" "$cas_avg" "ns / op"
    print_metric_row "OS Jitter Stalls (>1us)" "$jit_spk" "spikes (Max: ${jit_max} ns)"
    print_metric_row "Cyclictest Wakeup Jitter" "$cyc_avg" "ns (Min: ${cyc_min} ns, Max: ${cyc_max} ns)"

    # Save dedicated Before report if in BEFORE phase
    if [ "$phase" = "BEFORE" ]; then
        cat << EOF_BEF_RPT > "$REPORT_BEFORE"
================================================================================
           HFT BASELINE LATENCY BENCHMARK REPORT (BEFORE TUNING)
================================================================================
Timestamp   : $(date)
Host Name   : ${SYSTEM_INFO["hostname"]}
Platform    : ${SYSTEM_INFO["os_name"]} (${SYSTEM_INFO["virt"]})
Kernel      : ${SYSTEM_INFO["kernel"]} (${SYSTEM_INFO["arch"]})
CPU Model   : ${SYSTEM_INFO["cpu_model"]}
Topology    : ${SYSTEM_INFO["cpus"]} vCPUs / ${SYSTEM_INFO["sockets"]} Sockets / ${SYSTEM_INFO["numa_nodes"]} NUMA Nodes
Target Core : CPU $bench_core (Shielded Measurement Thread)
================================================================================

NANOSECOND LATENCY MEASUREMENTS:
  • Clock Monotonic Latency (vDSO)    : Mean=${clk_avg} ns | P99=${clk_p99} ns
  • Minimal Syscall (getpid)          : Mean=${sys_avg} ns | P99=${sys_p99} ns
  • Thread Context Switch (Pipe RTT/2): Mean=${ctx_avg} ns | P99=${ctx_p99} ns
  • TCP Loopback Ping-Pong (64B)      : Mean=${tcp_avg} ns | P99=${tcp_p99} ns
  • UDP Loopback Ping-Pong (64B)      : Mean=${udp_avg} ns | P99=${udp_p99} ns
  • UNIX Domain Socket Stream (64B)   : Mean=${uds_avg} ns | P99=${uds_p99} ns
  • LLC / Memory Pointer Chase        : Mean=${mem_avg} ns / dereference
  • Atomic CAS Contention             : Mean=${cas_avg} ns / atomic op
  • OS Jitter Spikes (>1000ns)        : Total=${jit_spk} | Max Spike=${jit_max} ns
  • Cyclictest Real-Time Wakeup       : Min=${cyc_min} ns | Mean=${cyc_avg} ns | Max=${cyc_max} ns
================================================================================
EOF_BEF_RPT
        print_success "Baseline Before report generated at: $REPORT_BEFORE"
    fi
}

# ------------------------------------------------------------------------------
# 10. COMPREHENSIVE HFT LINUX TUNING ENGINE
# ------------------------------------------------------------------------------
apply_hft_tuning() {
    print_header "APPLYING COMPREHENSIVE HFT SYSTEM & KERNEL OPTIMIZATIONS"

    # Backup current sysctl if not already backed up
    if [ ! -f "$BACKUP_SYSCTL" ]; then
        sudo sysctl -a > "$BACKUP_SYSCTL" 2>/dev/null || true
        print_info "Baseline sysctl backed up to $BACKUP_SYSCTL"
    fi

    # --------------------------------------------------------------------------
    # [1] CPU POWER, FREQUENCY & C-STATES
    # --------------------------------------------------------------------------
    print_subheader "[1/7] CPU Governors, Frequency Pinning & C-States"
    
    # 1. Scaling Governor -> performance
    local gov_changed=0
    for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        if [ -f "$g" ]; then
            echo "performance" | sudo tee "$g" >/dev/null 2>&1 || true
            gov_changed=1
        fi
    done
    if [ "$gov_changed" -eq 1 ]; then
        print_success "Scaling governor set to 'performance' on all CPU cores."
        IMPROVEMENTS["CPU Governor"]="Locked to 'performance' on all cores"
    else
        print_info "CPU scaling governors managed by hypervisor/host."
    fi

    # 2. Lock Min Freq to Max Freq
    for min_f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_min_freq; do
        local max_f="${min_f%min_freq}max_freq"
        if [ -f "$min_f" ] && [ -f "$max_f" ]; then
            sudo cat "$max_f" 2>/dev/null | sudo tee "$min_f" >/dev/null 2>&1 || true
        fi
    done

    # 3. Energy Performance Bias -> performance (0)
    if command -v x86_energy_perf_policy >/dev/null 2>&1; then
        sudo x86_energy_perf_policy performance >/dev/null 2>&1 || true
        IMPROVEMENTS["Energy Perf Bias"]="Configured to maximum performance"
    fi
    for epb in /sys/devices/system/cpu/cpu*/power/energy_perf_bias; do
        if [ -f "$epb" ]; then
            echo 0 | sudo tee "$epb" >/dev/null 2>&1 || true
        fi
    done

    # 4. Intel P-state turbo / energy preference
    if [ -d /sys/devices/system/cpu/intel_pstate ]; then
        echo 0 | sudo tee /sys/devices/system/cpu/intel_pstate/no_turbo >/dev/null 2>&1 || true
    fi

    # 5. Lock PM QoS via /dev/cpu_dma_latency to 0
    start_dma_latency_lock
    IMPROVEMENTS["PM QoS C-States"]="Locked exit latency to 0us via /dev/cpu_dma_latency"

    # 6. Disable deeper idle states (C1E, C3, C6, C7, C8)
    for state_disable in /sys/devices/system/cpu/cpu*/cpuidle/state[1-9]/disable; do
        if [ -f "$state_disable" ]; then
            echo 1 | sudo tee "$state_disable" >/dev/null 2>&1 || true
        fi
    done

    # 7. Disable NMI & Soft Watchdogs (eliminates periodic timer interrupts)
    sudo sysctl -w kernel.nmi_watchdog=0 >/dev/null 2>&1 || true
    sudo sysctl -w kernel.soft_watchdog=0 >/dev/null 2>&1 || true
    sudo sysctl -w kernel.watchdog=0 >/dev/null 2>&1 || true
    IMPROVEMENTS["NMI & Soft Watchdog"]="Disabled to eliminate periodic timer ticks"

    # --------------------------------------------------------------------------
    # [2] KERNEL SCHEDULER & REAL-TIME
    # --------------------------------------------------------------------------
    print_subheader "[2/7] Linux Kernel Scheduler & Real-Time Policies"
    
    # Mount debugfs if not mounted (needed for /sys/kernel/debug/sched)
    if ! mountpoint -q /sys/kernel/debug 2>/dev/null; then
        sudo mount -t debugfs none /sys/kernel/debug >/dev/null 2>&1 || true
    fi

    # Migration cost (5ms to prevent thrashing cache lines across cores)
    if [ -f /sys/kernel/debug/sched/migration_cost_ns ]; then
        echo 5000000 | sudo tee /sys/kernel/debug/sched/migration_cost_ns >/dev/null 2>&1 || true
    elif sysctl kernel.sched_migration_cost_ns >/dev/null 2>&1; then
        sudo sysctl -w kernel.sched_migration_cost_ns=5000000 >/dev/null 2>&1 || true
    fi
    IMPROVEMENTS["Migration Cost"]="Set to 5,000,000 ns (5ms) to enforce CPU cache affinity"

    # Sched min granularity & latency
    if [ -f /sys/kernel/debug/sched/min_granularity_ns ]; then
        echo 500000 | sudo tee /sys/kernel/debug/sched/min_granularity_ns >/dev/null 2>&1 || true
    fi
    if [ -f /sys/kernel/debug/sched/latency_ns ]; then
        echo 1000000 | sudo tee /sys/kernel/debug/sched/latency_ns >/dev/null 2>&1 || true
    fi
    if [ -f /sys/kernel/debug/sched/wakeup_granularity_ns ]; then
        echo 1000000 | sudo tee /sys/kernel/debug/sched/wakeup_granularity_ns >/dev/null 2>&1 || true
    fi

    # Disable CFS autogroups
    sudo sysctl -w kernel.sched_autogroup_enabled=0 >/dev/null 2>&1 || true
    
    # CFS bandwidth slice
    sudo sysctl -w kernel.sched_cfs_bandwidth_slice_us=3000 >/dev/null 2>&1 || true

    # Real-time thread budget: -1 (unlimited RT runtime, prevents 95% throttling)
    sudo sysctl -w kernel.sched_rt_runtime_us=-1 >/dev/null 2>&1 || true
    sudo sysctl -w kernel.sched_rt_period_us=1000000 >/dev/null 2>&1 || true
    IMPROVEMENTS["Real-Time Budget"]="sched_rt_runtime_us=-1 (100% budget for trading threads)"

    # Disable NUMA balancing scanner
    sudo sysctl -w kernel.numa_balancing=0 >/dev/null 2>&1 || true
    IMPROVEMENTS["NUMA Balancing"]="Disabled background numa_balancing memory scanner"

    # Disable hung task detector
    sudo sysctl -w kernel.hung_task_timeout_secs=0 >/dev/null 2>&1 || true

    # Suppress console printk latency delays
    sudo sysctl -w kernel.printk="3 4 1 3" >/dev/null 2>&1 || true

    # Perf event paranoid
    sudo sysctl -w kernel.perf_event_paranoid=-1 >/dev/null 2>&1 || true

    # --------------------------------------------------------------------------
    # [3] VIRTUAL MEMORY & PAGING SUBSYSTEM
    # --------------------------------------------------------------------------
    print_subheader "[3/7] Memory Subsystem, Swappiness & Transparent Hugepages"

    # Swappiness = 0 (never swap anonymous process memory)
    sudo sysctl -w vm.swappiness=0 >/dev/null 2>&1 || true
    IMPROVEMENTS["VM Swappiness"]="vm.swappiness=0 (strictly prevents paging stalls)"

    # Dirty ratios (prevent large synchronous flush pauses)
    sudo sysctl -w vm.dirty_ratio=10 >/dev/null 2>&1 || true
    sudo sysctl -w vm.dirty_background_ratio=5 >/dev/null 2>&1 || true
    sudo sysctl -w vm.dirty_writeback_centisecs=1500 >/dev/null 2>&1 || true
    sudo sysctl -w vm.dirty_expire_centisecs=3000 >/dev/null 2>&1 || true

    # Reduce vmstat background timer interrupt interval from 1s to 120s!
    sudo sysctl -w vm.stat_interval=120 >/dev/null 2>&1 || true
    IMPROVEMENTS["VM Stat Interval"]="Set to 120s (eliminates 1 Hz periodic vmstat timer jitter)"

    # Disable proactive memory compaction
    sudo sysctl -w vm.compaction_proactiveness=0 >/dev/null 2>&1 || true
    sudo sysctl -w vm.zone_reclaim_mode=0 >/dev/null 2>&1 || true
    sudo sysctl -w vm.max_map_count=1048576 >/dev/null 2>&1 || true

    # Transparent Huge Pages -> never (eliminates allocation stalls and compaction jitter)
    if [ -f /sys/kernel/mm/transparent_hugepage/enabled ]; then
        echo never | sudo tee /sys/kernel/mm/transparent_hugepage/enabled >/dev/null 2>&1 || true
        echo never | sudo tee /sys/kernel/mm/transparent_hugepage/defrag >/dev/null 2>&1 || true
        IMPROVEMENTS["Transparent Huge Pages"]="Disabled (never) to eliminate defrag allocation latency spikes"
    fi
    if [ -f /sys/kernel/mm/transparent_hugepage/khugepaged/defrag ]; then
        echo 0 | sudo tee /sys/kernel/mm/transparent_hugepage/khugepaged/defrag >/dev/null 2>&1 || true
    fi

    # Flush page caches before test
    sync
    echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null 2>&1 || true

    # --------------------------------------------------------------------------
    # [4] NETWORK STACK: SOCKET BUSY-POLLING & TCP/IP
    # --------------------------------------------------------------------------
    print_subheader "[4/7] Network Stack, Low-Latency Sockets & Busy-Polling"

    # Socket Low-Latency Busy-Polling
    sudo sysctl -w net.core.busy_poll=50 >/dev/null 2>&1 || true
    sudo sysctl -w net.core.busy_read=50 >/dev/null 2>&1 || true
    IMPROVEMENTS["Socket Busy Polling"]="net.core.busy_poll=50us, busy_read=50us (active polling)"

    # Buffer capacities & queue depths (up to 64MB buffers)
    sudo sysctl -w net.core.rmem_max=67108864 >/dev/null 2>&1 || true
    sudo sysctl -w net.core.wmem_max=67108864 >/dev/null 2>&1 || true
    sudo sysctl -w net.core.rmem_default=16777216 >/dev/null 2>&1 || true
    sudo sysctl -w net.core.wmem_default=16777216 >/dev/null 2>&1 || true
    sudo sysctl -w net.core.optmem_max=2097152 >/dev/null 2>&1 || true
    sudo sysctl -w net.ipv4.tcp_rmem="4096 87380 67108864" >/dev/null 2>&1 || true
    sudo sysctl -w net.ipv4.tcp_wmem="4096 65536 67108864" >/dev/null 2>&1 || true
    sudo sysctl -w net.core.netdev_max_backlog=250000 >/dev/null 2>&1 || true
    sudo sysctl -w net.core.somaxconn=65535 >/dev/null 2>&1 || true
    sudo sysctl -w net.ipv4.tcp_max_syn_backlog=3240000 >/dev/null 2>&1 || true
    IMPROVEMENTS["Socket Buffers"]="Expanded max socket memory to 64MB; backlog to 250,000"

    # TCP Low-Latency Protocol Options
    sudo sysctl -w net.ipv4.tcp_low_latency=1 >/dev/null 2>&1 || true
    sudo sysctl -w net.ipv4.tcp_timestamps=0 >/dev/null 2>&1 || true
    sudo sysctl -w net.ipv4.tcp_sack=1 >/dev/null 2>&1 || true
    sudo sysctl -w net.ipv4.tcp_dsack=0 >/dev/null 2>&1 || true
    sudo sysctl -w net.ipv4.tcp_slow_start_after_idle=0 >/dev/null 2>&1 || true
    sudo sysctl -w net.ipv4.tcp_tw_reuse=1 >/dev/null 2>&1 || true
    sudo sysctl -w net.ipv4.tcp_fin_timeout=15 >/dev/null 2>&1 || true
    sudo sysctl -w net.ipv4.tcp_fastopen=3 >/dev/null 2>&1 || true
    sudo sysctl -w net.ipv4.ip_local_port_range="1024 65535" >/dev/null 2>&1 || true
    sudo sysctl -w net.ipv4.tcp_window_scaling=1 >/dev/null 2>&1 || true
    sudo sysctl -w net.ipv4.tcp_adv_win_scale=1 >/dev/null 2>&1 || true
    sudo sysctl -w net.ipv4.tcp_notsent_lowat=16384 >/dev/null 2>&1 || true
    IMPROVEMENTS["TCP Slow Start After Idle"]="Disabled (ensures immediate line-rate burst upon idle packet)"
    IMPROVEMENTS["TCP Timestamps"]="Disabled to shave 12-byte packet overhead and timestamp math"

    # Loopback Interface Optimization
    sudo ip link set lo mtu 65536 2>/dev/null || true
    sudo ip link set lo txqueuelen 10000 2>/dev/null || true
    IMPROVEMENTS["Loopback Interface"]="MTU=65536, txqueuelen=10000"

    # Hardware NIC tuning (if supported on interface)
    local iface="${SYSTEM_INFO["primary_iface"]}"
    if [ "$iface" != "unknown" ] && [ "$iface" != "lo" ]; then
        # Disable interrupt coalescing delay
        sudo ethtool -C "$iface" adaptive-rx off adaptive-tx off rx-usecs 0 tx-usecs 0 rx-frames 1 tx-frames 1 >/dev/null 2>&1 || true
        # Disable packet aggregation offloads that add queueing delay
        sudo ethtool -K "$iface" gro off lro off tso off gso off >/dev/null 2>&1 || true
        # Tune ring buffer
        sudo ethtool -G "$iface" rx 256 tx 256 >/dev/null 2>&1 || true
        IMPROVEMENTS["NIC Coalescing & Offloads"]="Zeroed rx/tx usecs, disabled GRO/LRO batching on $iface"
    fi

    # --------------------------------------------------------------------------
    # [5] IRQ AFFINITY & CORE SHIELDING
    # --------------------------------------------------------------------------
    print_subheader "[5/7] IRQ Balancing, Affinity & Workqueue Shielding"

    # Disable irqbalance daemon
    if systemctl is-active --quiet irqbalance 2>/dev/null; then
        sudo systemctl stop irqbalance >/dev/null 2>&1 || true
        sudo systemctl disable irqbalance >/dev/null 2>&1 || true
        IMPROVEMENTS["irqbalance"]="Stopped and disabled irqbalance service"
    fi

    # Shield Core 1..N: pin all interrupts to Core 0
    local total_cpus="${SYSTEM_INFO["cpus"]}"
    if [ "$total_cpus" -ge 2 ]; then
        # Default affinity: CPU 0 (hex mask 0x1)
        echo 1 | sudo tee /proc/irq/default_smp_affinity >/dev/null 2>&1 || true
        for irq_aff in /proc/irq/*/smp_affinity; do
            if [ -f "$irq_aff" ]; then
                echo 1 | sudo tee "$irq_aff" >/dev/null 2>&1 || true
            fi
        done
        IMPROVEMENTS["IRQ Shielding"]="All hardware & network IRQs directed to Core 0"

        # Direct writeback workqueues to Core 0
        if [ -f /sys/bus/workqueue/devices/writeback/cpumask ]; then
            echo 1 | sudo tee /sys/bus/workqueue/devices/writeback/cpumask >/dev/null 2>&1 || true
        fi
    fi

    # --------------------------------------------------------------------------
    # [6] TUNED PROFILE & OS JITTER ELIMINATION
    # --------------------------------------------------------------------------
    print_subheader "[6/7] Tuned Profile, Audit Suppression & Background Jitter"

    # Create custom tuned profile
    sudo mkdir -p /etc/tuned/hft-ultra
    cat << 'EOF_TUNED' | sudo tee /etc/tuned/hft-ultra/tuned.conf >/dev/null 2>&1
# Custom HFT Ultra Low-Latency Tuned Profile
[main]
summary=Ultimate HFT Ultra Low-Latency Profile
include=network-latency

[cpu]
force_latency=0
governor=performance
energy_perf_bias=performance
min_perf_pct=100
boost=1

[vm]
transparent_hugepages=never

[sysctl]
vm.swappiness=0
vm.stat_interval=120
net.core.busy_poll=50
net.core.busy_read=50
kernel.numa_balancing=0
kernel.nmi_watchdog=0
EOF_TUNED

    if command -v tuned-adm >/dev/null 2>&1; then
        if sudo tuned-adm profile hft-ultra >/dev/null 2>&1; then
            IMPROVEMENTS["Tuned Profile"]="Activated custom 'hft-ultra' profile"
        elif sudo tuned-adm profile network-latency >/dev/null 2>&1; then
            IMPROVEMENTS["Tuned Profile"]="Switched to 'network-latency' profile"
        fi
    fi

    # Suppress kernel audit overhead
    if command -v auditctl >/dev/null 2>&1; then
        sudo auditctl -e 0 >/dev/null 2>&1 || true
        IMPROVEMENTS["Kernel Audit"]="Disabled via auditctl -e 0"
    fi

    # Disable non-essential background timers that generate jitter
    for timer in dnf-makecache.timer apt-daily.timer apt-daily-upgrade.timer; do
        if systemctl is-active --quiet "$timer" 2>/dev/null; then
            sudo systemctl stop "$timer" >/dev/null 2>&1 || true
        fi
    done

    # Security limits (unlimited memlock, 1M file descriptors)
    sudo mkdir -p /etc/security/limits.d
    cat << 'EOF_LIMITS' | sudo tee /etc/security/limits.d/99-hft.conf >/dev/null 2>&1
*       soft    nofile      1048576
*       hard    nofile      1048576
*       soft    memlock     unlimited
*       hard    memlock     unlimited
*       soft    rtprio      99
*       hard    rtprio      99
*       soft    nice        -20
*       hard    nice        -20
root    soft    memlock     unlimited
root    hard    memlock     unlimited
EOF_LIMITS
    IMPROVEMENTS["Resource Limits"]="Set nofile=1M, memlock=unlimited, rtprio=99 in limits.d/99-hft.conf"

    # --------------------------------------------------------------------------
    # [7] PERSISTENT CONFIGURATION & BOOT ARGS
    # --------------------------------------------------------------------------
    print_subheader "[7/7] Persistent Sysctl & Bare-Metal GRUB Recommendations"

    # Write persistent sysctl file
    cat << 'EOF_SYSCTL' | sudo tee /etc/sysctl.d/99-hft-latency.conf >/dev/null 2>&1
# HFT Low-Latency Kernel Configuration
# Generated by HFT Ultra Tuning Engine
net.core.busy_poll = 50
net.core.busy_read = 50
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.rmem_default = 16777216
net.core.wmem_default = 16777216
net.core.optmem_max = 2097152
net.core.netdev_max_backlog = 250000
net.core.somaxconn = 65535
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.tcp_max_syn_backlog = 3240000
net.ipv4.tcp_slow_start_after_idle = 0
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
vm.swappiness = 0
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5
vm.dirty_writeback_centisecs = 1500
vm.dirty_expire_centisecs = 3000
vm.stat_interval = 120
vm.compaction_proactiveness = 0
vm.zone_reclaim_mode = 0
vm.max_map_count = 1048576
kernel.numa_balancing = 0
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
    print_success "Persistent sysctl saved to /etc/sysctl.d/99-hft-latency.conf"

    # Generate GRUB boot parameters recommendation file
    local isolated_cores="1-$((total_cpus - 1))"
    [ "$total_cpus" -le 1 ] && isolated_cores="0"
    
    cat << EOF_GRUB > "$OUT_DIR/grub_cmdline_recommendation.txt"
# ==============================================================================
# HFT RECOMMENDED BARE-METAL BOOT PARAMETERS
# Append the following line to GRUB_CMDLINE_LINUX in /etc/default/grub:
# ==============================================================================
isolcpus=${isolated_cores} nohz=on nohz_full=${isolated_cores} rcu_nocbs=${isolated_cores} rcu_nocb_poll intel_idle.max_cstate=0 processor.max_cstate=0 idle=poll intel_pstate=disable clocksource=tsc tsc=reliable nosmt audit=0 mce=ignore_ce elevator=noop transparent_hugepage=never

# Then update GRUB:
# AlmaLinux/RHEL: sudo grub2-mkconfig -o /boot/grub2/grub.cfg
# Debian/Ubuntu : sudo update-grub
EOF_GRUB
    print_success "Bare-metal kernel boot command line recommendation written to $OUT_DIR/grub_cmdline_recommendation.txt"

    print_success "Comprehensive low-latency tuning successfully applied!"
}

# ------------------------------------------------------------------------------
# 11. SIDE-BY-SIDE COMPARATIVE NANOSECOND REPORT GENERATION
# ------------------------------------------------------------------------------
format_delta() {
    local b="$1"
    local a="$2"
    local is_lower_better="${3:-1}"

    if [ -z "$b" ] || [ -z "$a" ] || [ "$b" = "0" ] || [ "$b" = "0.0" ]; then
        echo "0.00%|N/A|SAME"
        return
    fi

    # Calculate delta: Before - After
    local delta
    delta="$(echo "$b - $a" | bc -l 2>/dev/null || echo "0")"
    
    # Calculate percentage: ((Before - After) / Before) * 100%
    local pct
    pct="$(echo "scale=2; (($b - $a) / $b) * 100.0" | bc -l 2>/dev/null || echo "0")"

    local status="SAME"
    local cmp
    cmp="$(echo "$delta > 0.001" | bc -l 2>/dev/null || echo "0")"
    local cmp_neg
    cmp_neg="$(echo "$delta < -0.001" | bc -l 2>/dev/null || echo "0")"

    if [ "$cmp" -eq 1 ]; then
        [ "$is_lower_better" -eq 1 ] && status="FASTER" || status="SLOWER"
    elif [ "$cmp_neg" -eq 1 ]; then
        [ "$is_lower_better" -eq 1 ] && status="SLOWER" || status="FASTER"
    fi

    printf "%.2f%%|%.1f|%s" "$pct" "$delta" "$status"
}

generate_comparative_report() {
    print_header "GENERATING COMPREHENSIVE LATENCY COMPARISON REPORT"

    local metrics_list=(
        "CLOCK_MONO_AVG:Clock Monotonic (Mean):ns:1"
        "CLOCK_MONO_P99:Clock Monotonic (P99):ns:1"
        "CLOCK_RAW_AVG:Clock Monotonic Raw (Mean):ns:1"
        "CLOCK_RAW_P99:Clock Monotonic Raw (P99):ns:1"
        "SYSCALL_AVG:Minimal Syscall getpid (Mean):ns:1"
        "SYSCALL_P99:Minimal Syscall getpid (P99):ns:1"
        "CTXSWITCH_AVG:Thread Context Switch (Mean):ns:1"
        "CTXSWITCH_P99:Thread Context Switch (P99):ns:1"
        "TCPLOOP_AVG:TCP Loopback Ping-Pong (Mean):ns:1"
        "TCPLOOP_P99:TCP Loopback Ping-Pong (P99):ns:1"
        "UDPLOOP_AVG:UDP Loopback Ping-Pong (Mean):ns:1"
        "UDPLOOP_P99:UDP Loopback Ping-Pong (P99):ns:1"
        "UDSLOOP_AVG:UNIX Domain Socket RTT (Mean):ns:1"
        "UDSLOOP_P99:UNIX Domain Socket RTT (P99):ns:1"
        "MEM_CHASE_AVG:Memory Pointer Chase (LLC/RAM):ns:1"
        "CAS_CONTENTION_AVG:Atomic CAS Contention:ns:1"
        "JITTER_SPIKES:OS Jitter Stalls (>1000ns):count:1"
        "JITTER_MAX:OS Jitter Max Pause:ns:1"
        "CYCLIC_AVG:Cyclictest Timer Wakeup (Mean):ns:1"
        "CYCLIC_MAX:Cyclictest Timer Wakeup (Max):ns:1"
    )

    # 1. Print formatted table to terminal
    echo ""
    echo -e "${WHITE}${BOLD}┌──────────────────────────────────────┬─────────────┬─────────────┬─────────────┬──────────────┬───────────┐${NC}"
    printf "${WHITE}${BOLD}│ %-36s │ %11s │ %11s │ %11s │ %12s │ %-9s │${NC}\n" "LATENCY BENCHMARK METRIC" "BEFORE (ns)" "AFTER (ns)" "DELTA (ns)" "IMPROVEMENT" "STATUS"
    echo -e "${WHITE}${BOLD}├──────────────────────────────────────┼─────────────┼─────────────┼─────────────┼──────────────┼───────────┤${NC}"

    for item in "${metrics_list[@]}"; do
        IFS=':' read -r key label unit lower_better <<< "$item"
        local b_val="${BEFORE_METRICS[$key]:-N/A}"
        local a_val="${AFTER_METRICS[$key]:-N/A}"

        if [ "$b_val" != "N/A" ] && [ "$a_val" != "N/A" ]; then
            local res
            res="$(format_delta "$b_val" "$a_val" "$lower_better")"
            IFS='|' read -r pct delta status <<< "$res"

            local color="$NC"
            if [ "$status" = "FASTER" ]; then
                color="$GREEN"
            elif [ "$status" = "SLOWER" ]; then
                color="$RED"
            fi

            printf "│ %-36s │ %11s │ %11s │ ${color}%11s${NC} │ ${color}%12s${NC} │ ${color}%-9s${NC} │\n" \
                   "$label" "$b_val" "$a_val" "$delta" "$pct" "$status"
        fi
    done
    echo -e "${WHITE}${BOLD}└──────────────────────────────────────┴─────────────┴─────────────┴─────────────┴──────────────┴───────────┘${NC}"
    echo ""

    # 2. Write permanent text report
    {
        cat << EOF_RPT
================================================================================
           HFT ULTRA-LOW-LATENCY LINUX BENCHMARK & TUNING REPORT
================================================================================
Timestamp   : $(date)
Host Name   : ${SYSTEM_INFO["hostname"]}
Platform    : ${SYSTEM_INFO["os_name"]} (${SYSTEM_INFO["virt"]})
Kernel      : ${SYSTEM_INFO["kernel"]} (${SYSTEM_INFO["arch"]})
CPU Model   : ${SYSTEM_INFO["cpu_model"]}
Topology    : ${SYSTEM_INFO["cpus"]} vCPUs / ${SYSTEM_INFO["sockets"]} Sockets / ${SYSTEM_INFO["numa_nodes"]} NUMA Nodes
Network IF  : ${SYSTEM_INFO["primary_iface"]}
Report File : $REPORT_TXT
Log File    : $LOG_FILE
================================================================================

--------------------------------------------------------------------------------
1. COMPARATIVE NANOSECOND LATENCY MATRIX (BEFORE vs AFTER)
--------------------------------------------------------------------------------
Benchmark Metric                          Before (ns)    After (ns)    Delta (ns)    Improvement    Verdict
---------------------------------------------------------------------------------------------------------
EOF_RPT

        for item in "${metrics_list[@]}"; do
            IFS=':' read -r key label unit lower_better <<< "$item"
            local b_val="${BEFORE_METRICS[$key]:-N/A}"
            local a_val="${AFTER_METRICS[$key]:-N/A}"

            if [ "$b_val" != "N/A" ] && [ "$a_val" != "N/A" ]; then
                local res
                res="$(format_delta "$b_val" "$a_val" "$lower_better")"
                IFS='|' read -r pct delta status <<< "$res"
                printf "%-40s  %11s  %12s  %12s  %13s    %-8s\n" \
                       "$label" "$b_val" "$a_val" "$delta" "$pct" "$status"
            fi
        done

        cat << EOF_RPT2

--------------------------------------------------------------------------------
2. SYSTEM TUNING ACTIONS APPLIED
--------------------------------------------------------------------------------
EOF_RPT2
        for key in "${!IMPROVEMENTS[@]}"; do
            printf "  [✓] %-28s : %s\n" "$key" "${IMPROVEMENTS[$key]}"
        done

        cat << EOF_RPT3

--------------------------------------------------------------------------------
3. ARTIFACTS & CONFIGURATION FILES
--------------------------------------------------------------------------------
  • Full Log Output           : $LOG_FILE
  • Baseline Before Report    : $REPORT_BEFORE
  • Comparative Text Report   : $REPORT_TXT
  • Machine JSON Report       : $REPORT_JSON
  • Persistent Sysctl File    : /etc/sysctl.d/99-hft-latency.conf
  • Security Limits Config    : /etc/security/limits.d/99-hft.conf
  • GRUB Commandline Advice   : $OUT_DIR/grub_cmdline_recommendation.txt
  • Sysctl Backup Baseline    : $BACKUP_SYSCTL

================================================================================
                        END OF HFT TUNING REPORT
================================================================================
EOF_RPT3
    } > "$REPORT_TXT"

    # 3. Write Machine-Readable JSON Report
    {
        echo "{"
        echo "  \"timestamp\": \"$(date --iso-8601=seconds)\","
        echo "  \"system\": {"
        echo "    \"hostname\": \"${SYSTEM_INFO["hostname"]}\","
        echo "    \"os\": \"${SYSTEM_INFO["os_name"]}\","
        echo "    \"kernel\": \"${SYSTEM_INFO["kernel"]}\","
        echo "    \"cpu\": \"${SYSTEM_INFO["cpu_model"]}\","
        echo "    \"vcpus\": ${SYSTEM_INFO["cpus"]},"
        echo "    \"virt\": \"${SYSTEM_INFO["virt"]}\""
        echo "  },"
        echo "  \"benchmarks\": {"
        local first=1
        for item in "${metrics_list[@]}"; do
            IFS=':' read -r key label unit lower_better <<< "$item"
            local b_val="${BEFORE_METRICS[$key]:-0}"
            local a_val="${AFTER_METRICS[$key]:-0}"
            local res
            res="$(format_delta "$b_val" "$a_val" "$lower_better")"
            IFS='|' read -r pct delta status <<< "$res"
            [ "$first" -eq 0 ] && echo ","
            first=0
            printf "    \"%s\": { \"label\": \"%s\", \"before_ns\": %s, \"after_ns\": %s, \"delta_ns\": %s, \"pct_improvement\": \"%s\", \"verdict\": \"%s\" }" \
                   "$key" "$label" "$b_val" "$a_val" "$delta" "$pct" "$status"
        done
        echo ""
        echo "  }"
        echo "}"
    } > "$REPORT_JSON"

    print_success "Permanent report saved to: $REPORT_TXT"
    print_success "JSON report saved to: $REPORT_JSON"
}

# ------------------------------------------------------------------------------
# 12. CLEANUP & REVERT CAPABILITY
# ------------------------------------------------------------------------------
cleanup() {
    rm -f "$BENCH_SRC" "$BENCH_BIN" "$DMA_DAEMON_SRC" "$DMA_DAEMON_BIN" 2>/dev/null || true
    rm -f /tmp/hft_uds.sock 2>/dev/null || true
}
trap cleanup EXIT

revert_tuning() {
    print_header "REVERTING SYSTEM SETTINGS TO PRE-TUNING BASELINE"

    stop_dma_latency_lock

    if [ -f "$BACKUP_SYSCTL" ]; then
        print_info "Restoring sysctl parameters from $BACKUP_SYSCTL..."
        sudo sysctl -p "$BACKUP_SYSCTL" >/dev/null 2>&1 || true
    else
        sudo sysctl -w net.core.busy_poll=0 net.core.busy_read=0 vm.swappiness=30 vm.stat_interval=1 >/dev/null 2>&1 || true
    fi

    # Re-enable irqbalance
    if systemctl is-enabled --quiet irqbalance 2>/dev/null; then
        sudo systemctl start irqbalance >/dev/null 2>&1 || true
    fi

    # Restore balanced tuned profile
    if command -v tuned-adm >/dev/null 2>&1; then
        sudo tuned-adm profile virtual-guest 2>/dev/null || sudo tuned-adm profile balanced 2>/dev/null || true
    fi

    print_success "System dynamic settings reverted to baseline."
}

# ------------------------------------------------------------------------------
# 13. SCRIPT CLI DISPATCHER
# ------------------------------------------------------------------------------
show_help() {
    print_banner
    cat << EOF_HELP
Usage: $(basename "$0") [COMMAND]

Commands:
  --full         (Default) Run complete workflow:
                 1. Run BEFORE benchmark and output baseline nanosecond latency.
                 2. Apply the comprehensive set of Linux HFT kernel & OS optimizations.
                 3. Run AFTER benchmark and generate side-by-side comparative report.
  --before-only  Execute only the initial baseline nanosecond latency benchmarks.
  --tune-only    Apply comprehensive HFT Linux tuning settings without running benchmarks.
  --after-only   Execute only the post-tuning benchmarks and comparative report.
  --revert       Revert dynamic sysctl, PM QoS, and service settings to baseline.
  --help, -h     Display this help manual.

Output Files:
  Reports and logs are written to ~/results/ (or ./results/):
  • hft_before_report_<timestamp>.txt   - Standalone nanosecond baseline report
  • hft_tuning_report_<timestamp>.txt   - Exhaustive human-readable comparative report
  • hft_tuning_report_<timestamp>.json  - Machine-readable JSON latency matrix
  • hft_tuning_<timestamp>.log          - Full debug execution log
  • grub_cmdline_recommendation.txt     - Bare-metal GRUB boot parameters
EOF_HELP
}

main() {
    local mode="${1:---full}"

    case "$mode" in
        --full)
            print_banner
            discover_system
            ensure_dependencies
            build_microbenchmark
            build_dma_latency_daemon
            run_benchmarks "BEFORE"
            apply_hft_tuning
            run_benchmarks "AFTER"
            generate_comparative_report
            print_header "HFT TUNING & BENCHMARK SUITE COMPLETED SUCCESSFULLY"
            ;;
        --before-only)
            print_banner
            discover_system
            ensure_dependencies
            build_microbenchmark
            run_benchmarks "BEFORE"
            ;;
        --tune-only)
            print_banner
            discover_system
            ensure_dependencies
            build_dma_latency_daemon
            apply_hft_tuning
            ;;
        --after-only)
            print_banner
            discover_system
            ensure_dependencies
            build_microbenchmark
            run_benchmarks "AFTER"
            generate_comparative_report
            ;;
        --revert)
            revert_tuning
            ;;
        --help|-h|help)
            show_help
            ;;
        *)
            print_error "Unknown option: $mode"
            show_help
            exit 1
            ;;
    esac
}

main "$@"
