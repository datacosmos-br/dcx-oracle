#!/usr/bin/env bash
#===============================================================================
# dcx oracle validate - Validate Oracle Environment
#===============================================================================
# Usage:
#   dcx oracle validate [options]
#
# Options:
#   --require-sid       Require ORACLE_SID to be set
#   --require-sqlplus   Require sqlplus binary
#   --require-rman      Require rman binary
#   --require-datapump  Require impdp/expdp binaries
#   --verbose           Show detailed validation output
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
    log_warn() { echo "[WARN] $*" >&2; }
fi

# Load Oracle libraries
source "${PLUGIN_LIB}/oracle.sh"

#===============================================================================
# ARGUMENT PARSING
#===============================================================================

REQUIRE_SID=false
REQUIRE_SQLPLUS=false
REQUIRE_RMAN=false
REQUIRE_DATAPUMP=false
VERBOSE=false

show_help() {
    cat << 'EOF'
dcx oracle validate - Validate Oracle Environment

Usage:
  dcx oracle validate [options]

Options:
  --require-sid       Require ORACLE_SID to be set
  --require-sqlplus   Require sqlplus binary
  --require-rman      Require rman binary
  --require-datapump  Require impdp/expdp binaries
  --verbose           Show detailed validation output
  --help              Show this help message

Examples:
  dcx oracle validate
  dcx oracle validate --require-sid --require-sqlplus
  dcx oracle validate --verbose
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --require-sid)
            REQUIRE_SID=true
            shift
            ;;
        --require-sqlplus)
            REQUIRE_SQLPLUS=true
            shift
            ;;
        --require-rman)
            REQUIRE_RMAN=true
            shift
            ;;
        --require-datapump)
            REQUIRE_DATAPUMP=true
            shift
            ;;
        --verbose|-v)
            VERBOSE=true
            shift
            ;;
        --help|-h)
            show_help
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

#===============================================================================
# VALIDATION
#===============================================================================

errors=0

echo "Oracle Environment Validation"
echo "=============================="
echo

# ORACLE_HOME
if [[ -n "${ORACLE_HOME:-}" ]]; then
    if [[ -d "$ORACLE_HOME" ]]; then
        log_success "ORACLE_HOME: $ORACLE_HOME"
    else
        log_error "ORACLE_HOME directory does not exist: $ORACLE_HOME"
        ((errors++))
    fi
else
    log_error "ORACLE_HOME is not set"
    ((errors++))
fi

# ORACLE_SID
if [[ -n "${ORACLE_SID:-}" ]]; then
    log_success "ORACLE_SID: $ORACLE_SID"
elif $REQUIRE_SID; then
    log_error "ORACLE_SID is not set (required)"
    ((errors++))
else
    log_warn "ORACLE_SID is not set"
fi

# ORACLE_BASE
if [[ -n "${ORACLE_BASE:-}" ]]; then
    log_success "ORACLE_BASE: $ORACLE_BASE"
elif $VERBOSE; then
    log_warn "ORACLE_BASE is not set"
fi

# sqlplus
if command -v sqlplus &>/dev/null || [[ -x "${ORACLE_HOME:-}/bin/sqlplus" ]]; then
    log_success "sqlplus: found"
elif $REQUIRE_SQLPLUS; then
    log_error "sqlplus not found (required)"
    ((errors++))
else
    log_warn "sqlplus not found"
fi

# rman
if command -v rman &>/dev/null || [[ -x "${ORACLE_HOME:-}/bin/rman" ]]; then
    log_success "rman: found"
elif $REQUIRE_RMAN; then
    log_error "rman not found (required)"
    ((errors++))
elif $VERBOSE; then
    log_warn "rman not found"
fi

# impdp/expdp
if command -v impdp &>/dev/null || [[ -x "${ORACLE_HOME:-}/bin/impdp" ]]; then
    log_success "impdp/expdp: found"
elif $REQUIRE_DATAPUMP; then
    log_error "impdp/expdp not found (required)"
    ((errors++))
elif $VERBOSE; then
    log_warn "impdp/expdp not found"
fi

echo
echo "=============================="
if [[ $errors -eq 0 ]]; then
    log_success "Validation passed"
    exit 0
else
    log_error "Validation failed with $errors error(s)"
    exit 1
fi
