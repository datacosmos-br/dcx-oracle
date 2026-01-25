#!/usr/bin/env bash
# shellcheck shell=bash
#===============================================================================
# dcx Oracle Plugin - Unified Module Loader
#===============================================================================
# File    : oracle.sh
# Version : 2.0.0
# Date    : 2026-01-24
#===============================================================================
#
# DESCRIPTION:
#   Unified loader and facade for all Oracle-related modules in the dcx plugin.
#   This module automatically loads all core Oracle sub-modules and provides
#   convenience functions for Oracle operations.
#
# ARCHITECTURE:
#   This module loads all core Oracle sub-modules:
#   - oracle_core.sh    : Base Oracle functionality (environment, binaries)
#   - oracle_env.sh     : Environment management and configuration
#   - oracle_config.sh  : PFILE, memory, filesystem, paths
#   - oracle_cluster.sh : RAC and Clusterware support
#   - oracle_instance.sh: Instance lifecycle management
#   - oracle_sql.sh     : SQL execution via sqlplus
#
#   Additional specialized modules (loaded on demand):
#   - oracle_datapump.sh: Data Pump operations
#   - oracle_rman.sh    : RMAN backup/restore
#   - oracle_oci.sh     : OCI Object Storage
#
# dcx INTEGRATION:
#   This module inherits from dcx infrastructure:
#   - Logging: log_info, log_error, log_debug, etc.
#   - Runtime: need_cmd, assert_file, retry, timeout_cmd
#   - Config: config_get, config_set via dcx's yq
#   - UI: gum for spinners, confirmations, prompts
#
# USAGE:
#   # Via plugin init.sh (automatic)
#   source "${PLUGIN_DIR}/init.sh"
#
#   # Direct sourcing
#   source lib/oracle.sh
#   oracle_init
#
#===============================================================================

# Prevent double sourcing
[[ -n "${__ORACLE_LOADED:-}" ]] && return 0
__ORACLE_LOADED=1

# Resolve library directory
_ORACLE_LIB_DIR="${BASH_SOURCE[0]%/*}"

#===============================================================================
# dcx INFRASTRUCTURE CHECK
#===============================================================================

# Verify dcx functions are available (inherited from dcx)
_oracle_check_dcx() {
    # Check for essential dcx functions
    if ! type -t log_info &>/dev/null; then
        # dcx not loaded - define minimal fallbacks
        log_info() { echo "[INFO] $*"; }
        log_error() { echo "[ERROR] $*" >&2; }
        log_warn() { echo "[WARN] $*" >&2; }
        log_debug() { [[ "${LOG_LEVEL:-1}" -ge 3 ]] && echo "[DEBUG] $*"; }
        warn() { echo "[WARN] $*" >&2; }
        die() { echo "[FATAL] $*" >&2; exit 1; }
    fi
}
_oracle_check_dcx

#===============================================================================
# LOAD CORE MODULES
#===============================================================================

# Load all core Oracle modules in dependency order
# Note: Each module handles its own guard against double-sourcing

_oracle_load_core_modules() {
    local module_file

    # 1. oracle_core.sh - Base Oracle functionality (no dependencies)
    module_file="${_ORACLE_LIB_DIR}/oracle_core.sh"
    if [[ -f "$module_file" ]] && [[ -z "${__ORACLE_CORE_LOADED:-}" ]]; then
        # shellcheck source=/dev/null
        source "$module_file"
    fi

    # 2. oracle_sql.sh - SQL execution (depends on oracle_core)
    module_file="${_ORACLE_LIB_DIR}/oracle_sql.sh"
    if [[ -f "$module_file" ]] && [[ -z "${__ORACLE_SQL_LOADED:-}" ]]; then
        # shellcheck source=/dev/null
        source "$module_file"
    fi

    # 3. oracle_env.sh - Environment management (depends on oracle_core)
    module_file="${_ORACLE_LIB_DIR}/oracle_env.sh"
    if [[ -f "$module_file" ]] && [[ -z "${__ORACLE_ENV_LOADED:-}" ]]; then
        # shellcheck source=/dev/null
        source "$module_file"
    fi

    # 4. oracle_config.sh - Configuration (depends on oracle_core, oracle_sql)
    module_file="${_ORACLE_LIB_DIR}/oracle_config.sh"
    if [[ -f "$module_file" ]] && [[ -z "${__ORACLE_CONFIG_LOADED:-}" ]]; then
        # shellcheck source=/dev/null
        source "$module_file"
    fi

    # 5. oracle_cluster.sh - RAC support (depends on oracle_core, oracle_sql)
    module_file="${_ORACLE_LIB_DIR}/oracle_cluster.sh"
    if [[ -f "$module_file" ]] && [[ -z "${__ORACLE_CLUSTER_LOADED:-}" ]]; then
        # shellcheck source=/dev/null
        source "$module_file"
    fi

    # 6. oracle_instance.sh - Instance management (depends on cluster, sql)
    module_file="${_ORACLE_LIB_DIR}/oracle_instance.sh"
    if [[ -f "$module_file" ]] && [[ -z "${__ORACLE_INSTANCE_LOADED:-}" ]]; then
        # shellcheck source=/dev/null
        source "$module_file"
    fi
}

# Load core modules
_oracle_load_core_modules

#===============================================================================
# MODULE LOADING
#===============================================================================

# oracle_load_module - Load additional Oracle module(s)
# Usage: oracle_load_module "datapump" "rman" "oci"
oracle_load_module() {
    local module
    for module in "$@"; do
        local module_file="${_ORACLE_LIB_DIR}/oracle_${module}.sh"

        if [[ -f "$module_file" ]]; then
            # shellcheck source=/dev/null
            source "$module_file"
            log_debug "Loaded Oracle module: oracle_${module}"
        else
            log_warn "Oracle module not found: oracle_${module}.sh"
        fi
    done
}

# oracle_require - Ensure Oracle module(s) are loaded
# Usage: oracle_require "datapump" "rman"
oracle_require() {
    oracle_load_module "$@"
}

#===============================================================================
# INITIALIZATION
#===============================================================================

# oracle_init - Initialize Oracle environment
# Usage: oracle_init [options]
# Options:
#   --require-sid       Require ORACLE_SID to be set
#   --require-sqlplus   Require sqlplus binary
#   --require-rman      Require rman binary
#   --require-datapump  Require impdp/expdp binaries
oracle_init() {
    # Delegate to oracle_env_init if available
    if type -t oracle_env_init &>/dev/null; then
        oracle_env_init "$@"
    else
        # Basic initialization
        if [[ -z "${ORACLE_HOME:-}" ]]; then
            log_error "ORACLE_HOME is not set"
            return 1
        fi
        log_info "Oracle environment initialized"
    fi
}

#===============================================================================
# ENVIRONMENT INFORMATION
#===============================================================================

# oracle_print_info - Print comprehensive Oracle environment information
oracle_print_info() {
    echo
    echo "========================================================================"
    echo "                    ORACLE ENVIRONMENT INFORMATION"
    echo "========================================================================"

    # Environment
    if type -t oracle_core_print_env &>/dev/null; then
        oracle_core_print_env
    else
        echo "ORACLE_HOME: ${ORACLE_HOME:-<not set>}"
        echo "ORACLE_SID:  ${ORACLE_SID:-<not set>}"
        echo "ORACLE_BASE: ${ORACLE_BASE:-<not set>}"
    fi

    # Cluster information
    if type -t oracle_cluster_print_info &>/dev/null; then
        oracle_cluster_print_info
    fi

    # Instance information
    if [[ -n "${ORACLE_SID:-}" ]] && type -t oracle_instance_print_info &>/dev/null; then
        oracle_instance_print_info
    fi

    echo "========================================================================"
}

#===============================================================================
# CONVENIENCE FUNCTIONS
#===============================================================================

# oracle_validate - Validate Oracle environment
oracle_validate() {
    if type -t oracle_env_validate &>/dev/null; then
        oracle_env_validate "$@"
    else
        oracle_core_validate_oracle_home
    fi
}

# oracle_switch_sid - Switch to different SID
oracle_switch_sid() {
    if type -t oracle_env_switch_sid &>/dev/null; then
        oracle_env_switch_sid "$@"
    else
        export ORACLE_SID="$1"
        log_info "Switched to ORACLE_SID=$1"
    fi
}

#===============================================================================
# MODULE INFORMATION
#===============================================================================

# oracle_list_loaded - List all loaded Oracle modules
oracle_list_loaded() {
    echo "Loaded Oracle modules:"
    [[ -n "${__ORACLE_CORE_LOADED:-}" ]] && echo "  - oracle_core"
    [[ -n "${__ORACLE_ENV_LOADED:-}" ]] && echo "  - oracle_env"
    [[ -n "${__ORACLE_CONFIG_LOADED:-}" ]] && echo "  - oracle_config"
    [[ -n "${__ORACLE_CLUSTER_LOADED:-}" ]] && echo "  - oracle_cluster"
    [[ -n "${__ORACLE_INSTANCE_LOADED:-}" ]] && echo "  - oracle_instance"
    [[ -n "${__ORACLE_SQL_LOADED:-}" ]] && echo "  - oracle_sql"
    [[ -n "${__ORACLE_DATAPUMP_LOADED:-}" ]] && echo "  - oracle_datapump"
    [[ -n "${__ORACLE_RMAN_LOADED:-}" ]] && echo "  - oracle_rman"
    [[ -n "${__ORACLE_OCI_LOADED:-}" ]] && echo "  - oracle_oci"
}

# oracle_version - Print Oracle module versions
oracle_version() {
    echo "dcx Oracle Plugin v2.0.0"
    echo "  oracle.sh         : 2.0.0 (Unified loader)"
    echo "  oracle_core.sh    : 1.0.0 (Base functionality)"
    echo "  oracle_env.sh     : 1.0.0 (Environment management)"
    echo "  oracle_config.sh  : 1.0.0 (Configuration & PFILE)"
    echo "  oracle_cluster.sh : 1.0.0 (RAC & Clusterware)"
    echo "  oracle_instance.sh: 1.0.0 (Instance lifecycle)"
    echo "  oracle_sql.sh     : 1.0.0 (SQL execution)"
}

#===============================================================================
# AUTO-INITIALIZATION
#===============================================================================

log_debug "dcx Oracle unified module loaded (v2.0.0)"
