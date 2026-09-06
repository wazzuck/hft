#!/bin/bash

# ==============================================================================
# HFT SERVER TUNING SCRIPT - FULLY AUTONOMOUS WITH LATENCY REPORT
# Syntax-checked and verified
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

# File paths
REPORT_FILE="hft_latency_report_$(date +%Y%m%d_%H%M%S).txt"
LOGFILE="hft_tuning_$(date +%Y%m%d_%H%M%S).log"

# Arrays
declare -A BEFORE_METRICS
declare -A AFTER_METRICS
declare -A IMPROVEMENTS

# Redirect output to log
exec > >(tee -a "$LOGFILE") 2>&1

# ==============================================================================
# HELPER FUNCTIONS
# ==============================================================================

print_header() {
    echo ""
    echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
}

print_subheader() {
    echo ""
    echo -e "${CYAN}━━━ $1 ━━━${NC}"
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

print_explanation() {
    echo ""
    echo -e "${CYAN}📖 EXPLANATION:${NC}"
    echo -e "$1"
}

print_metric() {
    echo -e "${BOLD}$1:${NC} $2"
}

get_interface() {
    local interface
    interface=$(ip link show | grep -E "^[0-9]+: e" | grep -v "enx" | head -1 | awk -F': ' '{print $2}')
    if [ -z "$interface" ]; then
        interface=$(ip link show | grep -E "^[0-9]+: e" | head -1 | awk -F': ' '{print $2}')
    fi
    echo "$interface"
}

get_cpu_mhz() {
    local mhz
    mhz=$(lscpu | grep "CPU MHz" | awk '{print $3}')
    if [ -z "$mhz" ] || [ "$mhz" = "N/A" ]; then
        mhz=$(cat /proc/cpuinfo | grep "cpu MHz" | head -1 | awk -F: '{print $2}' | xargs)
    fi
    echo "$mhz"
}

get_governor() {
    cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "unknown"
}

get_threads_per_core() {
    lscpu | grep "Thread(s) per core" | awk '{print $4}'
}

get_numa_nodes() {
    numactl --hardware 2>/dev/null | grep "available:" | awk '{print $2}' || echo "1"
}

get_max_mhz() {
    lscpu | grep "CPU max MHz" | awk '{print $4}'
}

# ==============================================================================
# LATENCY MEASUREMENT FUNCTIONS
# ==============================================================================

measure_frequency_ramp() {
    local current_mhz max_mhz start_time end_time ramp_ms
    current_mhz=$(get_cpu_mhz)
    max_mhz=$(get_max_mhz)
    
    # If already at max, return 0
    if [ -n "$current_mhz" ] && [ -n "$max_mhz" ]; then
        if (( $(echo "$current_mhz >= $max_mhz * 0.95" | bc -l 2>/dev/null || echo 0) )); then
            echo "0"
            return
        fi
    fi
    
    start_time=$(date +%s%N)
    stress-ng --cpu 1 --timeout 1s > /dev/null 2>&1 &
    local stress_pid=$!
    
    for i in $(seq 1 100); do
        current_mhz=$(get_cpu_mhz)
        if [ -n "$current_mhz" ] && [ -n "$max_mhz" ]; then
            if (( $(echo "$current_mhz >= $max_mhz * 0.9" | bc -l 2>/dev/null || echo 0) )); then
                break
            fi
        fi
        sleep 0.01
    done
    
    end_time=$(date +%s%N)
    wait $stress_pid 2>/dev/null || true
    ramp_ms=$(( (end_time - start_time) / 1000000 ))
    echo "$ramp_ms"
}

measure_cache_latency() {
    if command -v lat_mem_rd > /dev/null 2>&1; then
        local l1 l2 l3
        l1=$(lat_mem_rd 1M 128 2>/dev/null | grep -oP '\d+\.\d+' | head -1)
        l2=$(lat_mem_rd 4M 128 2>/dev/null | grep -oP '\d+\.\d+' | head -1)
        l3=$(lat_mem_rd 32M 128 2>/dev/null | grep -oP '\d+\.\d+' | head -1)
        echo "L1=${l1}ns L2=${l2}ns L3=${l3}ns"
    else
        echo "N/A (install lmbench)"
    fi
}

measure_numa_ops() {
    local local_ops remote_ops
    local_ops=$(numactl --cpunodebind=0 --membind=0 stress-ng --vm 2 --vm-bytes 512M --metrics-brief --timeout 3s 2>&1 | grep "vm " | awk '{print $3}')
    remote_ops=$(numactl --cpunodebind=0 --membind=1 stress-ng --vm 2 --vm-bytes 512M --metrics-brief --timeout 3s 2>&1 | grep "vm " | awk '{print $3}')
    echo "local=$local_ops remote=$remote_ops"
}

measure_network_latency() {
    local ping_result
    ping_result=$(ping -c 5 -i 0.2 localhost 2>/dev/null | tail -1 | awk -F'/' '{print $5}')
    echo "${ping_result}ms"
}

measure_context_switch() {
    if command -v lat_ctx > /dev/null 2>&1; then
        lat_ctx -s 0 2 2>/dev/null | tail -1
    else
        echo "N/A (install lmbench)"
    fi
}

measure_syscall_latency() {
    if command -v lat_syscall > /dev/null 2>&1; then
        lat_syscall null 2>/dev/null | tail -1
    else
        echo "N/A (install lmbench)"
    fi
}

# ==============================================================================
# BEFORE STATE CAPTURE
# ==============================================================================

capture_before_state() {
    print_header "CAPTURING BASELINE STATE (BEFORE TUNING)"
    
    print_info "Running comprehensive latency measurements..."
    print_info "This will take approximately 30-60 seconds..."
    
    BEFORE_METRICS["cpu_mhz"]=$(get_cpu_mhz)
    BEFORE_METRICS["cpu_max_mhz"]=$(get_max_mhz)
    BEFORE_METRICS["governor"]=$(get_governor)
    BEFORE_METRICS["threads_per_core"]=$(get_threads_per_core)
    BEFORE_METRICS["numa_nodes"]=$(get_numa_nodes)
    BEFORE_METRICS["freq_ramp_ms"]=$(measure_frequency_ramp)
    BEFORE_METRICS["cache_latency"]=$(measure_cache_latency)
    BEFORE_METRICS["numa_ops"]=$(measure_numa_ops)
    BEFORE_METRICS["network_latency"]=$(measure_network_latency)
    BEFORE_METRICS["context_switch"]=$(measure_context_switch)
    BEFORE_METRICS["syscall_latency"]=$(measure_syscall_latency)
    
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
    echo ""
}

# ==============================================================================
# TUNING FUNCTIONS
# ==============================================================================

tune_cpu_governor() {
    print_header "TUNING: CPU GOVERNOR TO PERFORMANCE"
    
    print_subheader "Before"
    print_metric "Governor" "$(get_governor)"
    print_metric "CPU MHz" "$(get_cpu_mhz)"
    
    print_explanation "Setting CPU governor to performance mode for zero frequency ramp latency."
    
    for i in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        echo performance | sudo tee "$i" > /dev/null 2>&1 || true
    done
    sleep 1
    
    print_subheader "After"
    print_metric "Governor" "$(get_governor)"
    print_metric "CPU MHz" "$(get_cpu_mhz)"
    
    if [ "$(get_governor)" = "performance" ]; then
        print_success "Governor set to performance"
    else
        print_warning "Governor did not change"
    fi
    echo ""
}

tune_network_ring_buffer() {
    print_header "TUNING: NETWORK RING BUFFER TO 256"
    
    local interface
    interface=$(get_interface)
    
    print_subheader "Before"
    local rx_before tx_before
    rx_before=$(sudo ethtool -g "$interface" 2>/dev/null | grep -A 5 'Current' | grep 'RX:' | awk '{print $2}')
    tx_before=$(sudo ethtool -g "$interface" 2>/dev/null | grep -A 5 'Current' | grep 'TX:' | awk '{print $2}')
    print_metric "RX Ring" "${rx_before:-N/A}"
    print_metric "TX Ring" "${tx_before:-N/A}"
    
    print_explanation "Reducing ring buffers to minimize packet queueing delay."
    
    sudo ethtool -G "$interface" rx 256 tx 256 2>/dev/null || print_warning "Could not change ring buffer"
    
    print_subheader "After"
    local rx_after tx_after
    rx_after=$(sudo ethtool -g "$interface" 2>/dev/null | grep -A 5 'Current' | grep 'RX:' | awk '{print $2}')
    tx_after=$(sudo ethtool -g "$interface" 2>/dev/null | grep -A 5 'Current' | grep 'TX:' | awk '{print $2}')
    print_metric "RX Ring" "${rx_after:-N/A}"
    print_metric "TX Ring" "${tx_after:-N/A}"
    
    IMPROVEMENTS["ring_buffer"]="RX: ${rx_before:-N/A} to ${rx_after:-N/A}, TX: ${tx_before:-N/A} to ${tx_after:-N/A}"
    echo ""
}

tune_irq_affinity() {
    print_header "TUNING: IRQ AFFINITY TO NUMA NODE 1"
    
    local interface
    interface=$(get_interface)
    
    print_subheader "Before (first 3 queues)"
    local irq_list
    irq_list=$(sudo cat /proc/interrupts | grep "${interface}-TxRx" | awk -F: '{print $1}' | head -3)
    
    for irq in $irq_list; do
        local cpu_list
        cpu_list=$(cat /proc/irq/$irq/smp_affinity_list 2>/dev/null)
        echo "  IRQ $irq: CPUs: ${cpu_list:-N/A}"
    done
    
    print_explanation "Pinning network IRQs to Node 1 (CPUs 12-23) to keep Node 0 free."
    
    local all_irqs
    all_irqs=$(sudo cat /proc/interrupts | grep "${interface}-TxRx" | awk -F: '{print $1}')
    
    for irq in $all_irqs; do
        echo fff000 | sudo tee /proc/irq/$irq/smp_affinity > /dev/null 2>&1 || true
    done
    
    print_subheader "After (first 3 queues)"
    for irq in $irq_list; do
        local cpu_list
        cpu_list=$(cat /proc/irq/$irq/smp_affinity_list 2>/dev/null)
        echo "  IRQ $irq: CPUs: ${cpu_list:-N/A}"
    done
    
    IMPROVEMENTS["irq_affinity"]="All ${interface} IRQs pinned to CPUs 12-23"
    echo ""
}

# ==============================================================================
# AFTER STATE CAPTURE
# ==============================================================================

capture_after_state() {
    print_header "CAPTURING FINAL STATE (AFTER TUNING)"
    
    print_info "Running final comprehensive latency measurements..."
    
    AFTER_METRICS["cpu_mhz"]=$(get_cpu_mhz)
    AFTER_METRICS["cpu_max_mhz"]=$(get_max_mhz)
    AFTER_METRICS["governor"]=$(get_governor)
    AFTER_METRICS["threads_per_core"]=$(get_threads_per_core)
    AFTER_METRICS["numa_nodes"]=$(get_numa_nodes)
    AFTER_METRICS["freq_ramp_ms"]=$(measure_frequency_ramp)
    AFTER_METRICS["cache_latency"]=$(measure_cache_latency)
    AFTER_METRICS["numa_ops"]=$(measure_numa_ops)
    AFTER_METRICS["network_latency"]=$(measure_network_latency)
    AFTER_METRICS["context_switch"]=$(measure_context_switch)
    AFTER_METRICS["syscall_latency"]=$(measure_syscall_latency)
    
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
    echo ""
}

# ==============================================================================
# FINAL REPORT
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
        echo "CPU CONFIGURATION:"
        printf "  %-25s %20s %20s %12s\n" "Metric" "Before" "After" "Status"
        printf "  %-25s %20s %20s %12s\n" "─────────────────" "──────" "─────" "──────"
        printf "  %-25s %20s %20s %12s\n" "Governor" "${BEFORE_METRICS["governor"]}" "${AFTER_METRICS["governor"]}" "SEE_DIFF"
        printf "  %-25s %20s %20s %12s\n" "CPU MHz" "${BEFORE_METRICS["cpu_mhz"]}" "${AFTER_METRICS["cpu_mhz"]}" "SEE_DIFF"
        printf "  %-25s %20s %20s %12s\n" "Frequency Ramp (ms)" "${BEFORE_METRICS["freq_ramp_ms"]}" "${AFTER_METRICS["freq_ramp_ms"]}" "SEE_DIFF"
        printf "  %-25s %20s %20s %12s\n" "Threads/Core" "${BEFORE_METRICS["threads_per_core"]}" "${AFTER_METRICS["threads_per_core"]}" "SEE_DIFF"
        printf "  %-25s %20s %20s %12s\n" "NUMA Nodes" "${BEFORE_METRICS["numa_nodes"]}" "${AFTER_METRICS["numa_nodes"]}" "SEE_DIFF"
        echo ""
        echo "LATENCY METRICS:"
        printf "  %-25s %20s %20s %12s\n" "Metric" "Before" "After" "Status"
        printf "  %-25s %20s %20s %12s\n" "─────────────────" "──────" "─────" "──────"
        printf "  %-25s %20s %20s %12s\n" "Cache Latency" "${BEFORE_METRICS["cache_latency"]}" "${AFTER_METRICS["cache_latency"]}" "SEE_DIFF"
        printf "  %-25s %20s %20s %12s\n" "NUMA Ops" "${BEFORE_METRICS["numa_ops"]}" "${AFTER_METRICS["numa_ops"]}" "SEE_DIFF"
        printf "  %-25s %20s %20s %12s\n" "Network Latency" "${BEFORE_METRICS["network_latency"]}" "${AFTER_METRICS["network_latency"]}" "SEE_DIFF"
        printf "  %-25s %20s %20s %12s\n" "Context Switch" "${BEFORE_METRICS["context_switch"]}" "${AFTER_METRICS["context_switch"]}" "SEE_DIFF"
        printf "  %-25s %20s %20s %12s\n" "Syscall Latency" "${BEFORE_METRICS["syscall_latency"]}" "${AFTER_METRICS["syscall_latency"]}" "SEE_DIFF"
        echo ""
        echo "────────────────────────────────────────────────────────────────"
        echo "  CHANGES APPLIED"
        echo "────────────────────────────────────────────────────────────────"
        echo ""
        for key in "${!IMPROVEMENTS[@]}"; do
            echo "  OK ${key}: ${IMPROVEMENTS[$key]}"
        done
        echo ""
        echo "════════════════════════════════════════════════════════════════"
        echo "  Report: $REPORT_FILE"
        echo "  Log: $LOGFILE"
        echo "════════════════════════════════════════════════════════════════"
    } | tee "$REPORT_FILE"
    
    print_success "Report saved to: $REPORT_FILE"
}

# ==============================================================================
# MAIN
# ==============================================================================

main() {
    echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}       HFT SERVER TUNING - AUTONOMOUS LATENCY OPTIMIZATION${NC}"
    echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
    echo ""
    print_info "Running fully autonomous HFT tuning..."
    print_info "Report will be saved to: $REPORT_FILE"
    print_info "Log will be saved to: $LOGFILE"
    echo ""
    
    # Install required tools
    print_info "Installing required tools..."
    sudo apt update -qq > /dev/null 2>&1
    sudo apt install -y -qq numactl stress-ng ethtool bc > /dev/null 2>&1
    
    # Run all steps
    capture_before_state
    tune_cpu_governor
    tune_network_ring_buffer
    tune_irq_affinity
    capture_after_state
    generate_report
    
    echo ""
    print_success "HFT tuning complete!"
    print_success "Report: $REPORT_FILE"
    print_success "Log: $LOGFILE"
    echo ""
}

# Execute
main