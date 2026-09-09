#!/usr/bin/env bash
# ==============================================================================
# BASIC ENVIRONMENT INSTALLER: TMUX, GIT & ANTIGRAVITY CLI (AGY)
# ==============================================================================
# Supported Platforms: AlmaLinux / RHEL / Rocky / Fedora / Debian / Ubuntu
# Description: Installs git, tmux, curl, and Google Antigravity CLI (agy).
# ==============================================================================

set -euo pipefail

# Visual formatting
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

print_header() {
    echo -e "\n${BLUE}${BOLD}══════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}${BOLD}  $1${NC}"
    echo -e "${BLUE}${BOLD}══════════════════════════════════════════════════════════════════════════${NC}"
}

print_info()    { echo -e "  ${YELLOW}ℹ [INFO]${NC} $1"; }
print_success() { echo -e "  ${GREEN}✓ [SUCCESS]${NC} $1"; }
print_error()   { echo -e "  ${RED}✗ [ERROR]${NC} $1"; }

print_header "STEP 1: DETECTING PACKAGE MANAGER & INSTALLING BASE PACKAGES"

if command -v dnf >/dev/null 2>&1; then
    print_info "Detected DNF (RHEL / AlmaLinux / Rocky / Fedora)"
    print_info "Installing tmux, git, curl, and ca-certificates..."
    sudo dnf install -y tmux git curl ca-certificates
elif command -v yum >/dev/null 2>&1; then
    print_info "Detected YUM (CentOS / RHEL)"
    print_info "Installing tmux, git, curl, and ca-certificates..."
    sudo yum install -y tmux git curl ca-certificates
elif command -v apt-get >/dev/null 2>&1; then
    print_info "Detected APT (Debian / Ubuntu)"
    print_info "Updating package lists..."
    sudo apt-get update -qq
    print_info "Installing tmux, git, curl, and ca-certificates..."
    sudo apt-get install -y -qq tmux git curl ca-certificates
elif command -v pacman >/dev/null 2>&1; then
    print_info "Detected Pacman (Arch Linux)"
    sudo pacman -Sy --noconfirm tmux git curl ca-certificates
elif command -v zypper >/dev/null 2>&1; then
    print_info "Detected Zypper (openSUSE)"
    sudo zypper install -y tmux git curl ca-certificates
else
    print_error "Unsupported package manager. Please install tmux, git, and curl manually."
    exit 1
fi

print_success "Base system packages installed successfully."

print_header "STEP 2: INSTALLING ANTIGRAVITY CLI (AGY)"

print_info "Fetching and running official Antigravity CLI installer..."
if curl -fsSL https://antigravity.google/cli/install.sh | bash; then
    print_success "Antigravity CLI installer completed successfully."
else
    print_error "Failed to install Antigravity CLI via official script."
    exit 1
fi

# Ensure ~/.local/bin and ~/bin are included in PATH
for p in "$HOME/.local/bin" "$HOME/bin"; do
    if [ -d "$p" ] && [[ ":$PATH:" != *":$p:"* ]]; then
        export PATH="$p:$PATH"
        # Persist to ~/.bashrc if not already present
        if ! grep -qs "export PATH=\"$p:\$PATH\"" "$HOME/.bashrc" 2>/dev/null; then
            echo "export PATH=\"$p:\$PATH\"" >> "$HOME/.bashrc"
        fi
    fi
done

print_header "STEP 3: VERIFYING INSTALLATIONS"

echo ""
# Verify Git
if command -v git >/dev/null 2>&1; then
    print_success "Git : $(git --version)"
else
    print_error "Git is not accessible in PATH."
fi

# Verify Tmux
if command -v tmux >/dev/null 2>&1; then
    print_success "Tmux: $(tmux -V)"
else
    print_error "Tmux is not accessible in PATH."
fi

# Verify AGY CLI
if command -v agy >/dev/null 2>&1; then
    print_success "AGY : $(agy --version 2>/dev/null || which agy)"
elif [ -f "$HOME/.local/bin/agy" ]; then
    print_success "AGY : Installed at $HOME/.local/bin/agy (Reload shell or run 'source ~/.bashrc')"
else
    print_info "AGY : Installed. Please run 'source ~/.bashrc' or reload your terminal session."
fi

echo -e "\n${GREEN}${BOLD}Setup completed successfully!${NC}\n"
