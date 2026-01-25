#!/usr/bin/env bash
#===============================================================================
# dcx oracle rman - Execute RMAN Commands
#===============================================================================
# Usage:
#   dcx oracle rman "LIST BACKUP SUMMARY"
#   dcx oracle rman -f script.rman
#   dcx oracle rman --target / "CROSSCHECK BACKUP"
#
# Options:
#   -f, --file FILE     Execute RMAN from file
#   --target CONN       Target database connection
#   --catalog CONN      Recovery catalog connection
#   --auxiliary CONN    Auxiliary database connection
#   --sid SID           Set ORACLE_SID
#   --help              Show this help message
#===============================================================================

set -eo pipefail

#===============================================================================
# LIBRARY LOADING
#===============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="${SCRIPT_DIR}/.."
PLUGIN_LIB="${PLUGIN_DIR}/lib"

# Load DCX infrastructure or fallbacks
if [[ -z "${DC_LIB_DIR:-}" ]]; then
    log_info() { echo "[INFO] $*"; }
    log_error() { echo "[ERROR] $*" >&2; }
    die() { echo "[FATAL] $*" >&2; exit 1; }
fi

# Load Oracle libraries
source "${PLUGIN_LIB}/oracle.sh"

#===============================================================================
# ARGUMENT PARSING
#===============================================================================

RMAN_FILE=""
RMAN_CMD=""
TARGET_CONN="/"
CATALOG_CONN=""
AUXILIARY_CONN=""
SID_OVERRIDE=""

show_help() {
    cat << 'EOF'
dcx oracle rman - Execute RMAN Commands

Usage:
  dcx oracle rman "LIST BACKUP SUMMARY"
  dcx oracle rman -f script.rman
  dcx oracle rman --target / "CROSSCHECK BACKUP"

Options:
  -f, --file FILE     Execute RMAN from file
  --target CONN       Target database connection (default: /)
  --catalog CONN      Recovery catalog connection
  --auxiliary CONN    Auxiliary database connection
  --sid SID           Set ORACLE_SID
  --help              Show this help message

Examples:
  dcx oracle rman "LIST BACKUP SUMMARY"
  dcx oracle rman "CROSSCHECK BACKUP"
  dcx oracle rman "REPORT NEED BACKUP"
  dcx oracle rman -f /tmp/backup.rman
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -f|--file)
            RMAN_FILE="$2"
            shift 2
            ;;
        --target)
            TARGET_CONN="$2"
            shift 2
            ;;
        --catalog)
            CATALOG_CONN="$2"
            shift 2
            ;;
        --auxiliary)
            AUXILIARY_CONN="$2"
            shift 2
            ;;
        --sid)
            SID_OVERRIDE="$2"
            shift 2
            ;;
        --help|-h)
            show_help
            ;;
        -*)
            log_error "Unknown option: $1"
            exit 1
            ;;
        *)
            RMAN_CMD="$1"
            shift
            ;;
    esac
done

#===============================================================================
# VALIDATION
#===============================================================================

if [[ -z "$RMAN_FILE" && -z "$RMAN_CMD" ]]; then
    log_error "No RMAN command or file provided"
    echo "Usage: dcx oracle rman \"COMMAND\" or dcx oracle rman -f file.rman"
    exit 1
fi

if [[ -n "$RMAN_FILE" && ! -f "$RMAN_FILE" ]]; then
    die "RMAN file not found: $RMAN_FILE"
fi

if [[ -z "${ORACLE_HOME:-}" ]]; then
    die "ORACLE_HOME is not set"
fi

# Override SID if specified
if [[ -n "$SID_OVERRIDE" ]]; then
    export ORACLE_SID="$SID_OVERRIDE"
fi

#===============================================================================
# EXECUTION
#===============================================================================

# Build rman command
RMAN="${ORACLE_HOME}/bin/rman"
if [[ ! -x "$RMAN" ]]; then
    die "rman not found: $RMAN"
fi

# Build connection arguments
RMAN_ARGS=("target" "$TARGET_CONN")
if [[ -n "$CATALOG_CONN" ]]; then
    RMAN_ARGS+=("catalog" "$CATALOG_CONN")
fi
if [[ -n "$AUXILIARY_CONN" ]]; then
    RMAN_ARGS+=("auxiliary" "$AUXILIARY_CONN")
fi

# Execute RMAN
if [[ -n "$RMAN_FILE" ]]; then
    # Execute from file
    "$RMAN" "${RMAN_ARGS[@]}" @"$RMAN_FILE"
else
    # Execute inline command
    echo "$RMAN_CMD" | "$RMAN" "${RMAN_ARGS[@]}"
fi
