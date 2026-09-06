#!/bin/bash

# ==============================================================================
# HFT SERVER TUNING SCRIPT - COMPREHENSIVE WITH LATENCY BENCHMARKS
# Transforms a default Ubuntu server into an HFT-optimized low-latency machine
# Includes before/after latency measurements and improvement report
# ==============================================================================

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

# Report file
REPORT_FILE="hft_latency_report_$(date +%Y%m%d_%H%M%S).txt"
LOGFILE="hft_tuning_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOGFILE") 2>&1

# Arrays to store before/after metrics
declare -A BEFORE_METRICS
declare -A AFTER_METRICS
declare -A IMPROVEMENTS

# ==============================================================================
# HELPER FUNCTIONS
# ==============================================================================

print_header() {
    echo -e "\n${BLUE}════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
}

print_subheader() {
    echo -e "\n${CYAN}━━━ $1 ━━━${NC}"
}

print_info() {
    echo -e "${YELLOW}ℹ INFO:${NC} $1"
}

print_success() {
    echo -e "${GREEN}✓ SUCCESS:${NC} $1"
}

print_warning() {
    echo -e "${MAGENTA}⚠ WARNING:${NC} $1"
}

print_error() {
    echo -e "${RED}✗ ERROR:${NC} $1"
}

print_metric() {
    echo -e "${BOLD}$1:${NC} $2"
}

pause_for_reading() {
    echo -e "\n${YELLOW}Press ENTER to continue...${NC}"
    read -r
}

get_interface() {
    INTERFACE=$(ip link show | grep -E "^[0-9]+: e" | grep -v "enx" | head -1 | awk -F': ' '{print $2}')
    if [[ -z "$INTERFACE" ]]; then
        INTERFACE=$(ip link show | grep -E "^[0-9]+: e" | head -1 | awk -F': ' '{print $2}')
    fi
    echo "$INTERFACE"
}

get_cpu_mhz() {
    lscpu | grep "CPU MHz" | awk '{print $3}'
}

get_governor() {
    cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor
}

get_threads_per_core() {
    lscpu | grep "Thread(s) per core" | awk '{print $4}'
}

get_numa_nodes() {
    numactl --hardware 2>/dev/null | grep "available:" | awk '{print $2}'
}

# ==============================================================================
# LATENCY MEASUREMENT FUNCTIONS
# ==============================================================================

measure_cpu_frequency_latency() {
    # Measure time to ramp from idle to max frequency
    print_info "Measuring CPU frequency ramp latency..."
    
    # Get current frequency
    CURRENT_MHZ=$(get_cpu_mhz)
    MAX_MHZ=$(lscpu | grep "CPU max MHz" | awk '{print $4}')
    
    # Measure time to reach max under load
    START_TIME=$(date +%s%N)
    stress-ng --cpu 1 --timeout 1s > /dev/null 2>&1 &
    STRESS_PID=$!
    
    # Poll for frequency increase
    while kill -0 $STRESS_PID 2>/dev/null; do
        NEW_MHZ=$(get_cpu_mhz)
        if (( $(echo "$NEW_MHZ > $CURRENT_MHZ * 1.5" | bc -l 2>/dev/null || echo 0) )); then
            break
        fi
        sleep 0.01
    done
    
    END_TIME=$(date +%s%N)
    wait $STRESS_PID 2>/dev/null || true
    
    RAMP_NS=$(( (END_TIME - START_TIME) / 1000000 ))
    echo "$RAMP_NS"
}

measure_memory_latency() {
    # Use lmbench lat_mem_rd if available, otherwise use stress-ng
    print_info "Measuring memory access latency..."
    
    if command -v lat_mem_rd > /dev/null 2>&1; then
        # Get L3 and DRAM latency
        RESULT=$(lat_mem_rd 64M 128 2>/dev/null | tail -5)
        echo "$RESULT"
    else
        # Fallback to stress-ng timing
        RESULT=$( { time stress-ng --vm 1 --vm-bytes 100M --timeout 2s ; } 2>&1 | grep real )
        echo "$RESULT"
    fi
}

measure_cache_latency() {
    print_info "Measuring L1/L2/L3 cache latency..."
    
    if command -v lat_mem_rd > /dev/null 2>&1; then
        # Small size = L1 cache, medium = L2, large = L3
        L1=$(lat_mem_rd 1M 128 2>/dev/null | grep -oP '\d+\.\d+' | head -1)
        L2=$(lat_mem_rd 4M 128 2>/dev/null | grep -oP '\d+\.\d+' | head -1)
        L3=$(lat_mem_rd 32M 128 2>/dev/null | grep -oP '\d+\.\d+' | head -1)
        echo "L1=${L1}ns L2=${L2}ns L3=${L3}ns"
    else
        echo "lmbench not installed - skipping cache latency test"
    fi
}

measure_numa_latency() {
    print_info "Measuring NUMA local vs remote latency..."
    
    LOCAL_OPS=$(numactl --cpunodebind=0 --membind=0 stress-ng --vm 2 --vm-bytes 512M --metrics-brief --timeout 3s 2>&1 | grep "vm " | awk '{print $3}')
    REMOTE_OPS=$(numactl --cpunodebind=0 --membind=1 stress-ng --vm 2 --vm-bytes 512M --metrics-brief --timeout 3s 2>&1 | grep "vm " | awk '{print $3}')
    
    echo "local_ops=$LOCAL_OPS remote_ops=$REMOTE_OPS"
}

measure_interrupt_latency() {
    print_info "Measuring interrupt handling latency..."
    
    # Measure time to process 1000 interrupts
    INTERFACE=$(get_interface)
    START_IRQ=$(cat /proc/interrupts | grep "${INTERFACE}-TxRx-0" | awk -F: '{print $2}' | awk '{print $1}')
    
    # Generate some traffic
    ping -c 10 -i 0.1 localhost > /dev/null 2>&1
    
    END_IRQ=$(cat /proc/interrupts | grep "${INTERFACE}-TxRx-0" | awk -F: '{print $2}' | awk '{print $1}')
    
    if [[ "$START_IRQ" != "$END_IRQ" ]]; then
        echo "Interrupts processed: $((END_IRQ - START_IRQ))"
    else
        echo "No interrupt change detected"
    fi
}

measure_network_latency() {
    print_info "Measuring network loopback latency..."
    
    # Measure ping latency to localhost (should be very low)
    PING_RESULT=$(ping -c 5 -i 0.2 localhost 2>/dev/null | tail -1 | awk -F'/' '{print $5}')
    echo "Loopback latency: ${PING_RESULT}ms"
}

measure_context_switch_latency() {
    print_info "Measuring context switch latency..."
    
    if command -v lat_ctx > /dev/null 2>&1; then
        RESULT=$(lat_ctx -s 0 2 2>/dev/null)
        echo "$RESULT"
    else
        echo "lat_ctx not available - skipping context switch test"
    fi
}

measure_syscall_latency() {
    print_info "Measuring system call latency..."
    
    if command -v lat_syscall > /dev/null 2>&1; then
        RESULT=$(lat_syscall null 2>/dev/null)
        echo "$RESULT"
    else
        echo "lat_syscall not available - skipping syscall test"
    fi
}

# ==============================================================================
# COMPREHENSIVE BEFORE STATE CAPTURE
# ==============================================================================

capture_before_state() {
    print_header "CAPTURING BASELINE STATE (BEFORE TUNING)"
    
    print_info "Running comprehensive latency measurements..."
    print_info "This will take approximately 30-60 seconds..."
    
    # CPU Metrics
    BEFORE_METRICS["cpu_mhz"]=$(get_cpu_mhz)
    BEFORE_METRICS["cpu_max_mhz"]=$(lscpu | grep "CPU max MHz" | awk '{print $4}')
    BEFORE_METRICS["governor"]=$(get_governor)
    BEFORE_METRICS["threads_per_core"]=$(get_threads_per_core)
    BEFORE_METRICS["numa_nodes"]=$(get_numa_nodes)
    
    # Latency Metrics
    BEFORE_METRICS["freq_ramp_ms"]=$(measure_cpu_frequency_latency)
    BEFORE_METRICS["memory_latency"]=$(measure_memory_latency | tail -1)
    BEFORE_METRICS["cache_latency"]=$(measure_cache_latency)
    BEFORE_METRICS["numa_ops"]=$(measure_numa_latency)
    BEFORE_METRICS["network_latency"]=$(measure_network_latency)
    BEFORE_METRICS["context_switch"]=$(measure_context_switch_latency | tail -1)
    BEFORE_METRICS["syscall_latency"]=$(measure_syscall_latency | tail -1)
    
    print_subheader "BEFORE STATE SUMMARY"
    print_metric "CPU Frequency" "${BEFORE_METRICS["cpu_mhz"]} MHz (Max: ${BEFORE_METRICS["cpu_max_mhz"]} MHz)"
    print_metric "Governor" "${BEFORE_METRICS["governor"]}"
    print_metric "Threads/Core" "${BEFORE_METRICS["threads_per_core"]}"
    print_metric "NUMA Nodes" "${BEFORE_METRICS["numa_nodes"]}"
    print_metric "Frequency Ramp" "${BEFORE_METRICS["freq_ramp_ms"]} ms"
    print_metric "Cache Latency" "${BEFORE_METRICS["cache_latency"]}"
    print_metric "NUMA Ops" "${BEFORE_METRICS["numa_ops"]}"
    print_metric "Network Latency" "${BEFORE_METRICS["network_latency"]}"
    print_metric "Context Switch" "${BEFORE_METRICS["context_switch"]}"
    print_metric "Syscall Latency" "${BEFORE_METRICS["syscall_latency"]}"
    
    pause_for_reading
}

# ==============================================================================
# TUNING FUNCTIONS (Each with before/after measurement)
# ==============================================================================

tune_cpu_governor() {
    print_header "TUNING: CPU GOVERNOR → PERFORMANCE"
    
    print_subheader "Before"
    print_metric "Governor" "$(get_governor)"
    print_metric "CPU MHz" "$(get_cpu_mhz)"
    BEFORE_RAMP=$(measure_cpu_frequency_latency)
    print_metric "Frequency Ramp" "${BEFORE_RAMP} ms"
    
    print_explanation "Changing from $(get_governor) to performance..."
    
    # Apply change
    for i in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        echo performance | sudo tee "$i" > /dev/null 2>&1 || true
    done
    
    # Small wait for frequency to stabilize
    sleep 1
    
    print_subheader "After"
    print_metric "Governor" "$(get_governor)"
    print_metric "CPU MHz" "$(get_cpu_mhz)"
    AFTER_RAMP=$(measure_cpu_frequency_latency)
    print_metric "Frequency Ramp" "${AFTER_RAMP} ms"
    
    # Store improvement
    IMPROVEMENTS["governor"]="$(get_governor)"
    IMPROVEMENTS["freq_ramp_before"]="$BEFORE_RAMP"
    IMPROVEMENTS["freq_ramp_after"]="$AFTER_RAMP"
    
    if [[ "$(get_governor)" == "performance" ]]; then
        print_success "Governor set to performance"
    fi
    
    pause_for_reading
}

tune_network_ring_buffer() {
    print_header "TUNING: NETWORK RING BUFFER SIZE"
    
    INTERFACE=$(get_interface)
    print_subheader "Before"
    print_metric "RX Ring" "$(sudo ethtool -g $INTERFACE | grep -A 5 'Current' | grep 'RX:' | awk '{print $2}')"
    print_metric "TX Ring" "$(sudo ethtool -g $INTERFACE | grep -A 5 'Current' | grep 'TX:' | awk '{print $2}')"
    
    BEFORE_NET_LAT=$(measure_network_latency)
    print_metric "Loopback Latency" "$BEFORE_NET_LAT"
    
    print_explanation "Reducing ring buffer from 512 to 256 for lower latency..."
    
    # Apply change
    sudo ethtool -G $INTERFACE rx 256 tx 256 2>/dev/null || print_warning "Could not change ring buffer"
    
    print_subheader "After"
    print_metric "RX Ring" "$(sudo ethtool -g $INTERFACE | grep -A 5 'Current' | grep 'RX:' | awk '{print $2}')"
    print_metric "TX Ring" "$(sudo ethtool -g $INTERFACE | grep -A 5 'Current' | grep 'TX:' | awk '{print $2}')"
    AFTER_NET_LAT=$(measure_network_latency)
    print_metric "Loopback Latency" "$AFTER_NET_LAT"
    
    IMPROVEMENTS["ring_buffer_before"]="512"
    IMPROVEMENTS["ring_buffer_after"]="256"
    IMPROVEMENTS["net_lat_before"]="$BEFORE_NET_LAT"
    IMPROVEMENTS["net_lat_after"]="$AFTER_NET_LAT"
    
    pause_for_reading
}

tune_irq_affinity() {
    print_header "TUNING: IRQ AFFINITY TO NUMA NODE 1"
    
    INTERFACE=$(get_interface)
    print_subheader "Current IRQ Distribution (first 5 queues)"
    IRQ_LIST=$(sudo cat /proc/interrupts | grep "${INTERFACE}-TxRx" | awk -F: '{print $1}' | head -5)
    for irq in $IRQ_LIST; do
        CPU_LIST=$(cat /proc/irq/$irq/smp_affinity_list 2>/dev/null)
        echo "  IRQ $irq: CPUs: $CPU_LIST"
    done
    
    print_explanation "Pinning IRQs to NUMA Node 1 (CPUs 12-23) to keep Node 0 free for trading..."
    print_explanation "Hex mask for CPUs 12-23: fff000"
    
    # Apply change - pin all network IRQs to Node 1 (CPUs 12-23)
    ALL_IRQS=$(sudo cat /proc/interrupts | grep "${INTERFACE}-TxRx" | awk -F: '{print $1}')
    for irq in $ALL_IRQS; do
        echo fff000 | sudo tee /proc/irq/$irq/smp_affinity > /dev/null 2>&1 || true
    done
    
    print_subheader "After (first 5 queues)"
    for irq in $IRQ_LIST; do
        CPU_LIST=$(cat /proc/irq/$irq/smp_affinity_list 2>/dev/null)
        echo "  IRQ $irq: CPUs: $CPU_LIST"
    done
    
    IMPROVEMENTS["irq_pinned"]="All ${INTERFACE} IRQs pinned to CPUs 12-23 (Node 1)"
    
    print_success "IRQ affinity configured"
    pause_for_reading
}

# ==============================================================================
# COMPREHENSIVE AFTER STATE CAPTURE
# ==============================================================================

capture_after_state() {
    print_header "CAPTURING FINAL STATE (AFTER TUNING)"
    
    print_info "Running final comprehensive latency measurements..."
    
    # CPU Metrics
    AFTER_METRICS["cpu_mhz"]=$(get_cpu_mhz)
    AFTER_METRICS["cpu_max_mhz"]=$(lscpu | grep "CPU max MHz" | awk '{print $4}')
    AFTER_METRICS["governor"]=$(get_governor)
    AFTER_METRICS["threads_per_core"]=$(get_threads_per_core)
    AFTER_METRICS["numa_nodes"]=$(get_numa_nodes)
    
    # Latency Metrics
    AFTER_METRICS["freq_ramp_ms"]=$(measure_cpu_frequency_latency)
    AFTER_METRICS["memory_latency"]=$(measure_memory_latency | tail -1)
    AFTER_METRICS["cache_latency"]=$(measure_cache_latency)
    AFTER_METRICS["numa_ops"]=$(measure_numa_latency)
    AFTER_METRICS["network_latency"]=$(measure_network_latency)
    AFTER_METRICS["context_switch"]=$(measure_context_switch_latency | tail -1)
    AFTER_METRICS["syscall_latency"]=$(measure_syscall_latency | tail -1)
    
    print_subheader "AFTER STATE SUMMARY"
    print_metric "CPU Frequency" "${AFTER_METRICS["cpu_mhz"]} MHz (Max: ${AFTER_METRICS["cpu_max_mhz"]} MHz)"
    print_metric "Governor" "${AFTER_METRICS["governor"]}"
    print_metric "Threads/Core" "${AFTER_METRICS["threads_per_core"]}"
    print_metric "NUMA Nodes" "${AFTER_METRICS["numa_nodes"]}"
    print_metric "Frequency Ramp" "${AFTER_METRICS["freq_ramp_ms"]} ms"
    print_metric "Cache Latency" "${AFTER_METRICS["cache_latency"]}"
    print_metric "NUMA Ops" "${AFTER_METRICS["numa_ops"]}"
    print_metric "Network Latency" "${AFTER_METRICS["network_latency"]}"
    print_metric "Context Switch" "${AFTER_METRICS["context_switch"]}"
    print_metric "Syscall Latency" "${AFTER_METRICS["syscall_latency"]}"
    
    pause_for_reading
}

# ==============================================================================
# FINAL REPORT GENERATION
# ==============================================================================

generate_report() {
    print_header "GENERATING HFT TUNING REPORT"
    
    {
        echo "════════════════════════════════════════════════════════════════"
        echo "           HFT SERVER TUNING REPORT"
        echo "           $(date)"
        echo "════════════════════════════════════════════════════════════════"
        echo ""
        echo "Server: $(hostname)"
        echo "CPU: $(lscpu | grep 'Model name' | awk -F: '{print $2}' | xargs)"
        echo "Kernel: $(uname -r)"
        echo ""
        echo "────────────────────────────────────────────────────────────────"
        echo "  METRIC COMPARISON: BEFORE vs AFTER"
        echo "────────────────────────────────────────────────────────────────"
        echo ""
        
        # CPU Metrics
        echo "CPU CONFIGURATION:"
        printf "  %-25s %15s %15s %10s\n" "Metric" "Before" "After" "Status"
        printf "  %-25s %15s %15s %10s\n" "─────────────────" "──────" "─────" "──────"
        printf "  %-25s %15s %15s %10s\n" \
            "Governor" \
            "${BEFORE_METRICS["governor"]}" \
            "${AFTER_METRICS["governor"]}" \
            "$( [[ "${BEFORE_METRICS["governor"]}" != "${AFTER_METRICS["governor"]}" ]] && echo "✓ CHANGED" || echo "NO CHANGE" )"
        printf "  %-25s %15s %15s %10s\n" \
            "CPU MHz (idle)" \
            "${BEFORE_METRICS["cpu_mhz"]}" \
            "${AFTER_METRICS["cpu_mhz"]}" \
            "$( [[ "${BEFORE_METRICS["cpu_mhz"]}" != "${AFTER_METRICS["cpu_mhz"]}" ]] && echo "✓ CHANGED" || echo "NO CHANGE" )"
        printf "  %-25s %15s %15s %10s\n" \
            "Frequency Ramp (ms)" \
            "${BEFORE_METRICS["freq_ramp_ms"]}" \
            "${AFTER_METRICS["freq_ramp_ms"]}" \
            "$( [[ "${BEFORE_METRICS["freq_ramp_ms"]}" != "${AFTER_METRICS["freq_ramp_ms"]}" ]] && echo "✓ CHANGED" || echo "NO CHANGE" )"
        printf "  %-25s %15s %15s %10s\n" \
            "Threads/Core" \
            "${BEFORE_METRICS["threads_per_core"]}" \
            "${AFTER_METRICS["threads_per_core"]}" \
            "$( [[ "${BEFORE_METRICS["threads_per_core"]}" != "${AFTER_METRICS["threads_per_core"]}" ]] && echo "✓ CHANGED" || echo "NO CHANGE" )"
        printf "  %-25s %15s %15s %10s\n" \
            "NUMA Nodes" \
            "${BEFORE_METRICS["numa_nodes"]}" \
            "${AFTER_METRICS["numa_nodes"]}" \
            "$( [[ "${BEFORE_METRICS["numa_nodes"]}" != "${AFTER_METRICS["numa_nodes"]}" ]] && echo "✓ CHANGED" || echo "NO CHANGE" )"
        echo ""
        
        # Latency Metrics
        echo "LATENCY METRICS:"
        printf "  %-25s %15s %15s %10s\n" "Metric" "Before" "After" "Status"
        printf "  %-25s %15s %15s %10s\n" "─────────────────" "──────" "─────" "──────"
        printf "  %-25s %15s %15s %10s\n" \
            "Cache Latency" \
            "${BEFORE_METRICS["cache_latency"]}" \
            "${AFTER_METRICS["cache_latency"]}" \
            "$( [[ "${BEFORE_METRICS["cache_latency"]}" != "${AFTER_METRICS["cache_latency"]}" ]] && echo "✓ CHANGED" || echo "NO CHANGE" )"
        printf "  %-25s %15s %15s %10s\n" \
            "NUMA Ops/sec" \
            "${BEFORE_METRICS["numa_ops"]}" \
            "${AFTER_METRICS["numa_ops"]}" \
            "$( [[ "${BEFORE_METRICS["numa_ops"]}" != "${AFTER_METRICS["numa_ops"]}" ]] && echo "✓ CHANGED" || echo "NO CHANGE" )"
        printf "  %-25s %15s %15s %10s\n" \
            "Network Latency" \
            "${BEFORE_METRICS["network_latency"]}" \
            "${AFTER_METRICS["network_latency"]}" \
            "$( [[ "${BEFORE_METRICS["network_latency"]}" != "${AFTER_METRICS["network_latency"]}" ]] && echo "✓ CHANGED" || echo "NO CHANGE" )"
        printf "  %-25s %15s %15s %10s\n" \
            "Context Switch" \
            "${BEFORE_METRICS["context_switch"]}" \
            "${AFTER_METRICS["context_switch"]}" \
            "$( [[ "${BEFORE_METRICS["context_switch"]}" != "${AFTER_METRICS["context_switch"]}" ]] && echo "✓ CHANGED" || echo "NO CHANGE" )"
        printf "  %-25s %15s %15s %10s\n" \
            "Syscall Latency" \
            "${BEFORE_METRICS["syscall_latency"]}" \
            "${AFTER_METRICS["syscall_latency"]}" \
            "$( [[ "${BEFORE_METRICS["syscall_latency"]}" != "${AFTER_METRICS["syscall_latency"]}" ]] && echo "✓ CHANGED" || echo "NO CHANGE" )"
        echo ""
        
        # Improvements
        echo "────────────────────────────────────────────────────────────────"
        echo "  CHANGES APPLIED"
        echo "────────────────────────────────────────────────────────────────"
        echo ""
        for key in "${!IMPROVEMENTS[@]}"; do
            echo "  ✓ ${key}: ${IMPROVEMENTS[$key]}"
        done
        echo ""
        
        # Recommendations
        echo "────────────────────────────────────────────────────────────────"
        echo "  RECOMMENDATIONS FOR FURTHER OPTIMIZATION"
        echo "────────────────────────────────────────────────────────────────"
        echo ""
        echo "  1. Apply CPU isolation via GRUB (requires reboot):"
        echo "     isolcpus=0-11 nohz_full=0-11 rcu_nocbs=0-11 mitigations=off"
        echo ""
        echo "  2. Install DPDK for kernel bypass networking"
        echo "     sudo apt install dpdk dpdk-dev"
        echo ""
        echo "  3. Configure real-time scheduling for trading app:"
        echo "     sudo chrt -f 99 ./trading_app"
        echo "     sudo taskset -c 0 ./trading_app"
        echo ""
        echo "  4. Disable unnecessary services:"
        echo "     sudo systemctl disable --now snapd.service"
        echo "     sudo systemctl disable --now systemd-timesyncd.service"
        echo ""
        echo "  5. Consider using a custom kernel with PREEMPT_RT patches"
        echo ""
        
        echo "════════════════════════════════════════════════════════════════"
        echo "  Report generated: $(date)"
        echo "  Log file: $LOGFILE"
        echo "════════════════════════════════════════════════════════════════"
    } | tee "$REPORT_FILE"
    
    print_success "Report saved to: $REPORT_FILE"
}

# ==============================================================================
# MAIN EXECUTION
# ==============================================================================

main() {
    clear
    echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}       HFT SERVER TUNING WITH LATENCY BENCHMARKING${NC}"
    echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
    echo ""
    print_info "This script will:"
    print_info "  1. Measure current latency metrics"
    print_info "  2. Apply HFT optimizations one-by-one"
    print_info "  3. Re-measure after each change"
    print_info "  4. Generate a comprehensive before/after report"
    echo ""
    print_info "Report will be saved to: $REPORT_FILE"
    echo ""
    pause_for_reading
    
    # Capture baseline
    capture_before_state
    
    # Apply tunings with measurements
    tune_cpu_governor
    tune_network_ring_buffer
    tune_irq_affinity
    
    # Capture final state
    capture_after_state
    
    # Generate report
    generate_report
    
    echo ""
    print_success "HFT tuning complete!"
    print_success "Review the report: $REPORT_FILE"
    echo ""
}

# Run
main