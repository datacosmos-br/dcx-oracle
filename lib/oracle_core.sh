#!/usr/bin/env bash
# shellcheck shell=bash
#===============================================================================
# Datacosmos - Oracle Core Module
#
# Copyright (c) 2026 Datacosmos
# Licensed under the Apache License, Version 2.0
#===============================================================================
# File    : oracle_core.sh
# Version : 1.1.0
# Date    : 2026-01-15
#===============================================================================
#
# DESCRIPTION:
#   Core Oracle functionality: environment validation, binary discovery,
#   and base environment variable management. This is the foundation module
#   that all other Oracle modules depend on.
#
# DEPENDS ON:
#   - runtime.sh (for rt_assert_*, has_cmd, need_cmd, runtime_capture, runtime_exec_logged)
#   - logging.sh (for log, warn, die, log_debug)
#
# PROVIDES:
#   Environment:
#     - oracle_core_validate_home()     - Validate ORACLE_HOME
#     - oracle_core_discover_binaries() - Discover Oracle binaries
#     - oracle_core_set_env()           - Set Oracle environment
#     - oracle_core_get_env()           - Get current environment
#     - oracle_core_validate_env()      - Full environment validation
#
#   Execution Wrappers:
#     - oracle_core_exec()              - Execute with logging and timing
#     - oracle_core_exec_to_file()      - Execute with output to file
#     - oracle_core_exec_silent()       - Execute silently, log on error
#     - oracle_core_exec_with_sid()     - Execute with specific SID
#
#===============================================================================

# Prevent double sourcing
[[ -n "${__ORACLE_CORE_LOADED:-}" ]] && return 0
__ORACLE_CORE_LOADED=1

# Resolve library directory
_ORACLE_CORE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load runtime.sh (provides rt_assert_*, has_cmd, need_cmd, runtime_capture)
# shellcheck source=/dev/null
[[ -z "${__RUNTIME_LOADED:-}" ]] && source "${_ORACLE_CORE_LIB_DIR}/runtime.sh"

#===============================================================================
# INTERNAL STATE
#===============================================================================

# Binary paths cache
declare -g _ORACLE_SQLPLUS_PATH=""
declare -g _ORACLE_RMAN_PATH=""
declare -g _ORACLE_IMPDP_PATH=""
declare -g _ORACLE_EXPDP_PATH=""
declare -g _ORACLE_SRVCTL_PATH=""
declare -g _ORACLE_CRSCTL_PATH=""
declare -g _ORACLE_ASMCMD_PATH=""

# Environment validation state
declare -g _ORACLE_ENV_VALIDATED=0

#===============================================================================
# SECTION 1: ORACLE_HOME Validation
#===============================================================================

# oracle_core_validate_home - Validate ORACLE_HOME is properly configured
# Usage: oracle_core_validate_home
# Dies if ORACLE_HOME is not valid
oracle_core_validate_home() {
    log_debug "Validating ORACLE_HOME..."
    
    # Check ORACLE_HOME is set and non-empty
    rt_assert_nonempty "ORACLE_HOME" "${ORACLE_HOME:-}"
    
    # Check ORACLE_HOME is absolute path
    rt_assert_abs_path "ORACLE_HOME" "${ORACLE_HOME}"
    
    # Check ORACLE_HOME directory exists
    rt_assert_dir_exists "ORACLE_HOME" "${ORACLE_HOME}"
    
    # Check bin directory exists
    rt_assert_dir_exists "ORACLE_HOME/bin" "${ORACLE_HOME}/bin"
    
    log_debug "ORACLE_HOME validated: ${ORACLE_HOME}"
    return 0
}

# oracle_core_check_home - Check ORACLE_HOME without dying (returns boolean)
# Usage: if oracle_core_check_home; then ...
oracle_core_check_home() {
    [[ -n "${ORACLE_HOME:-}" ]] || return 1
    [[ "${ORACLE_HOME}" == /* ]] || return 1
    [[ -d "${ORACLE_HOME}" ]] || return 1
    [[ -d "${ORACLE_HOME}/bin" ]] || return 1
    return 0
}

#===============================================================================
# SECTION 2: Binary Discovery
#===============================================================================

# oracle_core_find_binary - Find Oracle binary in ORACLE_HOME or PATH
# Usage: path=$(oracle_core_find_binary "sqlplus")
# Returns: Full path to binary, or empty string if not found
oracle_core_find_binary() {
    local binary="$1"
    local path=""
    
    # First try ORACLE_HOME/bin
    if [[ -n "${ORACLE_HOME:-}" ]] && [[ -x "${ORACLE_HOME}/bin/${binary}" ]]; then
        path="${ORACLE_HOME}/bin/${binary}"
    # Then try PATH
    elif has_cmd "${binary}"; then
        path="$(command -v "${binary}")"
    fi
    
    log_debug "Binary ${binary}: ${path:-<not found>}"
    echo "${path}"
}

# oracle_core_discover_binaries - Discover all Oracle binaries
# Usage: oracle_core_discover_binaries
# Sets global variables for binary paths
oracle_core_discover_binaries() {
    log_debug "Discovering Oracle binaries..."
    
    _ORACLE_SQLPLUS_PATH="$(oracle_core_find_binary "sqlplus")"
    _ORACLE_RMAN_PATH="$(oracle_core_find_binary "rman")"
    _ORACLE_IMPDP_PATH="$(oracle_core_find_binary "impdp")"
    _ORACLE_EXPDP_PATH="$(oracle_core_find_binary "expdp")"
    _ORACLE_SRVCTL_PATH="$(oracle_core_find_binary "srvctl")"
    _ORACLE_CRSCTL_PATH="$(oracle_core_find_binary "crsctl")"
    _ORACLE_ASMCMD_PATH="$(oracle_core_find_binary "asmcmd")"
    
    log_debug "Binaries discovered:"
    log_debug "  sqlplus: ${_ORACLE_SQLPLUS_PATH:-<not found>}"
    log_debug "  rman:    ${_ORACLE_RMAN_PATH:-<not found>}"
    log_debug "  impdp:   ${_ORACLE_IMPDP_PATH:-<not found>}"
    log_debug "  expdp:   ${_ORACLE_EXPDP_PATH:-<not found>}"
    log_debug "  srvctl:  ${_ORACLE_SRVCTL_PATH:-<not found>}"
    log_debug "  crsctl:  ${_ORACLE_CRSCTL_PATH:-<not found>}"
    log_debug "  asmcmd:  ${_ORACLE_ASMCMD_PATH:-<not found>}"
}

# oracle_core_require_binary - Ensure required binary is available
# Usage: oracle_core_require_binary "sqlplus"
# Dies if binary not found
oracle_core_require_binary() {
    local binary="$1"
    local path
    path="$(oracle_core_find_binary "${binary}")"
    
    [[ -n "${path}" ]] || die "Oracle binary not found: ${binary}"
    log_debug "Required binary found: ${binary} -> ${path}"
}

# oracle_core_require_binaries - Ensure multiple binaries are available
# Usage: oracle_core_require_binaries sqlplus rman
oracle_core_require_binaries() {
    local binary
    for binary in "$@"; do
        oracle_core_require_binary "${binary}"
    done
}

# oracle_core_get_binary - Get cached binary path
# Usage: SQLPLUS=$(oracle_core_get_binary "sqlplus")
oracle_core_get_binary() {
    local binary="$1"
    case "${binary}" in
        sqlplus) echo "${_ORACLE_SQLPLUS_PATH}" ;;
        rman)    echo "${_ORACLE_RMAN_PATH}" ;;
        impdp)   echo "${_ORACLE_IMPDP_PATH}" ;;
        expdp)   echo "${_ORACLE_EXPDP_PATH}" ;;
        srvctl)  echo "${_ORACLE_SRVCTL_PATH}" ;;
        crsctl)  echo "${_ORACLE_CRSCTL_PATH}" ;;
        asmcmd)  echo "${_ORACLE_ASMCMD_PATH}" ;;
        *)       oracle_core_find_binary "${binary}" ;;
    esac
}

# oracle_core_has_binary - Check if binary is available (boolean)
# Usage: if oracle_core_has_binary "srvctl"; then ...
oracle_core_has_binary() {
    local binary="$1"
    local path
    path="$(oracle_core_get_binary "${binary}")"
    [[ -n "${path}" ]] && [[ -x "${path}" ]]
}

#===============================================================================
# SECTION 3: Environment Management
#===============================================================================

# oracle_core_set_env - Set Oracle environment variables
# Usage: oracle_core_set_env ORACLE_HOME="/u01/app/oracle" ORACLE_SID="ORCL"
oracle_core_set_env() {
    local kv key val
    for kv in "$@"; do
        key="${kv%%=*}"
        val="${kv#*=}"
        export "${key}=${val}"
        log_debug "Set ${key}=${val}"
    done
    
    # Add ORACLE_HOME/bin to PATH if not already there
    if [[ -n "${ORACLE_HOME:-}" ]] && [[ ":${PATH}:" != *":${ORACLE_HOME}/bin:"* ]]; then
        export PATH="${ORACLE_HOME}/bin:${PATH}"
        log_debug "Added ${ORACLE_HOME}/bin to PATH"
    fi
    
    # Refresh binary discovery
    oracle_core_discover_binaries
}

# oracle_core_get_env - Get current Oracle environment as key=value pairs
# Usage: oracle_core_get_env
oracle_core_get_env() {
    echo "ORACLE_HOME=${ORACLE_HOME:-}"
    echo "ORACLE_BASE=${ORACLE_BASE:-}"
    echo "ORACLE_SID=${ORACLE_SID:-}"
    echo "ORACLE_UNQNAME=${ORACLE_UNQNAME:-}"
    echo "TNS_ADMIN=${TNS_ADMIN:-}"
    echo "NLS_LANG=${NLS_LANG:-}"
    echo "NLS_DATE_FORMAT=${NLS_DATE_FORMAT:-}"
    echo "PATH=${PATH:-}"
}

# oracle_core_print_env - Print Oracle environment summary
# Usage: oracle_core_print_env
oracle_core_print_env() {
    echo
    echo "==================== Oracle Environment ===================="
    runtime_print_kv "ORACLE_HOME" "${ORACLE_HOME:-<not set>}"
    runtime_print_kv "ORACLE_BASE" "${ORACLE_BASE:-<not set>}"
    runtime_print_kv "ORACLE_SID" "${ORACLE_SID:-<not set>}"
    runtime_print_kv "ORACLE_UNQNAME" "${ORACLE_UNQNAME:-<not set>}"
    runtime_print_kv "TNS_ADMIN" "${TNS_ADMIN:-<not set>}"
    runtime_print_kv "NLS_LANG" "${NLS_LANG:-<not set>}"
    echo "============================================================"
}

# oracle_core_validate_sid - Validate ORACLE_SID format
# Usage: oracle_core_validate_sid "ORCL"
oracle_core_validate_sid() {
    local sid="${1:-${ORACLE_SID:-}}"
    rt_assert_nonempty "ORACLE_SID" "${sid}"
    rt_assert_sid_token "ORACLE_SID" "${sid}"
    log_debug "ORACLE_SID validated: ${sid}"
}

# oracle_core_set_sid - Set ORACLE_SID with validation
# Usage: oracle_core_set_sid "ORCL"
oracle_core_set_sid() {
    local sid="$1"
    oracle_core_validate_sid "${sid}"
    export ORACLE_SID="${sid}"
    log_debug "ORACLE_SID set to: ${sid}"
}

#===============================================================================
# SECTION 4: Full Environment Validation
#===============================================================================

# oracle_core_validate_env - Full environment validation
# Usage: oracle_core_validate_env [--require-sid] [--require-sqlplus] [--require-rman]
oracle_core_validate_env() {
    local require_sid=0
    local require_sqlplus=0
    local require_rman=0
    local require_datapump=0
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --require-sid)      require_sid=1 ;;
            --require-sqlplus)  require_sqlplus=1 ;;
            --require-rman)     require_rman=1 ;;
            --require-datapump) require_datapump=1 ;;
            *) warn "Unknown option: $1" ;;
        esac
        shift
    done
    
    log_debug "Validating Oracle environment..."
    
    # Validate ORACLE_HOME (always required)
    oracle_core_validate_home
    
    # Discover binaries
    oracle_core_discover_binaries
    
    # Validate ORACLE_SID if required
    if [[ ${require_sid} -eq 1 ]]; then
        oracle_core_validate_sid
    fi
    
    # Validate required binaries
    if [[ ${require_sqlplus} -eq 1 ]]; then
        oracle_core_require_binary "sqlplus"
    fi
    
    if [[ ${require_rman} -eq 1 ]]; then
        oracle_core_require_binary "rman"
    fi
    
    if [[ ${require_datapump} -eq 1 ]]; then
        oracle_core_require_binary "impdp"
        oracle_core_require_binary "expdp"
    fi
    
    _ORACLE_ENV_VALIDATED=1
    log_debug "Oracle environment validated successfully"
}

# oracle_core_is_validated - Check if environment has been validated
# Usage: if oracle_core_is_validated; then ...
oracle_core_is_validated() {
    [[ ${_ORACLE_ENV_VALIDATED} -eq 1 ]]
}

#===============================================================================
# SECTION 5: ORATAB Utilities
#===============================================================================

# oracle_core_oratab_path - Get path to oratab file
# Usage: ORATAB=$(oracle_core_oratab_path)
oracle_core_oratab_path() {
    local oratab=""
    
    if [[ -f "/etc/oratab" ]]; then
        oratab="/etc/oratab"
    elif [[ -f "/var/opt/oracle/oratab" ]]; then
        oratab="/var/opt/oracle/oratab"
    fi
    
    echo "${oratab}"
}

# oracle_core_oratab_home_for_sid - Get ORACLE_HOME for SID from oratab
# Usage: HOME=$(oracle_core_oratab_home_for_sid "ORCL")
oracle_core_oratab_home_for_sid() {
    local sid="$1"
    local oratab
    oratab="$(oracle_core_oratab_path)"
    
    [[ -z "${oratab}" ]] && return 1
    [[ ! -f "${oratab}" ]] && return 1
    
    awk -F: -v sid="${sid}" '$1==sid {print $2; exit}' "${oratab}"
}

# oracle_core_oratab_list_sids - List all SIDs from oratab
# Usage: for sid in $(oracle_core_oratab_list_sids); do ...
oracle_core_oratab_list_sids() {
    local oratab
    oratab="$(oracle_core_oratab_path)"
    
    [[ -z "${oratab}" ]] && return 0
    [[ ! -f "${oratab}" ]] && return 0
    
    awk -F: '/^[^#]/ && NF>=2 {print $1}' "${oratab}" | sort -u
}

# oracle_core_check_oratab_mismatch - Check if ORACLE_HOME matches oratab entry
# Usage: oracle_core_check_oratab_mismatch "ORCL"
# Returns 0 if matches or no oratab, 1 if mismatch
oracle_core_check_oratab_mismatch() {
    local sid="${1:-${ORACLE_SID:-}}"
    [[ -z "${sid}" ]] && return 0
    
    local oratab_home
    oratab_home="$(oracle_core_oratab_home_for_sid "${sid}")"
    
    # No oratab entry - no mismatch
    [[ -z "${oratab_home}" ]] && return 0
    
    # Check for mismatch
    if [[ -n "${ORACLE_HOME:-}" ]] && [[ "${ORACLE_HOME}" != "${oratab_home}" ]]; then
        warn "ORACLE_HOME mismatch for SID ${sid}:"
        warn "  Current:  ${ORACLE_HOME}"
        warn "  Expected: ${oratab_home} (from oratab)"
        return 1
    fi
    
    return 0
}

#===============================================================================
# SECTION 6: Test Mode Support
#===============================================================================

# Global flag to skip actual Oracle commands (for testing)
SKIP_ORACLE_CMDS="${SKIP_ORACLE_CMDS:-0}"

# oracle_core_skip_oracle_cmds - Check if Oracle commands should be skipped
# Usage: if oracle_core_skip_oracle_cmds; then return 0; fi
oracle_core_skip_oracle_cmds() {
    [[ "${SKIP_ORACLE_CMDS:-0}" == "1" ]]
}

# oracle_core_set_test_mode - Enable/disable test mode
# Usage: oracle_core_set_test_mode 1
oracle_core_set_test_mode() {
    SKIP_ORACLE_CMDS="${1:-1}"
    export SKIP_ORACLE_CMDS
    log_debug "Test mode: SKIP_ORACLE_CMDS=${SKIP_ORACLE_CMDS}"
}

#===============================================================================
# SECTION 7: Oracle Command Execution Wrappers
#===============================================================================

# oracle_core_exec - Execute Oracle command with standard logging
# Usage: oracle_core_exec "description" "binary" [args...]
# Handles: test mode, timing, logging, error reporting
# Returns: command exit code (0 in test mode)
oracle_core_exec() {
    local desc="$1" binary="$2"
    shift 2
    
    # Skip in test mode
    if oracle_core_skip_oracle_cmds; then
        log "[TEST] Skipping: ${desc}"
        return 0
    fi
    
    runtime_exec_logged "${desc}" "${binary}" "$@"
}

# oracle_core_exec_to_file - Execute Oracle command with output to file
# Usage: oracle_core_exec_to_file "description" "log_file" "binary" [args...]
# Handles: test mode, timing, logging, error reporting
# Output goes to log_file instead of stdout
oracle_core_exec_to_file() {
    local desc="$1" logfile="$2" binary="$3"
    shift 3
    
    # Skip in test mode
    if oracle_core_skip_oracle_cmds; then
        log "[TEST] Skipping: ${desc}"
        return 0
    fi
    
    runtime_exec_logged_to_file "${desc}" "${logfile}" "${binary}" "$@"
}

# oracle_core_exec_silent - Execute Oracle command silently, only log on error
# Usage: oracle_core_exec_silent "description" "binary" [args...]
# Output is captured but only shown on failure
oracle_core_exec_silent() {
    local desc="$1" binary="$2"
    shift 2
    
    # Skip in test mode
    if oracle_core_skip_oracle_cmds; then
        log_debug "[TEST] Skipping: ${desc}"
        return 0
    fi
    
    runtime_exec_silent "${desc}" "${binary}" "$@"
}

# oracle_core_exec_with_sid - Execute Oracle command with specific ORACLE_SID
# Usage: oracle_core_exec_with_sid "SID" "description" "binary" [args...]
# Temporarily sets ORACLE_SID for the command execution
oracle_core_exec_with_sid() {
    local sid="$1" desc="$2" binary="$3"
    shift 3
    
    rt_assert_nonempty "sid" "${sid}"
    
    # Skip in test mode
    if oracle_core_skip_oracle_cmds; then
        log "[TEST] Skipping (SID=${sid}): ${desc}"
        return 0
    fi
    
    log_debug "Executing with ORACLE_SID=${sid}: ${desc}"
    ORACLE_SID="${sid}" runtime_exec_logged "${desc}" "${binary}" "$@"
}

#===============================================================================
# AUTO-INITIALIZATION
#===============================================================================

# Auto-discover binaries if ORACLE_HOME is already set
if oracle_core_check_home; then
    oracle_core_discover_binaries
fi
