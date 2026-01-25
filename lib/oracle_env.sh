#!/usr/bin/env bash
# shellcheck shell=bash
#===============================================================================
# Datacosmos - Oracle Environment Module
#
# Copyright (c) 2026 Datacosmos
# Licensed under the Apache License, Version 2.0
#===============================================================================
# File    : oracle_env.sh
# Version : 1.0.0
# Date    : 2026-01-15
#===============================================================================
#
# DESCRIPTION:
#   Oracle environment management: configuration loading, session initialization,
#   and integration with core.sh setup. Provides complete environment setup
#   for Oracle scripts.
#
# DEPENDS ON:
#   - oracle_core.sh (base Oracle functionality)
#   - config.sh (configuration loading)
#   - runtime.sh (runtime utilities)
#   - logging.sh (logging)
#
# PROVIDES:
#   - oracle_env_init()         - Full environment initialization
#   - oracle_env_load_config()  - Load Oracle configuration
#   - oracle_env_validate()     - Validate Oracle environment
#   - oracle_env_setup()        - Integrated setup with core.sh
#   - oracle_env_get_info()     - Get environment information
#
# REPORT INTEGRATION:
#   This module integrates with report.sh for environment setup tracking:
#   - Tracked Steps: Config loading, environment validation, session initialization
#   - Tracked Metrics: env_initialized (1/0), env_validations_passed, env_validations_failed
#   - Tracked Metadata: env_config_file, env_logs_dir, env_session_id, ORACLE_HOME, ORACLE_SID
#   - Tracked Items: Config and validation step results with status
#   - Integration is graceful (NO-OP without report_init)
#   - All metrics have env_ prefix for pattern-based aggregation
#
#===============================================================================

# Prevent double sourcing
[[ -n "${__ORACLE_ENV_LOADED:-}" ]] && return 0
__ORACLE_ENV_LOADED=1

# Resolve library directory
_ORACLE_ENV_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load oracle_core.sh (provides oracle_core_* functions)
# shellcheck source=/dev/null
[[ -z "${__ORACLE_CORE_LOADED:-}" ]] && source "${_ORACLE_ENV_LIB_DIR}/oracle_core.sh"

# Load config.sh (provides config_load*, etc.) and session.sh (provides session_init*)
# shellcheck source=/dev/null
[[ -z "${__CONFIG_LOADED:-}" ]] && source "${_ORACLE_ENV_LIB_DIR}/config.sh"

#===============================================================================
# SECTION 1: Default Values
#===============================================================================

# Default Oracle environment variables
_ORACLE_ENV_DEFAULTS=(
    "NLS_LANG=AMERICAN_AMERICA.AL32UTF8"
    "NLS_DATE_FORMAT=YYYY-MM-DD HH24:MI:SS"
    "SQLNET_ALLOWED_LOGON_VERSION=11"
)

#===============================================================================
# SECTION 2: Configuration Loading
#===============================================================================

# oracle_env_load_config - Load Oracle configuration from file
# Usage: oracle_env_load_config "/path/to/oracle.conf"
# Config file format:
#   ORACLE_HOME=/u01/app/oracle/product/19c/dbhome_1
#   ORACLE_SID=ORCL
#   ORACLE_BASE=/u01/app/oracle
oracle_env_load_config() {
    local config_file="${1:-}"
    
    # Set defaults first
    oracle_env_set_defaults
    
    # Load config file if provided
    if [[ -n "${config_file}" ]]; then
        if [[ -f "${config_file}" ]]; then
            config_load "${config_file}"
            log_debug "Oracle config loaded: ${config_file}"
        else
            warn "Oracle config file not found: ${config_file}"
        fi
    fi
    
    # Validate and discover binaries
    if oracle_core_check_home; then
        oracle_core_discover_binaries
    fi
}

# oracle_env_load_config_with_defaults - Load config with explicit defaults
# Usage: oracle_env_load_config_with_defaults "/path/to/config" "ORACLE_SID=ORCL"
oracle_env_load_config_with_defaults() {
    local config_file="$1"
    shift
    
    # Set standard defaults
    oracle_env_set_defaults
    
    # Set user-provided defaults
    config_load_with_defaults "${config_file}" "$@"
    
    # Discover binaries
    if oracle_core_check_home; then
        oracle_core_discover_binaries
    fi
}

# oracle_env_set_defaults - Set default Oracle environment values
# Usage: oracle_env_set_defaults
oracle_env_set_defaults() {
    local default
    for default in "${_ORACLE_ENV_DEFAULTS[@]}"; do
        local key="${default%%=*}"
        local val="${default#*=}"
        runtime_set_default "${key}" "${val}"
    done
    
    # Derive ORACLE_BASE from ORACLE_HOME if not set
    if [[ -z "${ORACLE_BASE:-}" ]] && [[ -n "${ORACLE_HOME:-}" ]]; then
        # Try to detect ORACLE_BASE from ORACLE_HOME structure
        # Common patterns: /u01/app/oracle/product/19c/dbhome_1 -> /u01/app/oracle
        local base
        base="$(echo "${ORACLE_HOME}" | sed 's|/product/.*||')"
        if [[ -d "${base}" ]] && [[ "${base}" != "${ORACLE_HOME}" ]]; then
            export ORACLE_BASE="${base}"
            log_debug "Derived ORACLE_BASE: ${ORACLE_BASE}"
        fi
    fi
}

#===============================================================================
# SECTION 3: Environment Validation
#===============================================================================

# oracle_env_validate - Validate Oracle environment is properly configured
# Usage: oracle_env_validate [--require-sid] [--require-sqlplus]
oracle_env_validate() {
    log_debug "Validating Oracle environment..."
    
    # Delegate to oracle_core
    oracle_core_validate_env "$@"
    
    # Check oratab mismatch
    if [[ -n "${ORACLE_SID:-}" ]]; then
        oracle_core_check_oratab_mismatch "${ORACLE_SID}" || true
    fi
    
    log_debug "Oracle environment validated"
}

# oracle_env_require_vars - Require specific Oracle variables
# Usage: oracle_env_require_vars "ORACLE_HOME" "ORACLE_SID"
oracle_env_require_vars() {
    runtime_require_vars "$@"
}

#===============================================================================
# SECTION 4: Session Management
#===============================================================================

# oracle_env_init_session - Initialize Oracle session with logging
# Usage: oracle_env_init_session "/var/log/oracle" "restore"
oracle_env_init_session() {
    local logs_base="$1"
    local prefix="${2:-oracle}"

    # Use session.sh session management
    session_init "${logs_base}" "${prefix}"
    
    log_debug "Oracle session initialized: ${SESSION_ID}"
    log_debug "Session directory: ${SESSION_DIR}"
    log_debug "Session log: ${SESSION_LOG}"
}

# oracle_env_get_session_dir - Get current session directory
# Usage: DIR=$(oracle_env_get_session_dir)
oracle_env_get_session_dir() {
    echo "${SESSION_DIR:-}"
}

# oracle_env_get_session_id - Get current session ID
# Usage: ID=$(oracle_env_get_session_id)
oracle_env_get_session_id() {
    echo "${SESSION_ID:-}"
}

#===============================================================================
# SECTION 5: Full Environment Initialization
#===============================================================================

# oracle_env_init - Full Oracle environment initialization
# Usage: oracle_env_init [options]
# Options:
#   --config FILE       Load configuration from file
#   --logs-dir DIR      Initialize session logging in directory
#   --logs-prefix NAME  Session log prefix (default: "oracle")
#   --require-sid       Require ORACLE_SID to be set
#   --require-sqlplus   Require sqlplus binary
#   --require-rman      Require rman binary
#   --require-datapump  Require impdp/expdp binaries
oracle_env_init() {
    local config_file=""
    local logs_dir=""
    local logs_prefix="oracle"
    local require_args=()
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --config)
                config_file="$2"
                shift 2
                ;;
            --logs-dir)
                logs_dir="$2"
                shift 2
                ;;
            --logs-prefix)
                logs_prefix="$2"
                shift 2
                ;;
            --require-sid|--require-sqlplus|--require-rman|--require-datapump)
                require_args+=("$1")
                shift
                ;;
            *)
                warn "Unknown option: $1"
                shift
                ;;
        esac
    done
    
    # Track operation
    report_track_step "Initialize Oracle environment"
    [[ -n "${config_file}" ]] && report_track_meta "env_config_file" "${config_file}"
    [[ -n "${logs_dir}" ]] && report_track_meta "env_logs_dir" "${logs_dir}"

    log_debug "Initializing Oracle environment..."

    # Load configuration
    if [[ -n "${config_file}" ]]; then
        oracle_env_load_config "${config_file}"
        report_track_item "ok" "Config Loading" "${config_file}"
    else
        oracle_env_set_defaults
        report_track_item "ok" "Config Loading" "defaults applied"
    fi

    # Validate environment
    oracle_env_validate "${require_args[@]}"
    report_track_item "ok" "Environment Validation" "passed"

    # Initialize session if logs directory specified
    if [[ -n "${logs_dir}" ]]; then
        oracle_env_init_session "${logs_dir}" "${logs_prefix}"
        report_track_meta "env_session_id" "${SESSION_ID:-unknown}"
    fi

    log_debug "Oracle environment initialized"
    report_track_step_done 0 "Oracle environment initialized"
    report_track_metric "env_initialized" "1" "set"
}

#===============================================================================
# SECTION 6: Integrated Setup with core.sh
#===============================================================================

# oracle_env_setup - Full setup integrating core.sh and Oracle
# Usage: oracle_env_setup [core_setup_all options] [oracle options]
# 
# Core options (passed to core_setup_all):
#   --logdir DIR          Initialize logging to directory
#   --logbase NAME        Log file base name
#   --session-dir DIR     Initialize session management
#   --session-prefix NAME Session log prefix
#   --queue-max N         Initialize queue with max concurrent jobs
#   --enable-err-trap     Enable error trap handler
#
# Oracle options:
#   --oracle-config FILE  Load Oracle configuration
#   --oracle-require-sid  Require ORACLE_SID
#   --oracle-require-sql  Require sqlplus
#   --oracle-require-rman Require rman
oracle_env_setup() {
    local core_args=()
    local oracle_config=""
    local oracle_require_args=()
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            # Core options
            --logdir|--logbase|--session-dir|--session-prefix|--queue-max)
                core_args+=("$1" "$2")
                shift 2
                ;;
            --enable-err-trap|--no-queue-init|--no-session-init|--no-log-init)
                core_args+=("$1")
                shift
                ;;
            # Oracle options
            --oracle-config)
                oracle_config="$2"
                shift 2
                ;;
            --oracle-require-sid)
                oracle_require_args+=("--require-sid")
                shift
                ;;
            --oracle-require-sql)
                oracle_require_args+=("--require-sqlplus")
                shift
                ;;
            --oracle-require-rman)
                oracle_require_args+=("--require-rman")
                shift
                ;;
            --oracle-require-datapump)
                oracle_require_args+=("--require-datapump")
                shift
                ;;
            *)
                warn "Unknown option: $1"
                shift
                ;;
        esac
    done
    
    log_debug "Running Oracle environment setup..."
    
    # Setup core.sh subsystems if core_setup_all is available
    if declare -f core_setup_all >/dev/null 2>&1; then
        if [[ ${#core_args[@]} -gt 0 ]]; then
            core_setup_all "${core_args[@]}"
        fi
    else
        log_debug "core_setup_all not available, skipping core setup"
    fi
    
    # Load Oracle configuration
    if [[ -n "${oracle_config}" ]]; then
        oracle_env_load_config "${oracle_config}"
    else
        oracle_env_set_defaults
    fi
    
    # Validate Oracle environment
    oracle_env_validate "${oracle_require_args[@]}"
    
    log "Oracle environment setup complete"
}

#===============================================================================
# SECTION 7: Environment Information
#===============================================================================

# oracle_env_get_info - Get Oracle environment information as associative array
# Usage: eval "$(oracle_env_get_info)"
#        echo "${ORACLE_ENV_INFO[ORACLE_HOME]}"
oracle_env_get_info() {
    echo "declare -A ORACLE_ENV_INFO"
    echo "ORACLE_ENV_INFO[ORACLE_HOME]=\"${ORACLE_HOME:-}\""
    echo "ORACLE_ENV_INFO[ORACLE_BASE]=\"${ORACLE_BASE:-}\""
    echo "ORACLE_ENV_INFO[ORACLE_SID]=\"${ORACLE_SID:-}\""
    echo "ORACLE_ENV_INFO[ORACLE_UNQNAME]=\"${ORACLE_UNQNAME:-}\""
    echo "ORACLE_ENV_INFO[TNS_ADMIN]=\"${TNS_ADMIN:-}\""
    echo "ORACLE_ENV_INFO[NLS_LANG]=\"${NLS_LANG:-}\""
    echo "ORACLE_ENV_INFO[SESSION_ID]=\"${SESSION_ID:-}\""
    echo "ORACLE_ENV_INFO[SESSION_DIR]=\"${SESSION_DIR:-}\""
}

# oracle_env_print_info - Print Oracle environment information
# Usage: oracle_env_print_info
oracle_env_print_info() {
    oracle_core_print_env
    
    if [[ -n "${SESSION_ID:-}" ]]; then
        echo
        echo "==================== Session Info ===================="
        runtime_print_kv "SESSION_ID" "${SESSION_ID}"
        runtime_print_kv "SESSION_DIR" "${SESSION_DIR:-<not set>}"
        runtime_print_kv "SESSION_LOG" "${SESSION_LOG:-<not set>}"
        echo "======================================================="
    fi
    
    echo
    echo "==================== Binaries ===================="
    runtime_print_kv "sqlplus" "$(oracle_core_get_binary sqlplus || echo '<not found>')"
    runtime_print_kv "rman" "$(oracle_core_get_binary rman || echo '<not found>')"
    runtime_print_kv "impdp" "$(oracle_core_get_binary impdp || echo '<not found>')"
    runtime_print_kv "srvctl" "$(oracle_core_get_binary srvctl || echo '<not found>')"
    echo "==================================================="
}

# oracle_env_print_config_vars - Print Oracle configuration variables
# Usage: oracle_env_print_config_vars
oracle_env_print_config_vars() {
    config_print \
        "ORACLE_HOME" \
        "ORACLE_BASE" \
        "ORACLE_SID" \
        "ORACLE_UNQNAME" \
        "TNS_ADMIN" \
        "NLS_LANG" \
        "NLS_DATE_FORMAT"
}

#===============================================================================
# SECTION 8: Environment Switching
#===============================================================================

# oracle_env_switch_sid - Switch to a different SID
# Usage: oracle_env_switch_sid "NEWORCL"
oracle_env_switch_sid() {
    local new_sid="$1"
    local old_sid="${ORACLE_SID:-}"
    
    # Validate new SID
    oracle_core_validate_sid "${new_sid}"
    
    # Check for oratab entry
    local oratab_home
    oratab_home="$(oracle_core_oratab_home_for_sid "${new_sid}")"
    
    if [[ -n "${oratab_home}" ]]; then
        if [[ "${oratab_home}" != "${ORACLE_HOME:-}" ]]; then
            log "Switching ORACLE_HOME for SID ${new_sid}: ${oratab_home}"
            oracle_core_set_env "ORACLE_HOME=${oratab_home}" "ORACLE_SID=${new_sid}"
        else
            export ORACLE_SID="${new_sid}"
        fi
    else
        export ORACLE_SID="${new_sid}"
    fi
    
    log_debug "Switched SID: ${old_sid:-<none>} -> ${new_sid}"
}

# oracle_env_use_home - Set ORACLE_HOME and update PATH
# Usage: oracle_env_use_home "/u01/app/oracle/product/19c/dbhome_1"
oracle_env_use_home() {
    local new_home="$1"
    
    rt_assert_nonempty "ORACLE_HOME" "${new_home}"
    rt_assert_abs_path "ORACLE_HOME" "${new_home}"
    rt_assert_dir_exists "ORACLE_HOME" "${new_home}"
    
    oracle_core_set_env "ORACLE_HOME=${new_home}"
    log "Using ORACLE_HOME: ${new_home}"
}
