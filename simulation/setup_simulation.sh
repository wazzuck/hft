#!/usr/bin/env bash
set -euo pipefail

# Ensure libvirt connects to system daemon and uses system Python
export LIBVIRT_DEFAULT_URI="qemu:///system"
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
unset PYTHONPATH

VM_NAME="hft-alma"
DISK_IMG="hft-instance.qcow2"
SEED_ISO="seed.iso"
RAM_MB=4096
VCPUS=2
LOCAL_USER="$(whoami)"

show_help() {
    cat << EOF_HELP
================================================================================
  HFT ALMALINUX SIMULATION ENVIRONMENT - USAGE GUIDE
================================================================================

This script manages a fast, disposable AlmaLinux 9 virtual machine on your
Debian host. It lets you simulate a remote bare-metal server locally so you can
practice HFT low-latency tuning, test kernel settings, and run benchmarks at \$0
cost before deploying to expensive paid hosts.

USAGE:
  ./setup_simulation.sh <command>

COMMANDS:
  create    Spin up a fresh, pristine AlmaLinux VM (~10 seconds).
            • Creates a temporary Copy-on-Write disk (base image is never modified).
            • Configures host CPU passthrough + cache topology for HFT tests.
            • Automatically bakes your SSH key into '${LOCAL_USER}', 'almalinux', and 'root'.

  ssh       Log directly into the running VM via SSH as '${LOCAL_USER}'.
            • You can also connect directly: ssh <VM_IP>

  status    Display whether the VM is running and show its current IP address.

  sync      Pull benchmark results from the VM (~/results/) into your local
            host directory (./results/).

  destroy   Instantly terminate the VM and erase the temporary disk.
            • Leaves zero leftover state, ready for your next clean experiment.

  help      Show this instruction screen (-h, --help).

TYPICAL EXPERIMENT WORKFLOW:
  1. Spin up a clean environment:
       ./setup_simulation.sh create

  2. Connect to the machine:
       ./setup_simulation.sh ssh
       (or: ssh \$(./setup_simulation.sh status | awk '/IP:/ {print \$2}'))

  3. Inside the VM, install tools and run benchmarks:
       sudo dnf install -y realtime-tests tuned tuned-profiles-cpu-partitioning numactl
       sudo tuned-adm profile network-latency
       mkdir -p ~/results
       sudo cyclictest -m -p99 -t2 -D 60 -q > ~/results/test1.txt
       exit

  4. Save results back to your Debian host:
       ./setup_simulation.sh sync

  5. Wipe the VM when finished:
       ./setup_simulation.sh destroy

================================================================================
EOF_HELP
}

# Locate base image in home directory or current directory
if [ -f "$HOME/almalinux9-base.qcow2" ]; then
    BASE_IMG="$HOME/almalinux9-base.qcow2"
elif [ -f "./almalinux9-base.qcow2" ]; then
    BASE_IMG="./almalinux9-base.qcow2"
else
    echo "[-] Error: AlmaLinux base image not found."
    echo "    Expected at: $HOME/almalinux9-base.qcow2"
    exit 1
fi

# Locate SSH private key
if [ -f "$HOME/.ssh/id_ed25519" ]; then
    SSH_KEY="$HOME/.ssh/id_ed25519"
elif [ -f "$HOME/.ssh/id_rsa" ]; then
    SSH_KEY="$HOME/.ssh/id_rsa"
else
    echo "[-] Error: No private key found in ~/.ssh (checked id_ed25519, id_rsa)"
    exit 1
fi

# Read public key
if [ -f "${SSH_KEY}.pub" ]; then
    PUB_KEY=$(cat "${SSH_KEY}.pub")
else
    PUB_KEY=$(ssh-keygen -y -f "$SSH_KEY")
    echo "$PUB_KEY" > "${SSH_KEY}.pub"
    chmod 644 "${SSH_KEY}.pub"
fi

get_ip() {
    virsh domifaddr "$VM_NAME" 2>/dev/null | awk '/ipv4/ {sub(/\/.*$/, "", $4); print $4}' | head -n 1
}

case "${1:-}" in
    create)
        if virsh dominfo "$VM_NAME" &>/dev/null; then
            echo "[!] VM '$VM_NAME' already exists. Run '$0 destroy' first."
            exit 1
        fi

        echo "[1/5] Generating cloud-init configuration (injecting keys for $LOCAL_USER, almalinux, and root)..."
        cat << EOF_USER > user-data
#cloud-config
disable_root: false
users:
  - name: almalinux
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: wheel
    shell: /bin/bash
    ssh_authorized_keys:
      - $PUB_KEY
  - name: $LOCAL_USER
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: wheel
    shell: /bin/bash
    ssh_authorized_keys:
      - $PUB_KEY
  - name: root
    ssh_authorized_keys:
      - $PUB_KEY
ssh_pwauth: false
EOF_USER

        cat << 'EOF_META' > meta-data
instance-id: hft-lab-01
local-hostname: hft-alma
EOF_META

        cloud-localds "$SEED_ISO" user-data meta-data
        chmod 664 "$SEED_ISO"

        echo "[2/5] Creating copy-on-write overlay disk from $BASE_IMG..."
        rm -f "$DISK_IMG"
        qemu-img create -f qcow2 -b "$BASE_IMG" -F qcow2 "$DISK_IMG" 30G
        chmod 664 "$DISK_IMG"

        echo "[3/5] Launching AlmaLinux with host CPU and cache topology..."
        virt-install \
            --name "$VM_NAME" \
            --memory "$RAM_MB" \
            --vcpus "$VCPUS" \
            --cpu host-passthrough,cache.mode=passthrough \
            --disk path="$(pwd)/$DISK_IMG",format=qcow2 \
            --disk path="$(pwd)/$SEED_ISO",device=cdrom \
            --os-variant almalinux9 \
            --network default,model=virtio \
            --graphics none \
            --import \
            --noautoconsole

        echo -n "[4/5] Waiting for VM to boot and acquire IP"
        VM_IP=""
        while [ -z "$VM_IP" ]; do
            echo -n "."
            sleep 2
            VM_IP=$(get_ip)
        done
        echo ""
        echo "[+] VM IP: $VM_IP"

        echo -n "[5/5] Waiting for SSH service to become ready"
        until ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=2 "$LOCAL_USER@$VM_IP" "true" 2>/dev/null; do
            echo -n "."
            sleep 1
        done
        echo ""
        echo "================================================================"
        echo "  AlmaLinux host is ready!"
        echo "  SSH with any of:"
        echo "    ssh $VM_IP"
        echo "    ssh $LOCAL_USER@$VM_IP"
        echo "    ssh almalinux@$VM_IP"
        echo "    ssh root@$VM_IP"
        echo "    $0 ssh"
        echo "================================================================"
        ;;

    ssh)
        VM_IP=$(get_ip)
        if [ -z "$VM_IP" ]; then
            echo "[-] VM '$VM_NAME' is not running or has no IP address."
            echo "    Run '$0 create' to spin it up."
            exit 1
        fi
        ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$LOCAL_USER@$VM_IP"
        ;;

    sync)
        VM_IP=$(get_ip)
        if [ -z "$VM_IP" ]; then
            echo "[-] VM '$VM_NAME' not running."
            exit 1
        fi
        mkdir -p results
        rsync -avz -e "ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null" "$LOCAL_USER@$VM_IP:~/results/" ./results/
        echo "[+] Results synced to local ./results directory."
        ;;

    destroy)
        echo "[*] Tearing down VM and erasing state..."
        virsh destroy "$VM_NAME" 2>/dev/null || true
        virsh undefine "$VM_NAME" --remove-all-storage 2>/dev/null || true
        rm -f "$DISK_IMG" "$SEED_ISO" user-data meta-data
        echo "[+] Cleaned up. Ready for the next test."
        ;;

    status)
        if virsh dominfo "$VM_NAME" &>/dev/null; then
            STATE=$(virsh domstate "$VM_NAME" 2>/dev/null || echo "unknown")
            IP=$(get_ip)
            echo "VM: $VM_NAME ($STATE)"
            echo "IP: ${IP:-waiting for IP}"
        else
            echo "VM '$VM_NAME' does not exist."
        fi
        ;;

    help|-h|--help|"")
        show_help
        ;;

    *)
        echo "[-] Unknown command: '$1'"
        echo ""
        show_help
        exit 1
        ;;
esac
