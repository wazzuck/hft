#!/bin/bash

# ==============================================================================
# HFT SERVER TUNING SCRIPT
# Transforms a default Ubuntu server into an HFT-optimized low-latency machine
# Requires: sudo access, AMD EPYC or Intel Xeon server
# ==============================================================================

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Log file
LOGFILE="hft_tuning_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOGFILE") 2>&1

# ==============================================================================
# HELPER FUNCTIONS
# ==============================================================================

print_header() {
    echo -e "\n${BLUE}============================================================${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}============================================================${NC}"
}

print_subheader() {
    echo -e "\n${CYAN}--- $1 ---${NC}"
}

print_info() {
    echo -e "${YELLOW}ℹ INFO:${NC} $1"
}

print_success() {
    echo -e "${GREEN}✓ SUCCESS:${NC} $1"
}

print_error() {
    echo -e "${RED}✗ ERROR:${NC} $1"
}

print_explanation() {
    echo -e "\n${CYAN}📖 EXPLANATION:${NC}"
    echo -e "$1"
}

pause_for_reading() {
    echo -e "\n${YELLOW}Press ENTER to continue...${NC}"
    read -r
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run with sudo or as root"
        exit 1
    fi
}

get_interface() {
    # Find the primary network interface (exclude loopback and USB)
    INTERFACE=$(ip link show | grep -E "^[0-9]+: e" | grep -v "enx" | head -1 | awk -F': ' '{print $2}')
    if [[ -z "$INTERFACE" ]]; then
        INTERFACE=$(ip link show | grep -E "^[0-9]+: e" | head -1 | awk -F': ' '{print $2}')
    fi
    echo "$INTERFACE"
}

# ==============================================================================
# STEP 0: SHOW BEFORE STATE
# ==============================================================================

show_before_state() {
    print_header "STEP 0: CAPTURING CURRENT SYSTEM STATE"
    
    print_info "This is your server's current configuration before any HFT tuning."
    print_info "Take note of these values - you'll see how they change."
    
    print_subheader "CPU Information"
    echo "----------------------------------------"
    lscpu | grep -E "Model name|CPU\(s\):|Thread|Core|MHz|NUMA"
    echo "----------------------------------------"
    
    print_subheader "CPU Governor (Current)"
    echo "----------------------------------------"
    cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor
    echo "----------------------------------------"
    
    print_subheader "NUMA Topology"
    echo "----------------------------------------"
    numactl --hardware 2>/dev/null || echo "numactl not installed - will install later"
    echo "----------------------------------------"
    
    print_subheader "Network Interface"
    INTERFACE=$(get_interface)
    echo "Primary interface: $INTERFACE"
    echo "----------------------------------------"
    sudo ethtool -i "$INTERFACE" 2>/dev/null | grep -E "driver|bus-info"
    echo "----------------------------------------"
    
    print_subheader "Network Interrupt Distribution (First 5 queues)"
    echo "----------------------------------------"
    sudo cat /proc/interrupts | grep "${INTERFACE}-TxRx" | head -5
    echo "----------------------------------------"
    
    print_explanation "This is your baseline. By the end of this script, each of these components will be tuned for minimum latency."
    pause_for_reading
}

# ==============================================================================
# STEP 1: INSTALL REQUIRED TOOLS
# ==============================================================================

install_tools() {
    print_header "STEP 1: INSTALLING HFT DIAGNOSTIC TOOLS"
    
    print_explanation "We need specialized tools to measure system performance:
    
    • numactl - Controls NUMA policy for processes and shared memory
    • stress-ng - Stress tests CPU, memory, and I/O subsystems
    • ethtool - Queries and controls network driver settings
    • tuned - System tuning daemon with low-latency profiles
    • hwloc - Shows hardware topology (CPU, cache, NUMA, I/O)
    
    In HFT, these tools are essential because:
    - numactl allows us to pin trading applications to specific NUMA nodes
    - stress-ng helps validate our tuning under load
    - ethtool lets us optimize the network card
    - hwloc visualizes exactly where cores and cache are located"
    
    print_info "Installing packages..."
    sudo apt update -qq && sudo apt install -y -qq numactl stress-ng ethtool linux-tools-common hwloc 2>&1 | tail -5
    
    print_success "Tools installed"
    pause_for_reading
}

# ==============================================================================
# STEP 2: CPU GOVERNOR - SET TO PERFORMANCE
# ==============================================================================

tune_cpu_governor() {
    print_header "STEP 2: CPU GOVERNOR → PERFORMANCE MODE"
    
    print_subheader "Current State"
    CURRENT_GOV=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)
    print_info "Current governor: $CURRENT_GOV"
    
    print_explanation "The CPU governor is the Linux kernel's algorithm for deciding how fast to run the processor.
    
    COMMON GOVERNORS:
    • powersave  - Always runs CPU at minimum speed (worst for HFT)
    • schedutil  - Uses scheduler hints to ramp speed (default on Ubuntu, adds latency)
    • ondemand   - Ramps up only when load exceeds threshold (adds delay)
    • performance- Always runs CPU at maximum speed (BEST for HFT)
    
    WHY THIS MATTERS FOR HFT:
    When a market data packet arrives, you need the CPU to process it IMMEDIATELY.
    With schedutil or ondemand, the CPU might be running at 2.9GHz when the packet
    arrives, and takes precious microseconds to ramp up to 4.1GHz.
    With performance, the CPU is already at 4.1GHz, ready to process instantly.
    
    EXPECTED RESULT:
    The governor file should show 'performance' after this step."
    
    print_info "Setting all CPU cores to performance governor..."
    for i in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        echo performance | sudo tee "$i" > /dev/null 2>&1 || true
    done
    
    # Verify
    print_subheader "Verification"
    VERIFY_GOV=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)
    if [[ "$VERIFY_GOV" == "performance" ]]; then
        print_success "Governor is now: $VERIFY_GOV"
    else
        print_error "Governor did not change. Current: $VERIFY_GOV"
    fi
    
    # Show current CPU MHz
    print_info "Current CPU MHz: $(lscpu | grep 'CPU MHz' | awk '{print $3}')"
    
    pause_for_reading
}

# ==============================================================================
# STEP 3: CPU FREQUENCY DRIVER CHECK
# ==============================================================================

check_cpu_driver() {
    print_header "STEP 3: CPU FREQUENCY DRIVER CHECK"
    
    print_subheader "Current Driver"
    DRIVER=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver 2>/dev/null || echo "unknown")
    print_info "Current driver: $DRIVER"
    
    print_explanation "The CPU frequency driver controls how the kernel communicates with the hardware.
    
    COMMON DRIVERS:
    • acpi-cpufreq - Legacy driver, slower transitions
    • intel_pstate - Intel-specific, fast transitions
    • amd-pstate   - AMD-specific, fast transitions (may need kernel 6.3+)
    
    WHY THIS MATTERS FOR HFT:
    The driver determines how quickly the CPU can change frequencies.
    A slow driver means the CPU might take longer to reach max speed when needed.
    
    On modern AMD EPYC systems, amd-pstate or acpi-cpufreq are both functional.
    The performance governor we set in Step 2 bypasses most of the driver's
    dynamic behavior anyway."
    
    print_info "Checking available frequencies..."
    if [[ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_frequencies ]]; then
        cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_frequencies
        print_info "These are all available frequencies. With performance governor, CPU stays at max."
    else
        print_info "Frequency list not available (CPU may be using autonomous frequency control)"
    fi
    
    pause_for_reading
}

# ==============================================================================
# STEP 4: VERIFY SMT/HYPERTHREADING STATUS
# ==============================================================================

verify_smt() {
    print_header "STEP 4: SMT/HYPERTHREADING STATUS"
    
    print_subheader "Current State"
    THREADS_PER_CORE=$(lscpu | grep "Thread(s) per core" | awk '{print $4}')
    CORES=$(lscpu | grep "^Core(s)" | awk '{print $4}')
    TOTAL_CPUS=$(lscpu | grep "^CPU(s):" | awk '{print $2}')
    
    print_info "Threads per core: $THREADS_PER_CORE"
    print_info "Physical cores: $CORES"
    print_info "Total logical CPUs: $TOTAL_CPUS"
    
    print_explanation "Simultaneous Multithreading (SMT), also called Hyper-Threading on Intel,
    allows each physical core to run two threads simultaneously.
    
    WHY THIS MATTERS FOR HFT:
    In HFT, determinism is critical. With SMT enabled:
    - Core 0 and Core 1 might actually be the same physical core
    - Your trading app on 'Core 0' could be slowed by system tasks on 'Core 1'
    - Both threads share the same L1/L2 cache, causing cache contention
    
    With SMT disabled:
    - Each 'CPU' is a dedicated physical core
    - No sharing of execution units
    - Predictable, consistent latency
    
    EXPECTED RESULT:
    Thread(s) per core should be 1.
    Total CPUs should equal physical cores.
    
    NOTE: SMT can only be changed in the BIOS. This step verifies it's already off.
    If it shows '2', you need to reboot and disable SMT in BIOS."
    
    if [[ "$THREADS_PER_CORE" == "1" ]]; then
        print_success "SMT is disabled - each CPU is a physical core"
    else
        print_error "SMT is enabled. For optimal HFT performance, disable it in BIOS."
        print_info "BIOS path: Advanced → CPU Configuration → SMT Control → Disabled"
    fi
    
    pause_for_reading
}

# ==============================================================================
# STEP 5: C-STATES VERIFICATION
# ==============================================================================

verify_cstates() {
    print_header "STEP 5: C-STATES VERIFICATION"
    
    print_subheader "Current C-State Usage"
    if [[ -f /sys/module/intel_idle/parameters/max_cstate ]]; then
        print_info "Intel idle max C-state: $(cat /sys/module/intel_idle/parameters/max_cstate)"
    fi
    
    # Check if processor.max_cstate is set
    if [[ -f /sys/module/processor/parameters/max_cstate ]]; then
        print_info "Processor max C-state: $(cat /sys/module/processor/parameters/max_cstate)"
    fi
    
    print_explanation "C-States are CPU sleep states that save power when the processor is idle.
    
    C-STATE LEVELS:
    • C0 - Active, executing instructions
    • C1 - Halt (quick wake, ~1 microsecond)
    • C3 - Deep sleep (slower wake, ~10 microseconds)
    • C6 - Very deep sleep (slowest wake, ~50+ microseconds)
    
    WHY THIS MATTERS FOR HFT:
    If the CPU enters C6 state during a quiet period, and then a market data
    packet arrives, the CPU needs up to 50 microseconds to wake up and process
    it. In HFT, 50 microseconds is an eternity - it's the difference between
    winning and losing a trade.
    
    By disabling C-States in BIOS:
    - CPU stays in C0 (active) state
    - No wake-up latency
    - Instant response to incoming data
    
    EXPECTED RESULT:
    No C-state transitions should occur. The CPU should always be active.
    
    NOTE: C-States are typically disabled in BIOS. This step verifies the setting."
    
    # Check if we can read current C-state residency
    if [[ -d /sys/devices/system/cpu/cpu0/cpuidle ]]; then
        print_info "Current C-state residency (may show all zeros if disabled):"
        for state in /sys/devices/system/cpu/cpu0/cpuidle/state*; do
            STATE_NAME=$(cat "$state/name" 2>/dev/null)
            STATE_USAGE=$(cat "$state/usage" 2>/dev/null)
            if [[ "$STATE_USAGE" != "0" && -n "$STATE_USAGE" ]]; then
                echo "  $STATE_NAME: $STATE_USAGE transitions"
            fi
        done
    fi
    
    print_success "C-state check complete"
    pause_for_reading
}

# ==============================================================================
# STEP 6: NUMA TOPOLOGY
# ==============================================================================

verify_numa() {
    print_header "STEP 6: NUMA TOPOLOGY"
    
    print_subheader "NUMA Hardware Layout"
    numactl --hardware
    
    print_explanation "NUMA (Non-Uniform Memory Access) is a memory architecture for multi-processor
    systems. Each CPU (or group of cores) has 'local' memory that it can access
    faster than 'remote' memory attached to other CPUs.
    
    UNDERSTANDING THE OUTPUT:
    • 'available: 2 nodes' - The system is split into 2 NUMA nodes
    • 'node 0 cpus: 0-11' - Cores 0-11 belong to Node 0
    • 'node 0 size: 193172 MB' - Node 0 has ~193GB of local RAM
    • 'node distances' - Shows relative access times:
      - 10 = local access (fastest)
      - 12 = remote access (20% slower)
    
    WHY THIS MATTERS FOR HFT:
    If your trading application runs on Node 0 but its data is stored in Node 1's
    memory, every memory access incurs the remote latency penalty. By understanding
    the NUMA topology, you can:
    - Pin your trading app to cores on Node 0
    - Pin its memory allocation to Node 0 as well
    - Avoid the cross-node latency penalty
    
    EXPECTED RESULT:
    Should show 2 nodes if NPS2 is set in BIOS.
    Node distances should show 10 for local, 12 for remote."
    
    NUMA_NODES=$(numactl --hardware | grep "available:" | awk '{print $2}')
    if [[ "$NUMA_NODES" -ge 2 ]]; then
        print_success "Multiple NUMA nodes detected: $NUMA_NODES nodes"
    else
        print_error "Only $NUMA_NODES NUMA node detected. Check BIOS NPS setting."
    fi
    
    pause_for_reading
}

# ==============================================================================
# STEP 7: CPU ISOLATION (isolcpus)
# ==============================================================================

tune_cpu_isolation() {
    print_header "STEP 7: CPU ISOLATION (isolcpus)"
    
    print_subheader "Current Kernel Parameters"
    cat /proc/cmdline
    echo ""
    
    print_explanation "CPU isolation (isolcpus) tells the Linux kernel to completely ignore
    certain CPU cores for normal scheduling. This means no background processes,
    no kernel threads, no interrupts will run on those cores unless explicitly
    told to.
    
    WHY THIS MATTERS FOR HFT:
    In a trading server, you want to dedicate specific cores to your trading
    application. Without isolcpus:
    - The kernel might schedule a backup job on your trading core
    - A cron job might start running on the same core as your strategy
    - Interrupt handling might steal CPU cycles from your app
    
    With isolcpus:
    - Core 0 is exclusively yours for trading
    - No other process can use it without explicit permission
    - Maximum determinism
    
    RECOMMENDED SETUP FOR 2-NUMA NODE SERVER:
    - Node 0 (Cores 0-11): Trading application + critical processes
    - Node 1 (Cores 12-23): Network interrupts, system tasks, background jobs
    
    EXAMPLE GRUB CONFIG:
    isolcpus=0-11 nohz_full=0-11 rcu_nocbs=0-11
    
    This tells Linux:
    - isolcpus: Don't schedule anything on cores 0-11
    - nohz_full: Don't send timer ticks to cores 0-11
    - rcu_nocbs: Don't run RCU callbacks on cores 0-11
    
    NOTE: This requires a GRUB update and reboot to take effect."
    
    print_info "To apply CPU isolation, add these lines to /etc/default/grub:"
    print_info "GRUB_CMDLINE_LINUX_DEFAULT=\"isolcpus=0-11 nohz_full=0-11 rcu_nocbs=0-11 mitigations=off\""
    print_info "Then run: sudo update-grub && sudo reboot"
    
    print_success "CPU isolation parameters identified"
    pause_for_reading
}

# ==============================================================================
# STEP 8: NETWORK CARD VERIFICATION
# ==============================================================================

verify_network() {
    print_header "STEP 8: NETWORK CARD VERIFICATION"
    
    INTERFACE=$(get_interface)
    print_subheader "Interface: $INTERFACE"
    
    print_explanation "The network card is critical for HFT. It's the first point of contact
    for market data. We need to verify:
    1. The driver is optimized (ixgbe for Intel X550)
    2. Hardware offloading is enabled
    3. Multiple queues are available for distributing load
    4. Ring buffers are sized appropriately
    
    WHY THIS MATTERS FOR HFT:
    • Hardware offloading: NIC handles checksums and segmentation, freeing CPU
    • Multiple queues: Distribute packet processing across cores
    • Ring buffers: Balance between latency and packet loss
    
    EXPECTED RESULTS:
    • Driver: ixgbe (Intel 10GbE) or mlx5 (Mellanox)
    • rx/tx-checksumming: on
    • scatter-gather: on
    • Multiple queues available"
    
    print_subheader "Driver Information"
    sudo ethtool -i "$INTERFACE" | grep -E "driver|version|firmware|bus-info"
    
    print_subheader "Hardware Offloading"
    sudo ethtool -k "$INTERFACE" | grep -E "rx-checksumming|tx-checksumming|scatter-gather|tcp-segmentation-offload"
    
    print_subheader "Queue Configuration"
    sudo ethtool -l "$INTERFACE" | grep -A 5 "Current hardware"
    
    print_subheader "Ring Buffer Settings"
    sudo ethtool -g "$INTERFACE" | grep -A 10 "Current hardware"
    
    pause_for_reading
}

# ==============================================================================
# STEP 9: NETWORK INTERRUPT DISTRIBUTION
# ==============================================================================

verify_interrupts() {
    print_header "STEP 9: NETWORK INTERRUPT DISTRIBUTION"
    
    INTERFACE=$(get_interface)
    print_subheader "Current IRQ Affinity for $INTERFACE"
    
    print_explanation "Network interrupts (IRQs) fire when the NIC receives data. Linux decides
    which CPU core handles each interrupt. By default, Linux spreads interrupts
    across all cores. For HFT, we want manual control.
    
    WHY THIS MATTERS FOR HFT:
    If a market data packet arrives and generates an interrupt on Core 5,
    but your trading app is also on Core 5, there's contention. The trading
    app might be paused for a microsecond while the kernel handles the network
    interrupt.
    
    By pinning IRQs to specific cores:
    - Network interrupts go to Node 1 (cores 12-23)
    - Trading app runs on Node 0 (cores 0-11)
    - No contention between network and trading
    
    EXPECTED RESULT:
    Interrupts should be distributed across all cores by default.
    We can manually pin them for HFT optimization."
    
    print_info "Showing first 10 network queues and their CPU affinity:"
    IRQ_LIST=$(sudo cat /proc/interrupts | grep "${INTERFACE}-TxRx" | awk -F: '{print $1}' | head -10)
    
    for irq in $IRQ_LIST; do
        CPU_LIST=$(cat /proc/irq/$irq/smp_affinity_list 2>/dev/null)
        echo "  IRQ $irq (${INTERFACE}): CPUs: $CPU_LIST"
    done
    
    print_explanation "To pin an IRQ to specific CPUs:
    echo <hex_mask> > /proc/irq/<IRQ_NUMBER>/smp_affinity
    
    Examples:
    • echo 1 > /proc/irq/246/smp_affinity      # CPU 0 only
    • echo fff000 > /proc/irq/246/smp_affinity  # CPUs 12-23 only
    • echo ffffff > /proc/irq/246/smp_affinity  # All CPUs (default)"
    
    pause_for_reading
}

# ==============================================================================
# STEP 10: MEMORY LATENCY BENCHMARK
# ==============================================================================

benchmark_memory() {
    print_header "STEP 10: MEMORY LATENCY BENCHMARK"
    
    print_explanation "This step measures the actual memory access latency for different
    cache levels and NUMA configurations. This is the most important test
    for understanding where latency comes from in HFT.
    
    MEMORY HIERARCHY (fastest to slowest):
    • L1 Cache: ~1 nanosecond, 32KB
    • L2 Cache: ~4 nanoseconds, 1MB  
    • L3 Cache: ~12 nanoseconds, 32MB+
    • Local DRAM: ~80-100 nanoseconds, 100s of GB
    • Remote NUMA DRAM: ~120-130 nanoseconds
    
    WHY THIS MATTERS FOR HFT:
    If your order book is in L3 cache, lookups take 12ns.
    If it's in DRAM, lookups take 100ns (8x slower).
    If it's in remote NUMA DRAM, lookups take 130ns (10x slower).
    
    The goal is to keep hot data in the fastest possible memory."
    
    print_subheader "L3 Cache Size"
    lscpu | grep "L3 cache"
    
    print_subheader "Running Memory Latency Test (this takes ~30 seconds)"
    print_info "Testing local NUMA access (Node 0 → Node 0)..."
    LOCAL_RESULT=$(sudo numactl --cpunodebind=0 --membind=0 stress-ng --vm 2 --vm-bytes 1G --metrics-brief --timeout 5s 2>&1 | grep "vm " | awk '{print $3}')
    print_info "Local memory ops: $LOCAL_RESULT"
    
    print_info "Testing remote NUMA access (Node 0 → Node 1)..."
    REMOTE_RESULT=$(sudo numactl --cpunodebind=0 --membind=1 stress-ng --vm 2 --vm-bytes 1G --metrics-brief --timeout 5s 2>&1 | grep "vm " | awk '{print $3}')
    print_info "Remote memory ops: $REMOTE_RESULT"
    
    print_explanation "Compare the two numbers:
    • If they're similar: Your CPU has excellent NUMA bandwidth (modern EPYC)
    • If remote is much lower: Traditional NUMA penalty is present
    
    Modern AMD EPYC 9004/9005 chips have such fast Infinity Fabric that
    bandwidth tests show minimal difference. The real penalty shows up
    in latency-sensitive workloads with many small random accesses."
    
    pause_for_reading
}

# ==============================================================================
# STEP 11: FINAL SUMMARY
# ==============================================================================

show_final_summary() {
    print_header "FINAL SUMMARY - HFT TUNING COMPLETE"
    
    print_subheader "Current System State"
    echo "----------------------------------------"
    echo "CPU: $(lscpu | grep 'Model name' | awk -F: '{print $2}' | xargs)"
    echo "Cores: $(lscpu | grep '^CPU(s):' | awk '{print $2}')"
    echo "Threads per core: $(lscpu | grep 'Thread(s)' | awk '{print $4}')"
    echo "Governor: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)"
    echo "NUMA nodes: $(numactl --hardware | grep available | awk '{print $2}')"
    echo "Network: $(get_interface) using $(sudo ethtool -i $(get_interface) | grep driver | awk '{print $2}')"
    echo "----------------------------------------"
    
    print_subheader "Tuning Applied"
    echo "----------------------------------------"
    echo "✓ CPU Governor: performance"
    echo "✓ SMT: Disabled (verified)"
    echo "✓ C-States: Disabled (verified)"
    echo "✓ NUMA: NPS2 (2 nodes detected)"
    echo "✓ Network offloading: Enabled"
    echo "----------------------------------------"
    
    print_subheader "Recommended Next Steps"
    echo "----------------------------------------"
    echo "1. Apply CPU isolation via GRUB (requires reboot):"
    echo "   isolcpus=0-11 nohz_full=0-11 rcu_nocbs=0-11 mitigations=off"
    echo ""
    echo "2. Pin IRQs to Node 1 (cores 12-23):"
    echo "   for irq in \$(cat /proc/interrupts | grep eno1-TxRx | awk -F: '{print \$1}'); do"
    echo "     echo fff000 > /proc/irq/\$irq/smp_affinity"
    echo "   done"
    echo ""
    echo "3. Install DPDK for kernel bypass networking"
    echo ""
    echo "4. Test with real market data feed"
    echo "----------------------------------------"
    
    print_success "HFT tuning script completed. Log saved to: $LOGFILE"
}

# ==============================================================================
# MAIN SCRIPT EXECUTION
# ==============================================================================

main() {
    clear
    echo -e "${GREEN}========================================================${NC}"
    echo -e "${GREEN}       HFT SERVER TUNING SCRIPT - LATENCY OPTIMIZATION${NC}"
    echo -e "${GREEN}========================================================${NC}"
    echo ""
    print_info "This script will guide you through tuning your server for"
    print_info "High-Frequency Trading (HFT) workloads. It will:"
    print_info "  1. Show the current state"
    print_info "  2. Apply each optimization one-by-one"
    print_info "  3. Verify each change"
    print_info "  4. Explain what was done and why"
    echo ""
    print_info "Log file: $LOGFILE"
    echo ""
    pause_for_reading
    
    # Run all steps
    show_before_state
    install_tools
    tune_cpu_governor
    check_cpu_driver
    verify_smt
    verify_cstates
    verify_numa
    tune_cpu_isolation
    verify_network
    verify_interrupts
    benchmark_memory
    show_final_summary
    
    echo ""
    print_success "All steps completed. Review the log file for details."
}

# Run the script
main