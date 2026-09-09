#!/usr/bin/env bash
# ==============================================================================
# HFT SIMULATION VM RECREATION & AUTOMATED PROVISIONING SCRIPT
# ==============================================================================
# Purpose:
#   1. Cleanly destroys any existing AlmaLinux simulation VM ('hft-alma').
#   2. Provisions a fresh Copy-on-Write AlmaLinux 9 VM using setup_simulation.sh.
#   3. Deploys SSH credentials, toolchains, and clones the git repository
#      using setup_remote_server.sh.
#   4. Executes ~/hft/install.sh on the VM to install tmux, git, and the agy CLI.
#   5. Validates the end-to-end environment and outputs connection commands.
#
# Usage:
#   ./recreate_simulation.sh [OPTIONS]
#
# Options:
#   -y, --yes          Bypass confirmation prompt and destroy VM automatically.
#   --skip-install     Provision remote server and clone git repo, but skip install.sh.
#   -h, --help         Show this help manual.
# ==============================================================================

set -euo pipefail

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
NC='\033[0m'

print_banner() {
    echo -e "${BLUE}${BOLD}"
    cat << "EOF_BANNER"
  ╔══════════════════════════════════════════════════════════════════════════╗
  ║       🔄 HFT SIMULATION VM RECREATION & PROVISIONING SUITE 🔄           ║
  ║      Destroy • Rebuild AlmaLinux 9 • Deploy Git Repo • Install AGY       ║
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

print_step() {
    echo -e "\n${CYAN}${BOLD}─── $1 ───${NC}"
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

# ------------------------------------------------------------------------------
# 2. DIRECTORY RESOLUTION & ARGUMENT PARSING
# ------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -d "$SCRIPT_DIR/simulation" ]; then
    REPO_ROOT="$SCRIPT_DIR"
    SIM_DIR="$SCRIPT_DIR/simulation"
elif [ -f "$SCRIPT_DIR/setup_simulation.sh" ]; then
    REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
    SIM_DIR="$SCRIPT_DIR"
else
    REPO_ROOT="$SCRIPT_DIR"
    SIM_DIR="$SCRIPT_DIR/simulation"
fi

AUTO_CONFIRM=false
RUN_INSTALL=true
GIT_REPO="git@github.com:wazzuck/hft.git"
TARGET_DIR="~/hft"
VM_NAME="hft-alma"
SSH_ALIAS="hft-sim"

show_help() {
    print_banner
    cat << EOF_HELP
Usage: $(basename "$0") [OPTIONS]

Workflow:
  1. Destroys the active AlmaLinux KVM VM ('${VM_NAME}') and wipes overlay state.
  2. Provisions a fresh Copy-on-Write AlmaLinux 9 VM using host CPU passthrough.
  3. Runs setup_remote_server.sh to deploy SSH keys and clone ${GIT_REPO}.
  4. Connects via SSH and executes ~/hft/install.sh (tmux, git, agy CLI).
  5. Verifies environment readiness.

Options:
  -y, --yes, --force   Auto-confirm VM teardown without interactive prompt.
  --skip-install       Skip running ~/hft/install.sh inside the new VM.
  -h, --help           Show this help message.

Examples:
  ./recreate_simulation.sh
  ./recreate_simulation.sh -y
  ./recreate_simulation.sh --skip-install
EOF_HELP
    echo ""
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -y|--yes|--force)
            AUTO_CONFIRM=true
            shift
            ;;
        --skip-install)
            RUN_INSTALL=false
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            print_error "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

# ------------------------------------------------------------------------------
# 3. PRE-FLIGHT CHECKS & CONFIRMATION
# ------------------------------------------------------------------------------
print_banner

if [ ! -f "$SIM_DIR/setup_simulation.sh" ]; then
    print_error "Cannot find setup_simulation.sh in '$SIM_DIR'."
    exit 1
fi

if [ ! -f "$REPO_ROOT/setup_remote_server.sh" ]; then
    print_error "Cannot find setup_remote_server.sh in '$REPO_ROOT'."
    exit 1
fi

if [ "$AUTO_CONFIRM" = false ]; then
    echo -e "${YELLOW}${BOLD}ATTENTION:${NC} This operation will destroy the current AlmaLinux simulation VM"
    echo -e "           ('${VM_NAME}') and replace it with a fresh, clean instance."
    echo -e "           Any uncommitted changes inside the VM will be permanently lost."
    echo ""
    read -rp "  Proceed with VM recreation? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[yY]([eE][sS])?$ ]]; then
        print_info "Operation cancelled by user."
        exit 0
    fi
fi

# ------------------------------------------------------------------------------
# STEP 1: DESTROY EXISTING VM
# ------------------------------------------------------------------------------
print_header "STEP 1: DESTROYING EXISTING SIMULATION VM"

print_info "Terminating and wiping current '${VM_NAME}' state..."
(
    cd "$SIM_DIR"
    bash setup_simulation.sh destroy
)
print_success "Previous VM destroyed cleanly."

# ------------------------------------------------------------------------------
# STEP 2: CREATE FRESH ALMALINUX VM
# ------------------------------------------------------------------------------
print_header "STEP 2: CREATING FRESH ALMALINUX 9 VM VIA CLOUD-INIT"

print_info "Provisioning new VM from base image with host CPU topology..."
(
    cd "$SIM_DIR"
    bash setup_simulation.sh create
)

# Extract new VM IP address
print_info "Detecting dynamic IP address for '${VM_NAME}'..."
NEW_IP=""
for _ in {1..30}; do
    NEW_IP="$(virsh domifaddr "$VM_NAME" 2>/dev/null | awk '/ipv4/ {sub(/\/.*$/, "", $4); print $4}' | head -n 1 || true)"
    if [ -n "$NEW_IP" ]; then
        break
    fi
    sleep 1
done

if [ -z "$NEW_IP" ]; then
    print_error "Failed to acquire IP address for VM '${VM_NAME}'."
    exit 1
fi

print_success "VM is running with IP: ${NEW_IP}"

# Synchronize IP in ~/.ssh/config if hft-sim entry exists
if [ -f "$HOME/.ssh/config" ] && grep -q "Host.*hft-sim" "$HOME/.ssh/config"; then
    CURRENT_CONFIG_IP="$(awk '/Host.*hft-sim/{flag=1; next} flag && /HostName/{print $2; flag=0}' "$HOME/.ssh/config" || true)"
    if [ -n "$CURRENT_CONFIG_IP" ] && [ "$CURRENT_CONFIG_IP" != "$NEW_IP" ]; then
        print_info "Updating ~/.ssh/config HostName for 'hft-sim' from $CURRENT_CONFIG_IP to $NEW_IP..."
        sed -i "/Host.*hft-sim/,/Host /{s/HostName .*/HostName $NEW_IP/}" "$HOME/.ssh/config"
        print_success "Updated ~/.ssh/config with current VM IP."
    fi
fi

# ------------------------------------------------------------------------------
# STEP 3: PROVISION REMOTE SERVER & CLONE GIT REPOSITORY
# ------------------------------------------------------------------------------
print_header "STEP 3: RUNNING setup_remote_server.sh (DEPLOY KEYS & CLONE REPO)"

print_info "Executing remote provisioning against '${SSH_ALIAS}' (${NEW_IP})..."
bash "$REPO_ROOT/setup_remote_server.sh" "$SSH_ALIAS" \
    --repo "$GIT_REPO" \
    --dir "$TARGET_DIR"

print_success "Remote server provisioned and repository cloned to ${TARGET_DIR}."

# ------------------------------------------------------------------------------
# STEP 4: RUN install.sh ON THE ALMALINUX VM
# ------------------------------------------------------------------------------
if [ "$RUN_INSTALL" = true ]; then
    print_header "STEP 4: RUNNING ~/hft/install.sh (TMUX, GIT & AGY CLI)"

    print_info "Connecting to VM to execute installation script..."
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$SSH_ALIAS" "bash -s" << 'EOF_REMOTE_INSTALL'
set -euo pipefail
echo "  -> Navigating to ~/hft..."
cd ~/hft

if [ -f "install.sh" ]; then
    echo "  -> Setting executable permission on install.sh..."
    chmod +x install.sh
    echo "  -> Executing install.sh..."
    ./install.sh
else
    echo "  ! Error: ~/hft/install.sh was not found!"
    exit 1
fi
EOF_REMOTE_INSTALL

    print_success "install.sh executed successfully on AlmaLinux VM."
else
    print_info "Skipping install.sh (--skip-install specified)."
fi

# ------------------------------------------------------------------------------
# STEP 5: FINAL END-TO-END VERIFICATION
# ------------------------------------------------------------------------------
print_header "STEP 5: VERIFYING REMOTE ENVIRONMENT"

echo ""
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$SSH_ALIAS" "bash -s" << 'EOF_VERIFY'
echo "  • Operating System : $(cat /etc/redhat-release 2>/dev/null || uname -sr)"
echo "  • Git Version      : $(git --version 2>/dev/null || echo 'Not installed')"
echo "  • Tmux Version     : $(tmux -V 2>/dev/null || echo 'Not installed')"
if command -v agy >/dev/null 2>&1; then
    echo "  • Antigravity CLI  : $(agy --version 2>/dev/null || which agy)"
elif [ -f "$HOME/.local/bin/agy" ]; then
    echo "  • Antigravity CLI  : Installed at $HOME/.local/bin/agy"
else
    echo "  • Antigravity CLI  : Initialized (Run 'source ~/.bashrc' on login)"
fi
echo "  • Repo Directory   : $(ls -d ~/hft 2>/dev/null || echo 'Missing') ($(git -C ~/hft rev-parse --short HEAD 2>/dev/null || echo 'no-git'))"
EOF_VERIFY

echo ""
echo -e "${GREEN}${BOLD}══════════════════════════════════════════════════════════════════════════${NC}"
echo -e "${WHITE}${BOLD}  🎉 SIMULATION VM RECREATION COMPLETE!${NC}"
echo -e "${GREEN}${BOLD}══════════════════════════════════════════════════════════════════════════${NC}"
echo -e "  To connect to your pristine AlmaLinux test environment:"
echo -e "    ${CYAN}${BOLD}ssh ${SSH_ALIAS}${NC}"
echo -e "  or directly by IP:"
echo -e "    ${CYAN}${BOLD}ssh ${NEW_IP}${NC}"
echo ""
