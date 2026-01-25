#!/usr/bin/env bash
#===============================================================================
# init.sh - DCX Oracle Plugin Initialization
#===============================================================================
# This file is sourced by DCX when the oracle plugin is loaded.
# It sets up the plugin environment and loads Oracle libraries.
#
# Usage (by DCX):
#   source "${PLUGIN_DIR}/init.sh"
#
# After loading, the following are available:
#   - All oracle_* functions (oracle_sql_*, oracle_rman_*, etc.)
#   - Plugin-specific configuration
#   - DCX infrastructure (log_*, gum, yq, etc.)
#===============================================================================

# Guard against double-sourcing
[[ -n "${_DCX_ORACLE_PLUGIN_LOADED:-}" ]] && return 0
_DCX_ORACLE_PLUGIN_LOADED=1

#===============================================================================
# PLUGIN PATHS
#===============================================================================

# Plugin directory (where this script lives)
readonly DCX_ORACLE_PLUGIN_DIR="${BASH_SOURCE[0]%/*}"
readonly DCX_ORACLE_LIB_DIR="${DCX_ORACLE_PLUGIN_DIR}/lib"
readonly DCX_ORACLE_ETC_DIR="${DCX_ORACLE_PLUGIN_DIR}/etc"

#===============================================================================
# LOAD ORACLE LIBRARIES
#===============================================================================

# Load unified Oracle module loader
# This automatically loads all oracle_* modules in dependency order
if [[ -f "${DCX_ORACLE_LIB_DIR}/oracle.sh" ]]; then
    source "${DCX_ORACLE_LIB_DIR}/oracle.sh"
else
    echo "ERROR: Oracle library not found: ${DCX_ORACLE_LIB_DIR}/oracle.sh" >&2
    return 1
fi

#===============================================================================
# PLUGIN CONFIGURATION
#===============================================================================

# Load plugin defaults if available
if [[ -f "${DCX_ORACLE_ETC_DIR}/defaults.yaml" ]]; then
    # Use DCX's yq if available for YAML parsing
    if command -v yq &>/dev/null || [[ -x "${DC_BIN_DIR:-}/yq" ]]; then
        : # Config will be loaded via oracle_env module
    fi
fi

#===============================================================================
# PLUGIN INFO
#===============================================================================

# Plugin version (for dcx plugin list)
dcx_oracle_version() {
    local version_file="${DCX_ORACLE_PLUGIN_DIR}/VERSION"
    if [[ -f "$version_file" ]]; then
        cat "$version_file"
    else
        echo "1.0.0"
    fi
}

# Plugin info (for dcx plugin info oracle)
dcx_oracle_info() {
    echo "DCX Oracle Plugin v$(dcx_oracle_version)"
    echo ""
    echo "Commands:"
    echo "  dcx oracle restore     RMAN restore/clone from backup"
    echo "  dcx oracle migrate     Data Pump migration"
    echo "  dcx oracle validate    Validate Oracle environment"
    echo "  dcx oracle keyring     Credential management"
    echo "  dcx oracle sql         Execute SQL statements"
    echo "  dcx oracle rman        Execute RMAN commands"
    echo ""
    echo "For help on a specific command:"
    echo "  dcx oracle <command> --help"
}

#===============================================================================
# INITIALIZATION COMPLETE
#===============================================================================

# Log plugin load if DCX logging is available
if type -t log_debug &>/dev/null; then
    log_debug "DCX Oracle plugin loaded from ${DCX_ORACLE_PLUGIN_DIR}"
fi
