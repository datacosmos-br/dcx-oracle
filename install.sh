#!/usr/bin/env bash
#===============================================================================
# dcx Oracle Plugin Installer
#===============================================================================
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/datacosmos-br/dcx-oracle/main/install.sh | bash
#
# This script installs dcx first (if not present), then installs the oracle plugin.
#
# Options:
#   --prefix PATH     Installation prefix (default: ~/.local/share/dcx/plugins)
#   --version X.Y.Z   Install specific version (default: latest)
#   --skip-dcx        Skip dcx installation (for internal use)
#   --help            Show this help message
#===============================================================================

set -eo pipefail

#===============================================================================
# CONFIGURATION
#===============================================================================

PLUGIN_NAME="oracle"
REPO="datacosmos-br/dcx-oracle"
DCX_REPO="datacosmos-br/dcx"
DCX_INSTALL_URL="https://raw.githubusercontent.com/${DCX_REPO}/main/install.sh"

# Support both dcx locations (prefer dcx standard)
if [[ -d "${XDG_CONFIG_HOME:-$HOME/.config}/dcx/plugins" ]]; then
    DEFAULT_PREFIX="${XDG_CONFIG_HOME:-$HOME/.config}/dcx/plugins"
else
    DEFAULT_PREFIX="${HOME}/.local/share/dcx/plugins"
fi

#===============================================================================
# COLORS
#===============================================================================

if [[ -t 1 ]]; then
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    RED='\033[0;31m'
    CYAN='\033[0;36m'
    NC='\033[0m'
else
    GREEN='' YELLOW='' RED='' CYAN='' NC=''
fi

#===============================================================================
# LOGGING
#===============================================================================

_log() { echo -e "${GREEN}[✓]${NC} $*"; }
_info() { echo -e "${CYAN}[i]${NC} $*"; }
_warn() { echo -e "${YELLOW}[!]${NC} $*" >&2; }
_error() { echo -e "${RED}[✗]${NC} $*" >&2; }
_fatal() { _error "$*"; exit 1; }

#===============================================================================
# ARGUMENT PARSING
#===============================================================================

PREFIX="$DEFAULT_PREFIX"
VERSION=""
SKIP_DCX=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --prefix)
            PREFIX="$2"
            shift 2
            ;;
        --version)
            VERSION="$2"
            shift 2
            ;;
        --skip-dcx)
            SKIP_DCX=true
            shift
            ;;
        --help|-h)
            cat << EOF
dcx Oracle Plugin Installer

Usage: $0 [OPTIONS]

Options:
  --prefix PATH     Installation prefix (default: ~/.local/share/dcx/plugins)
  --version X.Y.Z   Install specific version (default: latest)
  --skip-dcx        Skip dcx installation (assumes dcx is already installed)
  --help            Show this help message

Examples:
  # Install dcx + oracle plugin (recommended)
  curl -fsSL https://raw.githubusercontent.com/${REPO}/main/install.sh | bash

  # Install to custom prefix
  ./install.sh --prefix /opt/dcx/plugins

  # Install specific version
  ./install.sh --version 0.0.1
EOF
            exit 0
            ;;
        *)
            _warn "Unknown option: $1"
            shift
            ;;
    esac
done

#===============================================================================
# HELPER FUNCTIONS
#===============================================================================

_download() {
    local url="$1" output="$2"
    if command -v curl &>/dev/null; then
        curl -fsSL "$url" -o "$output"
    elif command -v wget &>/dev/null; then
        wget -q "$url" -O "$output"
    else
        _fatal "Neither curl nor wget found"
    fi
}

_get_latest_version() {
    local api_url="https://api.github.com/repos/${REPO}/releases/latest"
    local response=""

    if command -v curl &>/dev/null; then
        response=$(curl -fsSL "$api_url" 2>/dev/null) || true
    elif command -v wget &>/dev/null; then
        response=$(wget -qO- "$api_url" 2>/dev/null) || true
    fi

    if [[ -n "$response" ]]; then
        echo "$response" | grep '"tag_name"' | sed 's/.*"v\([^"]*\)".*/\1/' || true
    fi
}

#===============================================================================
# MAIN
#===============================================================================

echo ""
echo -e "${CYAN}dcx Oracle Plugin Installer${NC}"
echo "========================================"
echo ""

# Check dependencies
_info "Checking dependencies..."
command -v curl &>/dev/null || command -v wget &>/dev/null || _fatal "curl or wget required"
command -v tar &>/dev/null || _fatal "tar required"

#===============================================================================
# INSTALL DCX FIRST (if not present)
#===============================================================================

if [[ "$SKIP_DCX" != "true" ]]; then
    if ! command -v dcx &>/dev/null; then
        _info "dcx not found, installing dcx first..."
        echo ""

        if command -v curl &>/dev/null; then
            curl -fsSL "$DCX_INSTALL_URL" | bash
        elif command -v wget &>/dev/null; then
            wget -qO- "$DCX_INSTALL_URL" | bash
        fi

        echo ""
        _info "Continuing with oracle plugin installation..."
        echo ""

        # Update PATH to find newly installed dcx
        export PATH="$HOME/.local/bin:$PATH"

        # Update prefix to use dcx standard location
        if [[ -d "${XDG_CONFIG_HOME:-$HOME/.config}/dcx/plugins" ]]; then
            PREFIX="${XDG_CONFIG_HOME:-$HOME/.config}/dcx/plugins"
        elif [[ -d "$HOME/.local/share/dcx" ]]; then
            PREFIX="$HOME/.local/share/dcx/plugins"
        fi
    else
        _log "dcx already installed: $(dcx --version 2>/dev/null || echo 'unknown version')"
    fi
fi

# Determine version
if [[ -z "$VERSION" ]]; then
    _info "Fetching latest version..."
    VERSION=$(_get_latest_version)
    if [[ -z "$VERSION" ]]; then
        _warn "Could not determine latest version, using 1.0.0"
        VERSION="1.0.0"
    fi
fi
_info "Installing version: v${VERSION}"

# Setup paths
INSTALL_DIR="${PREFIX}/${PLUGIN_NAME}"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# Download
TARBALL_NAME="dcx-oracle-${VERSION}.tar.gz"
DOWNLOAD_URL="https://github.com/${REPO}/releases/download/v${VERSION}/${TARBALL_NAME}"

_info "Downloading ${TARBALL_NAME}..."
if ! _download "$DOWNLOAD_URL" "$TMP_DIR/$TARBALL_NAME" 2>/dev/null; then
    # Fallback: clone from main branch
    _warn "Release not found, cloning from main branch..."
    if command -v git &>/dev/null; then
        git clone --depth 1 "https://github.com/${REPO}.git" "$TMP_DIR/dcx-oracle" 2>/dev/null
        EXTRACTED_DIR="$TMP_DIR/dcx-oracle"
    else
        _fatal "Could not download release and git not available"
    fi
else
    # Extract
    _info "Extracting..."
    tar -xzf "$TMP_DIR/$TARBALL_NAME" -C "$TMP_DIR"
    EXTRACTED_DIR=$(find "$TMP_DIR" -maxdepth 1 -type d -name "dcx-oracle-*" | head -1)
    [[ -z "$EXTRACTED_DIR" ]] && EXTRACTED_DIR="$TMP_DIR"
fi

# Install
_info "Installing to ${INSTALL_DIR}..."
mkdir -p "$INSTALL_DIR"

# Copy files
cp -r "$EXTRACTED_DIR/plugin.yaml" "$INSTALL_DIR/" 2>/dev/null || true
cp -r "$EXTRACTED_DIR/init.sh" "$INSTALL_DIR/" 2>/dev/null || true
cp -r "$EXTRACTED_DIR/VERSION" "$INSTALL_DIR/" 2>/dev/null || true
cp -r "$EXTRACTED_DIR/lib" "$INSTALL_DIR/" 2>/dev/null || true
cp -r "$EXTRACTED_DIR/commands" "$INSTALL_DIR/" 2>/dev/null || true
cp -r "$EXTRACTED_DIR/etc" "$INSTALL_DIR/" 2>/dev/null || true

# Make scripts executable
chmod +x "$INSTALL_DIR/init.sh" 2>/dev/null || true
chmod +x "$INSTALL_DIR"/commands/*.sh 2>/dev/null || true

_log "Plugin installed successfully!"

echo ""
echo -e "${GREEN}Installation complete!${NC}"
echo ""
echo "Usage:"
echo "  dcx oracle validate     # Validate Oracle environment"
echo "  dcx oracle restore      # RMAN restore"
echo "  dcx oracle migrate      # Data Pump migration"
echo "  dcx oracle --help       # Show all commands"
echo ""

# Verify dcx can see the plugin
if command -v dcx &>/dev/null; then
    if dcx plugin list 2>/dev/null | grep -q oracle; then
        _log "Plugin registered with dcx"
    fi
fi
