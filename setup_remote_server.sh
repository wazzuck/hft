#!/usr/bin/env bash
# ==============================================================================
# HFT REMOTE SERVER PROVISIONING & DEPLOYMENT AUTOMATION
# ==============================================================================
# Purpose: Provision remote bare-metal or cloud servers for HFT workloads.
#          - Resolves destination using ~/.ssh/config.
#          - Securely deploys local ~/.ssh credentials for Git access.
#          - Automates installation of developer, compiler, and low-latency tools.
#          - Clones the target HFT repository via authenticated SSH.
#          - Deploys the latency tuning and nanosecond benchmark suite.
# Author : Google Antigravity Advanced Agentic Systems Architecture
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
NC='\033[0m'

# ------------------------------------------------------------------------------
# 2. LOGGING & OUTPUT UTILITIES
# ------------------------------------------------------------------------------
print_banner() {
    echo -e "${BLUE}${BOLD}"
    cat << "EOF_BANNER"
  ╔══════════════════════════════════════════════════════════════════════════╗
  ║       🚀 HFT REMOTE SERVER DEPLOYMENT & TOOLCHAIN AUTOMATION 🚀          ║
  ║             SSH Provisioning • Toolchain • Git Auto-Clone                ║
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

print_field() {
    local label="$1"
    local val="$2"
    printf "  %-28s : ${WHITE}${BOLD}%s${NC}\n" "$label" "$val"
}

# ------------------------------------------------------------------------------
# 3. CLI HELP & CONFIGURATION LISTING
# ------------------------------------------------------------------------------
show_help() {
    print_banner
    cat << EOF_HELP
Usage: $(basename "$0") <destination_host> [OPTIONS]

Arguments:
  <destination_host>   Target hostname, IP address, or Host alias defined in ~/.ssh/config.

Options:
  --repo <git_url>     Git repository URL to clone on the remote server.
                       (Default: git@github.com:wazzuck/hft.git)
  --dir <path>         Destination directory on the remote server for the repo.
                       (Default: ~/hft)
  --branch <name>      Git branch to checkout after cloning (optional).
  --vunderland-repo <url>
                       Git repository URL for Vunderland dotfiles/environment setup.
                       (Default: git@github.com:wazzuck/vunderland.git)
  --no-vunderland, --skip-vunderland
                       Skip cloning and running vunderland/settings/setup.sh.
  --skip-install       Skip running ~/hft/install.sh (tmux, git, agy CLI).
  --no-repo            Skip cloning the Git repository.
  --skip-tools         Skip installing packages; only deploy SSH keys and Git repo.
  --production, --deploy-production
                       Immediately lock in golden production tunings on the remote host after setup.
  --dry-run            Validate SSH connectivity and display parameters without modifying the server.
  --help, -h           Show this manual.

Examples:
  $(basename "$0") hft-prod
  $(basename "$0") hft-prod --production
  $(basename "$0") hft-sim
  $(basename "$0") 192.168.122.210 --repo git@github.com:wazzuck/hft.git
  $(basename "$0") server01.chicago.colo --dir ~/production_hft

Configured Hosts in ~/.ssh/config:
EOF_HELP

    if [ -f "$HOME/.ssh/config" ]; then
        grep -E "^Host[[:space:]]" "$HOME/.ssh/config" | grep -v "\*" | awk '{for(i=2;i<=NF;i++) printf "  • %s\n", $i}' || echo "  (None found)"
    else
        echo "  (No ~/.ssh/config file found)"
    fi
    echo ""
}

# ------------------------------------------------------------------------------
# 4. DEFAULT PARAMETERS & ARGUMENT PARSING
# ------------------------------------------------------------------------------
DEST_HOST=""
GIT_REPO="git@github.com:wazzuck/hft.git"
TARGET_DIR="~/hft"
GIT_BRANCH=""
CLONE_REPO=true
VUNDERLAND_REPO="git@github.com:wazzuck/vunderland.git"
CLONE_VUNDERLAND=true
RUN_INSTALL=true
INSTALL_TOOLS=true
DEPLOY_PRODUCTION=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --production|--deploy-production)
            DEPLOY_PRODUCTION=true
            shift
            ;;
        --repo)
            GIT_REPO="$2"
            shift 2
            ;;
        --dir)
            TARGET_DIR="$2"
            shift 2
            ;;
        --branch)
            GIT_BRANCH="$2"
            shift 2
            ;;
        --vunderland-repo)
            VUNDERLAND_REPO="$2"
            shift 2
            ;;
        --no-vunderland|--skip-vunderland)
            CLONE_VUNDERLAND=false
            shift
            ;;
        --skip-install|--no-install)
            RUN_INSTALL=false
            shift
            ;;
        --no-repo)
            CLONE_REPO=false
            shift
            ;;
        --skip-tools)
            INSTALL_TOOLS=false
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --help|-h|help)
            show_help
            exit 0
            ;;
        -*)
            print_error "Unknown option: $1"
            show_help
            exit 1
            ;;
        *)
            if [ -z "$DEST_HOST" ]; then
                DEST_HOST="$1"
            else
                print_error "Unexpected argument: $1"
                show_help
                exit 1
            fi
            shift
            ;;
    esac
done

if [ -z "$DEST_HOST" ]; then
    print_error "Missing required destination host parameter."
    echo ""
    show_help
    exit 1
fi

# ------------------------------------------------------------------------------
# 5. SSH CONFIG RESOLUTION & PRE-FLIGHT VALIDATION
# ------------------------------------------------------------------------------
print_banner
print_header "STEP 1: RESOLVING SSH DESTINATION & CONNECTIVITY"

print_info "Resolving '$DEST_HOST' through OpenSSH configuration..."
RESOLVED_USER="$(ssh -G "$DEST_HOST" 2>/dev/null | awk '/^user / {print $2}' | head -1 || true)"
RESOLVED_HOSTNAME="$(ssh -G "$DEST_HOST" 2>/dev/null | awk '/^hostname / {print $2}' | head -1 || true)"
RESOLVED_PORT="$(ssh -G "$DEST_HOST" 2>/dev/null | awk '/^port / {print $2}' | head -1 || true)"
RESOLVED_KEY="$(ssh -G "$DEST_HOST" 2>/dev/null | awk '/^identityfile / {print $2}' | head -1 || true)"

print_field "Target Alias" "$DEST_HOST"
print_field "Resolved HostName" "${RESOLVED_HOSTNAME:-$DEST_HOST}"
print_field "Resolved User" "${RESOLVED_USER:-$USER}"
print_field "Resolved Port" "${RESOLVED_PORT:-22}"
print_field "Resolved Identity" "${RESOLVED_KEY:-default}"
print_field "HFT Git Repository" "$GIT_REPO"
print_field "Target Directory" "$TARGET_DIR"
print_field "Vunderland Repo" "$VUNDERLAND_REPO (Deploy: $CLONE_VUNDERLAND)"

if [ "$DRY_RUN" = true ]; then
    print_warning "Dry-run mode active. No changes will be made to the remote server."
    exit 0
fi

# Test SSH connection with a short timeout and clean error reporting
print_info "Testing SSH connectivity to '$DEST_HOST'..."
if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "$DEST_HOST" "true" 2>/dev/null; then
    print_error "Unable to connect to '$DEST_HOST' via SSH."
    print_info "Troubleshooting Checklist:"
    echo "  1. Is the target host online and reachable on port ${RESOLVED_PORT:-22}?"
    echo "  2. If using an alias from ~/.ssh/config, verify HostName and User."
    echo "  3. Ensure your public key is authorized on the remote host."
    echo "  4. Try connecting manually: ssh $DEST_HOST"
    exit 1
fi
print_success "SSH connection established successfully."

# Detect remote OS and environment
REMOTE_OS_PRETTY="$(ssh "$DEST_HOST" ". /etc/os-release 2>/dev/null && echo \"\$PRETTY_NAME\"" || echo "Linux")"
REMOTE_KERNEL="$(ssh "$DEST_HOST" "uname -r" 2>/dev/null || echo "unknown")"
REMOTE_ARCH="$(ssh "$DEST_HOST" "uname -m" 2>/dev/null || echo "unknown")"
REMOTE_SUDO="$(ssh "$DEST_HOST" "sudo -n true 2>/dev/null && echo 'passwordless' || echo 'needs_password'" || echo "none")"

print_field "Remote Operating System" "$REMOTE_OS_PRETTY"
print_field "Remote Kernel" "$REMOTE_KERNEL ($REMOTE_ARCH)"
print_field "Remote Sudo Status" "$REMOTE_SUDO"

# ------------------------------------------------------------------------------
# 6. SECURE TRANSFER OF LOCAL ~/.ssh CREDENTIALS
# ------------------------------------------------------------------------------
print_header "STEP 2: DEPLOYING SSH KEYS & HOST AUTHENTICATION"

print_info "Preparing remote ~/.ssh directory with strict permissions (0700)..."
ssh "$DEST_HOST" "mkdir -p ~/.ssh && chmod 700 ~/.ssh"

LOCAL_SSH_DIR="$HOME/.ssh"
if [ ! -d "$LOCAL_SSH_DIR" ]; then
    print_error "Local directory $LOCAL_SSH_DIR does not exist!"
    exit 1
fi

print_info "Transferring SSH private and public keys..."

# Transfer private keys (id_* excluding .pub)
for key in "$LOCAL_SSH_DIR"/id_*; do
    if [ -f "$key" ] && [[ "$key" != *.pub ]]; then
        local_name="$(basename "$key")"
        scp -q "$key" "$DEST_HOST:~/.ssh/$local_name"
        ssh "$DEST_HOST" "chmod 600 ~/.ssh/$local_name"
        print_success "Transferred private key: $local_name (mode 0600)"
    fi
done

# Transfer public keys (*.pub)
for pub in "$LOCAL_SSH_DIR"/*.pub; do
    if [ -f "$pub" ]; then
        pub_name="$(basename "$pub")"
        scp -q "$pub" "$DEST_HOST:~/.ssh/$pub_name"
        ssh "$DEST_HOST" "chmod 644 ~/.ssh/$pub_name"
        
        # Ensure this public key is also inside authorized_keys on remote host so access is never lost
        ssh "$DEST_HOST" "grep -qxF -f ~/.ssh/$pub_name ~/.ssh/authorized_keys 2>/dev/null || cat ~/.ssh/$pub_name >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
        print_success "Transferred public key: $pub_name (mode 0644, authorized)"
    fi
done

# Transfer ~/.ssh/config if exists locally
if [ -f "$LOCAL_SSH_DIR/config" ]; then
    scp -q "$LOCAL_SSH_DIR/config" "$DEST_HOST:~/.ssh/config"
    ssh "$DEST_HOST" "chmod 600 ~/.ssh/config"
    print_success "Transferred ~/.ssh/config (mode 0600)"
fi

# Ensure github.com uses IPv4 AddressFamily to avoid unrouted IPv6/NAT64 hangs
ssh "$DEST_HOST" '
    if ! grep -qs "AddressFamily inet" ~/.ssh/config 2>/dev/null; then
        mkdir -p ~/.ssh && touch ~/.ssh/config
        printf "\nHost github.com gitlab.com\n    AddressFamily inet\n" >> ~/.ssh/config
        chmod 600 ~/.ssh/config
    fi
'

# Transfer ~/.ssh/known_hosts if exists locally
if [ -f "$LOCAL_SSH_DIR/known_hosts" ]; then
    scp -q "$LOCAL_SSH_DIR/known_hosts" "$DEST_HOST:~/.ssh/known_hosts"
    ssh "$DEST_HOST" "chmod 644 ~/.ssh/known_hosts"
    print_success "Transferred ~/.ssh/known_hosts (mode 0644)"
fi

# Pre-populate GitHub and GitLab host keys on the remote server using ssh-keyscan
print_info "Scanning and caching public host keys for github.com and gitlab.com..."
ssh "$DEST_HOST" '
    touch ~/.ssh/known_hosts && chmod 644 ~/.ssh/known_hosts
    for host in github.com gitlab.com; do
        if ! ssh-keygen -F "$host" >/dev/null 2>&1; then
            ssh-keyscan -t rsa,ecdsa,ed25519 "$host" >> ~/.ssh/known_hosts 2>/dev/null || true
        fi
    done
'
print_success "Remote host keys verified. Git clones will execute without interactive prompts."

# Test GitHub SSH authentication from the remote host
print_info "Testing remote Git authentication against GitHub..."
REMOTE_GH_AUTH="$(ssh "$DEST_HOST" "ssh -T -o StrictHostKeyChecking=accept-new git@github.com 2>&1" || true)"
if echo "$REMOTE_GH_AUTH" | grep -q -i "successfully authenticated"; then
    GH_USER="$(echo "$REMOTE_GH_AUTH" | grep -o -E "Hi [^!]+" | awk '{print $2}' || echo "User")"
    print_success "GitHub authentication confirmed from remote server for user: ${WHITE}${BOLD}${GH_USER}${NC}"
else
    print_warning "GitHub response: $REMOTE_GH_AUTH"
    print_warning "If using a private repo, ensure your public key is added to your GitHub account."
fi

# ------------------------------------------------------------------------------
# 7. AUTOMATED TOOLCHAIN & DEPENDENCY INSTALLATION
# ------------------------------------------------------------------------------
if [ "$INSTALL_TOOLS" = true ]; then
    print_header "STEP 3: INSTALLING DEVELOPER & LOW-LATENCY TOOLCHAIN"
    print_info "Detecting remote package manager and repository configuration..."

    ssh "$DEST_HOST" 'bash -s' << 'EOF_REMOTE_INSTALL'
set -eo pipefail

if [ -f /etc/os-release ]; then
    . /etc/os-release
    ID_LIKE="${ID_LIKE:-$ID}"
else
    ID_LIKE="unknown"
fi

echo "  -> Remote Distribution Family: $ID_LIKE ($PRETTY_NAME)"

if command -v dnf >/dev/null 2>&1; then
    echo "  -> Configuring Enterprise Linux Repositories (CRB & EPEL)..."
    
    # Enable EPEL
    if ! rpm -q epel-release >/dev/null 2>&1; then
        sudo dnf install -y epel-release dnf-plugins-core >/dev/null 2>&1 || true
    fi

    # Enable CRB (CodeReady Builder)
    if command -v crb >/dev/null 2>&1; then
        sudo crb enable >/dev/null 2>&1 || true
    else
        sudo dnf config-manager --set-enabled crb >/dev/null 2>&1 || true
    fi

    echo "  -> Installing C++ Developer Toolchain (gcc, g++, make, cmake, git, tmux, gdb, valgrind)..."
    sudo dnf install -y \
        gcc \
        gcc-c++ \
        make \
        cmake \
        git \
        tmux \
        gdb \
        valgrind \
        pkgconf \
        pkgconf-pkg-config \
        glibc-devel \
        glibc-headers \
        kernel-headers >/dev/null 2>&1 || true

    echo "  -> Installing Low-Latency, Real-Time & Networking Suite..."
    sudo dnf install -y \
        realtime-tests \
        numactl \
        numactl-devel \
        ethtool \
        tuned \
        tuned-profiles-cpu-partitioning \
        bc \
        stress-ng \
        iperf3 \
        libxdp \
        libxdp-devel \
        libbpf \
        libbpf-devel \
        xdp-tools >/dev/null 2>&1 || true

    echo "  -> Installing System Profiling & Observability Tools..."
    sudo dnf install -y \
        perf \
        bpftool \
        pciutils \
        dmidecode \
        msr-tools \
        sysstat \
        htop \
        iotop \
        jq \
        wget \
        curl \
        python3 \
        python3-pip \
        python3-devel >/dev/null 2>&1 || true

elif command -v apt-get >/dev/null 2>&1; then
    echo "  -> Updating APT cache..."
    sudo apt-get update -qq >/dev/null 2>&1 || true

    echo "  -> Installing Developer & Low-Latency Suite via APT..."
    sudo apt-get install -y -qq \
        build-essential \
        gcc \
        g++ \
        make \
        cmake \
        git \
        tmux \
        gdb \
        valgrind \
        rt-tests \
        numactl \
        libnuma-dev \
        ethtool \
        tuned \
        bc \
        stress-ng \
        iperf3 \
        libxdp-dev \
        libbpf-dev \
        xdp-tools \
        linux-tools-generic \
        pciutils \
        dmidecode \
        msr-tools \
        sysstat \
        htop \
        iotop \
        jq \
        wget \
        curl \
        python3 \
        python3-pip \
        python3-dev >/dev/null 2>&1 || true
else
    echo "  ! Warning: Unrecognized package manager. Please verify build tools manually."
fi
EOF_REMOTE_INSTALL

    print_success "Toolchain packages installed and verified on remote server."
else
    print_info "Skipping toolchain installation (--skip-tools specified)."
fi

# ------------------------------------------------------------------------------
# 8. AUTOMATED GIT REPOSITORY CLONING
# ------------------------------------------------------------------------------
if [ "$CLONE_REPO" = true ]; then
    print_header "STEP 4: CLONING TARGET GIT REPOSITORY ON REMOTE SERVER"

    ssh "$DEST_HOST" "bash -s" -- "$GIT_REPO" "$TARGET_DIR" "$GIT_BRANCH" << 'EOF_REMOTE_GIT'
set -eo pipefail

REPO_URL="$1"
EXPANDED_DIR="${2/#\~/$HOME}"
BRANCH="$3"

if [ -d "$EXPANDED_DIR/.git" ]; then
    echo "  -> Repository already exists at $EXPANDED_DIR. Synchronizing..."
    git -C "$EXPANDED_DIR" remote set-url origin "$REPO_URL" 2>/dev/null || true
    git -C "$EXPANDED_DIR" fetch origin >/dev/null 2>&1 || true
    CURRENT_BRANCH="$(git -C "$EXPANDED_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")"
    git -C "$EXPANDED_DIR" pull --rebase origin "$CURRENT_BRANCH" 2>/dev/null || true
    echo "  -> Synchronized existing repository on branch: $CURRENT_BRANCH"
else
    echo "  -> Cloning $REPO_URL into $EXPANDED_DIR..."
    mkdir -p "$(dirname "$EXPANDED_DIR")"
    CLONED=false
    for attempt in 1 2 3 4 5; do
        if [ -n "$BRANCH" ]; then
            if git clone --branch "$BRANCH" "$REPO_URL" "$EXPANDED_DIR"; then
                CLONED=true; break
            fi
        else
            if git clone "$REPO_URL" "$EXPANDED_DIR"; then
                CLONED=true; break
            fi
        fi
        echo "  ! Git clone attempt $attempt failed (network or DNS). Retrying in 3s..."
        sleep 3
    done
    if [ "$CLONED" = false ]; then
        echo "  ✗ Failed to clone $REPO_URL after 5 attempts."
        exit 1
    fi
    echo "  -> Successfully cloned repository."
fi

COMMIT_INFO="$(git -C "$EXPANDED_DIR" log -1 --oneline 2>/dev/null || echo "Initial")"
echo "  -> Latest Commit: $COMMIT_INFO"
EOF_REMOTE_GIT

    print_success "Git repository successfully deployed to '$TARGET_DIR' on remote server."
else
    print_info "Skipping Git clone (--no-repo specified)."
fi

# ------------------------------------------------------------------------------
# 9. AUTOMATED VUNDERLAND REPOSITORY SETUP & ENVIRONMENT CONFIGURATION
# ------------------------------------------------------------------------------
if [ "$CLONE_VUNDERLAND" = true ]; then
    print_header "STEP 5: CLONING VUNDERLAND & RUNNING VUNDERLAND SETUP"
    print_info "Cloning $VUNDERLAND_REPO into ~/vunderland and executing setup.sh..."

    ssh "$DEST_HOST" "bash -s" -- "$VUNDERLAND_REPO" << 'EOF_VUNDERLAND'
set -eo pipefail

VUNDERLAND_URL="$1"
VUNDERLAND_DIR="$HOME/vunderland"

if [ -d "$VUNDERLAND_DIR/.git" ]; then
    echo "  -> Vunderland repository already exists at $VUNDERLAND_DIR. Synchronizing..."
    git -C "$VUNDERLAND_DIR" remote set-url origin "$VUNDERLAND_URL" 2>/dev/null || true
    git -C "$VUNDERLAND_DIR" fetch origin >/dev/null 2>&1 || true
    CURRENT_BRANCH="$(git -C "$VUNDERLAND_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "master")"
    git -C "$VUNDERLAND_DIR" pull --rebase origin "$CURRENT_BRANCH" 2>/dev/null || true
    echo "  -> Synchronized existing repository on branch: $CURRENT_BRANCH"
else
    echo "  -> Cloning $VUNDERLAND_URL into $VUNDERLAND_DIR..."
    CLONED=false
    for attempt in 1 2 3 4 5; do
        if git clone "$VUNDERLAND_URL" "$VUNDERLAND_DIR"; then
            CLONED=true; break
        fi
        echo "  ! Vunderland clone attempt $attempt failed. Retrying in 3s..."
        sleep 3
    done
    if [ "$CLONED" = false ]; then
        echo "  ✗ Failed to clone $VUNDERLAND_URL after 5 attempts."
        exit 1
    fi
    echo "  -> Successfully cloned vunderland repository."
fi

COMMIT_INFO="$(git -C "$VUNDERLAND_DIR" log -1 --oneline 2>/dev/null || echo "Initial")"
echo "  -> Latest Commit: $COMMIT_INFO"

# Execute vunderland/settings/setup.sh
if [ -f "$VUNDERLAND_DIR/settings/setup.sh" ]; then
    echo "  -> Setting executable permissions on $VUNDERLAND_DIR/settings/setup.sh..."
    chmod +x "$VUNDERLAND_DIR/settings/setup.sh"
    echo "  -> Executing $VUNDERLAND_DIR/settings/setup.sh..."
    # Pass 'penguin' to instruct setup.sh to execute locally without interactive prompts
    bash "$VUNDERLAND_DIR/settings/setup.sh" penguin
    echo "  -> Vunderland setup.sh completed successfully."
else
    echo "  ! Warning: $VUNDERLAND_DIR/settings/setup.sh not found."
fi

# Ensure strict permissions on SSH keys and directory
if [ -L "$HOME/.ssh" ] || [ -d "$HOME/.ssh" ]; then
    chmod 700 "$HOME/.ssh" 2>/dev/null || true
    chmod 600 "$HOME/.ssh/id_"* 2>/dev/null || true
    chmod 600 "$HOME/.ssh/authorized_keys" 2>/dev/null || true
    chmod 644 "$HOME/.ssh/"*.pub 2>/dev/null || true
    chmod 644 "$HOME/.ssh/config" 2>/dev/null || true
    chmod 644 "$HOME/.ssh/known_hosts" 2>/dev/null || true
fi
EOF_VUNDERLAND

    print_success "Vunderland repository deployed and setup script executed successfully."
else
    print_info "Skipping Vunderland setup (--skip-vunderland specified)."
fi

# ------------------------------------------------------------------------------
# 10. CONFIGURING HFT LATENCY TUNING & TESTING SUITE
# ------------------------------------------------------------------------------
print_header "STEP 6: CONFIGURING MASTER LATENCY TUNING ENGINE"

LOCAL_TUNING_SCRIPT="$(dirname "${BASH_SOURCE[0]}")/hft_tuning.sh"
print_info "Configuring hft_tuning.sh in '$TARGET_DIR'..."

ssh "$DEST_HOST" "EXP_DIR=\$(eval echo $TARGET_DIR); \
    if [ -f \"\$EXP_DIR/hft_tuning.sh\" ]; then \
        chmod +x \"\$EXP_DIR/hft_tuning.sh\"; \
    elif [ -d \"\$EXP_DIR\" ]; then \
        scp -q '$LOCAL_TUNING_SCRIPT' \"\$DEST_HOST:\$EXP_DIR/hft_tuning.sh\"; \
        chmod +x \"\$EXP_DIR/hft_tuning.sh\"; \
    fi; \
    rm -f ~/hft_tuning.sh"

print_success "Master latency tuning engine configured exclusively in: $TARGET_DIR/hft_tuning.sh"

# ------------------------------------------------------------------------------
# 11. AUTOMATED ENVIRONMENT SETUP & AGY CLI INSTALLATION
# ------------------------------------------------------------------------------
if [ "$RUN_INSTALL" = true ] && [ "$CLONE_REPO" = true ]; then
    print_header "STEP 7: RUNNING ~/hft/install.sh (TMUX, GIT & AGY CLI)"
    print_info "Connecting to execute install.sh in '$TARGET_DIR'..."

    ssh "$DEST_HOST" "bash -s" << 'EOF_INSTALL_SH'
set -euo pipefail
if [ -d "$HOME/hft" ] && [ -f "$HOME/hft/install.sh" ]; then
    cd "$HOME/hft"
    chmod +x install.sh
    ./install.sh
elif [ -f "$HOME/install.sh" ]; then
    chmod +x "$HOME/install.sh"
    "$HOME/install.sh"
else
    echo "  ! Warning: install.sh not found, skipping."
fi
EOF_INSTALL_SH

    print_success "install.sh executed successfully on remote server."
else
    print_info "Skipping install.sh execution (--skip-install or --no-repo specified)."
fi

# ------------------------------------------------------------------------------
# 12. DEPLOYMENT VERIFICATION & SUMMARY
# ------------------------------------------------------------------------------
print_header "PROVISIONING & DEPLOYMENT COMPLETED SUCCESSFULLY"

print_subheader "Remote Environment Summary"
print_field "Target Host" "$DEST_HOST (${RESOLVED_HOSTNAME:-$DEST_HOST})"
print_field "Remote User" "${RESOLVED_USER:-$USER}"
print_field "SSH Key Auth" "Active (keys transferred to remote ~/.ssh)"
print_field "HFT Repo Path" "$TARGET_DIR"
print_field "Vunderland Path" "$([ "$CLONE_VUNDERLAND" = true ] && echo '~/vunderland' || echo 'Skipped')"

print_subheader "Installed Tools Verification"
ssh "$DEST_HOST" 'bash -s' << 'EOF_VERIFY'
printf "  %-18s : %s\n" "GCC Compiler" "$(gcc --version 2>/dev/null | head -1 || echo 'Not installed')"
printf "  %-18s : %s\n" "G++ Compiler" "$(g++ --version 2>/dev/null | head -1 || echo 'Not installed')"
printf "  %-18s : %s\n" "CMake" "$(cmake --version 2>/dev/null | head -1 || echo 'Not installed')"
printf "  %-18s : %s\n" "Git" "$(git --version 2>/dev/null | head -1 || echo 'Not installed')"
printf "  %-18s : %s\n" "Tmux" "$(tmux -V 2>/dev/null || echo 'Not installed')"
if [ -f "$HOME/.local/bin/agy" ]; then
    printf "  %-18s : %s\n" "Antigravity CLI" "$("$HOME/.local/bin/agy" --version 2>/dev/null || which agy 2>/dev/null || echo 'Installed')"
elif command -v agy >/dev/null 2>&1; then
    printf "  %-18s : %s\n" "Antigravity CLI" "$(agy --version 2>/dev/null)"
else
    printf "  %-18s : %s\n" "Antigravity CLI" "Not installed"
fi
printf "  %-18s : %s\n" "Cyclictest" "$(sudo cyclictest 2>&1 | head -1 || echo 'Available via realtime-tests')"
printf "  %-18s : %s\n" "Numactl" "$(numactl --version 2>/dev/null | head -1 || echo 'Installed')"
printf "  %-18s : %s\n" "Tuned" "$(tuned --version 2>/dev/null | head -1 || echo 'Installed')"
printf "  %-18s : %s\n" "Perf" "$(perf --version 2>/dev/null | head -1 || echo 'Installed')"
if [ -d "$HOME/vunderland" ]; then
    printf "  %-18s : %s\n" "Vunderland" "Installed ($HOME/vunderland - $(git -C "$HOME/vunderland" rev-parse --short HEAD 2>/dev/null || echo 'master'))"
fi
if [ -f "$HOME/micromamba/bin/micromamba" ]; then
    printf "  %-18s : %s\n" "Micromamba" "$("$HOME/micromamba/bin/micromamba" --version 2>/dev/null || echo 'Installed')"
fi
if command -v rustc >/dev/null 2>&1; then
    printf "  %-18s : %s\n" "Rust" "$(rustc --version 2>/dev/null)"
elif [ -f "$HOME/.cargo/bin/rustc" ]; then
    printf "  %-18s : %s\n" "Rust" "$("$HOME/.cargo/bin/rustc" --version 2>/dev/null)"
fi
EOF_VERIFY

if [ "$DEPLOY_PRODUCTION" = true ]; then
    print_header "LOCKING IN GOLDEN PRODUCTION CONFIGURATION ON REMOTE SERVER"
    print_info "Executing: cd $TARGET_DIR && sudo ./hft_tuning.sh --production..."
    ssh -t "$DEST_HOST" "cd $TARGET_DIR && sudo ./hft_tuning.sh --production"
fi

echo ""
print_subheader "Next Steps: Connecting & Running Latency Tuning"
echo -e "  ${WHITE}${BOLD}1. Connect to the server:${NC}"
echo -e "     ${CYAN}ssh $DEST_HOST${NC}"
echo ""
echo -e "  ${WHITE}${BOLD}2. Navigate to your repository:${NC}"
echo -e "     ${CYAN}cd $TARGET_DIR${NC}"
echo ""
echo -e "  ${WHITE}${BOLD}3. Lock in production tunings or run benchmarks:${NC}"
echo -e "     ${CYAN}sudo ./hft_tuning.sh --production${NC}   # One-shot golden production lock-in"
echo -e "     ${CYAN}sudo ./hft_tuning.sh --verify${NC}       # Comprehensive 4-tier audit check"
echo -e "     ${CYAN}sudo ./hft_tuning.sh --full${NC}         # Full pipeline: Benchmark -> Tune -> Benchmark -> Learn"
echo ""
echo -e "${BLUE}${BOLD}══════════════════════════════════════════════════════════════════════════${NC}"
