#!/usr/bin/env bash
#===============================================================================
# dcx oracle keyring - Credential Management
#===============================================================================
# Usage:
#   dcx oracle keyring set KEY [VALUE]    # Set credential (prompts if no value)
#   dcx oracle keyring get KEY            # Get credential
#   dcx oracle keyring delete KEY         # Delete credential
#   dcx oracle keyring list               # List all credentials
#
# Options:
#   --service NAME      Service name (default: dcx-oracle)
#   --backend TYPE      Backend: secret-tool, keyring, file (auto-detected)
#   --help              Show this help message
#===============================================================================

set -eo pipefail

#===============================================================================
# LIBRARY LOADING
#===============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="${SCRIPT_DIR}/.."
PLUGIN_LIB="${PLUGIN_DIR}/lib"

# Load dcx infrastructure or fallbacks
if [[ -z "${DC_LIB_DIR:-}" ]]; then
    log_info() { echo "[INFO] $*"; }
    log_error() { echo "[ERROR] $*" >&2; }
    log_success() { echo "[OK] $*"; }
    die() { echo "[FATAL] $*" >&2; exit 1; }
fi

# Load keyring library
if [[ -f "${PLUGIN_LIB}/keyring.sh" ]]; then
    source "${PLUGIN_LIB}/keyring.sh"
fi

#===============================================================================
# CONFIGURATION
#===============================================================================

SERVICE_NAME="${KEYRING_SERVICE:-dcx-oracle}"
BACKEND=""

#===============================================================================
# ARGUMENT PARSING
#===============================================================================

show_help() {
    cat << 'EOF'
dcx oracle keyring - Credential Management

Usage:
  dcx oracle keyring set KEY [VALUE]    # Set credential (prompts if no value)
  dcx oracle keyring get KEY            # Get credential
  dcx oracle keyring delete KEY         # Delete credential
  dcx oracle keyring list               # List all credentials

Options:
  --service NAME      Service name (default: dcx-oracle)
  --backend TYPE      Backend: secret-tool, keyring, file (auto-detected)
  --help              Show this help message

Examples:
  dcx oracle keyring set PROD_PASSWORD
  dcx oracle keyring set DEV_USER scott
  dcx oracle keyring get PROD_PASSWORD
  dcx oracle keyring list
EOF
    exit 0
}

COMMAND=""
KEY=""
VALUE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --service)
            SERVICE_NAME="$2"
            shift 2
            ;;
        --backend)
            BACKEND="$2"
            shift 2
            ;;
        --help|-h)
            show_help
            ;;
        set|get|delete|list)
            COMMAND="$1"
            shift
            if [[ $# -gt 0 && ! "$1" =~ ^-- ]]; then
                KEY="$1"
                shift
            fi
            if [[ $# -gt 0 && ! "$1" =~ ^-- ]]; then
                VALUE="$1"
                shift
            fi
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

#===============================================================================
# BACKEND DETECTION
#===============================================================================

detect_backend() {
    if [[ -n "$BACKEND" ]]; then
        echo "$BACKEND"
        return
    fi

    # Prefer secret-tool (GNOME Keyring)
    if command -v secret-tool &>/dev/null; then
        echo "secret-tool"
        return
    fi

    # Fallback to Python keyring
    if command -v python3 &>/dev/null && python3 -c "import keyring" 2>/dev/null; then
        echo "keyring"
        return
    fi

    # Last resort: file-based
    echo "file"
}

BACKEND=$(detect_backend)

#===============================================================================
# BACKEND OPERATIONS
#===============================================================================

keyring_set() {
    local key="$1"
    local value="$2"

    # Prompt for value if not provided
    if [[ -z "$value" ]]; then
        echo -n "Enter value for $key: "
        read -rs value
        echo
    fi

    case "$BACKEND" in
        secret-tool)
            echo -n "$value" | secret-tool store --label="$key" service "$SERVICE_NAME" username "$key"
            ;;
        keyring)
            python3 -c "import keyring; keyring.set_password('$SERVICE_NAME', '$key', '$value')"
            ;;
        file)
            local file="${HOME}/.config/dcx-oracle/credentials"
            mkdir -p "$(dirname "$file")"
            chmod 700 "$(dirname "$file")"
            # Simple file storage (not secure, just fallback)
            grep -v "^${key}=" "$file" 2>/dev/null > "$file.tmp" || true
            echo "${key}=${value}" >> "$file.tmp"
            mv "$file.tmp" "$file"
            chmod 600 "$file"
            ;;
    esac

    log_success "Credential '$key' saved (backend: $BACKEND)"
}

keyring_get() {
    local key="$1"

    case "$BACKEND" in
        secret-tool)
            secret-tool lookup service "$SERVICE_NAME" username "$key" 2>/dev/null
            ;;
        keyring)
            python3 -c "import keyring; print(keyring.get_password('$SERVICE_NAME', '$key') or '')"
            ;;
        file)
            local file="${HOME}/.config/dcx-oracle/credentials"
            if [[ -f "$file" ]]; then
                grep "^${key}=" "$file" 2>/dev/null | cut -d= -f2-
            fi
            ;;
    esac
}

keyring_delete() {
    local key="$1"

    case "$BACKEND" in
        secret-tool)
            secret-tool clear service "$SERVICE_NAME" username "$key" 2>/dev/null || true
            ;;
        keyring)
            python3 -c "import keyring; keyring.delete_password('$SERVICE_NAME', '$key')" 2>/dev/null || true
            ;;
        file)
            local file="${HOME}/.config/dcx-oracle/credentials"
            if [[ -f "$file" ]]; then
                grep -v "^${key}=" "$file" > "$file.tmp" || true
                mv "$file.tmp" "$file"
            fi
            ;;
    esac

    log_success "Credential '$key' deleted"
}

keyring_list() {
    echo "Stored credentials (service: $SERVICE_NAME, backend: $BACKEND):"
    echo

    case "$BACKEND" in
        secret-tool)
            # secret-tool doesn't have a list command, so we show a note
            echo "  (secret-tool does not support listing - use GNOME Keyring app)"
            ;;
        keyring)
            echo "  (Python keyring does not support listing)"
            ;;
        file)
            local file="${HOME}/.config/dcx-oracle/credentials"
            if [[ -f "$file" ]]; then
                cut -d= -f1 "$file" | while read -r key; do
                    echo "  - $key"
                done
            else
                echo "  (no credentials stored)"
            fi
            ;;
    esac
}

#===============================================================================
# MAIN
#===============================================================================

case "$COMMAND" in
    set)
        [[ -z "$KEY" ]] && die "Key required: dcx oracle keyring set KEY [VALUE]"
        keyring_set "$KEY" "$VALUE"
        ;;
    get)
        [[ -z "$KEY" ]] && die "Key required: dcx oracle keyring get KEY"
        keyring_get "$KEY"
        ;;
    delete)
        [[ -z "$KEY" ]] && die "Key required: dcx oracle keyring delete KEY"
        keyring_delete "$KEY"
        ;;
    list)
        keyring_list
        ;;
    *)
        log_error "Unknown command: $COMMAND"
        echo "Usage: dcx oracle keyring {set|get|delete|list} [KEY] [VALUE]"
        exit 1
        ;;
esac
