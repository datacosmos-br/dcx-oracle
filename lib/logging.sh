#!/usr/bin/env bash
# shellcheck shell=bash
#===============================================================================
# Datacosmos - Logging & Output Library
#
# Copyright (c) 2026 Datacosmos
# Licensed under the Apache License, Version 2.0
#===============================================================================
# File    : logging.sh
# Version : 3.0.0
# Date    : 2026-01-15
#===============================================================================
#
# DESCRIPTION:
#   Advanced structured logging system with automatic context capture,
#   module-level log control, optional structured output (JSON), and
#   integration with config.sh for centralized configuration.
#
# LOG LEVELS:
#   DEBUG  - Detailed diagnostic information
#   INFO   - General operational messages
#   CMD    - Commands being executed (bash, SQL, etc)
#   SQL    - SQL statements being executed
#   BLOCK  - Blocking operations (confirmations, waits)
#   WARN   - Warning conditions
#   ERROR  - Error conditions
#   SUCCESS- Successful completion markers
#
# USAGE:
#   source "$(dirname "$0")/lib/logging.sh"
#
#===============================================================================

# Prevent double sourcing
[[ -n "${__LOGGING_LOADED:-}" ]] && return 0
__LOGGING_LOADED=1

#===============================================================================
# SECTION 1: Configuration
#===============================================================================

# Log level (0=quiet, 1=normal, 2=verbose, 3=debug)
LOG_LEVEL="${LOG_LEVEL:-2}"

# Enable/disable specific log types
LOG_SHOW_TIMESTAMP="${LOG_SHOW_TIMESTAMP:-1}"
LOG_SHOW_CMD="${LOG_SHOW_CMD:-1}"
LOG_SHOW_SQL="${LOG_SHOW_SQL:-1}"
LOG_SHOW_BLOCK="${LOG_SHOW_BLOCK:-1}"

# Colors (ANSI escape codes, empty if NO_COLOR is set)
if [[ -z "${NO_COLOR:-}" ]]; then
    _C_RESET='\033[0m'
    _C_BOLD='\033[1m'
    _C_DIM='\033[2m'
    _C_RED='\033[31m'
    _C_GREEN='\033[32m'
    _C_YELLOW='\033[33m'
    _C_BLUE='\033[34m'
    _C_MAGENTA='\033[35m'
    _C_CYAN='\033[36m'
    _C_GRAY='\033[90m'
else
    _C_RESET='' _C_BOLD='' _C_DIM='' _C_RED='' _C_GREEN=''
    _C_YELLOW='' _C_BLUE='' _C_MAGENTA='' _C_CYAN='' _C_GRAY=''
fi

# Globals set by runtime_init_logs
LOGDIR="${LOGDIR:-}"
MAIN_LOG="${MAIN_LOG:-}"

# Module-level log control (set via config.sh)
# Format: MODULE_NAME=LEVEL (e.g., "oracle=DEBUG", "config=INFO")
declare -gA LOG_MODULE_LEVELS

# Structured logging (JSON output)
LOG_STRUCTURED="${LOG_STRUCTURED:-0}"

# Context tracking
LOG_SHOW_CONTEXT="${LOG_SHOW_CONTEXT:-0}"  # Show function/module/line in logs

#===============================================================================
# SECTION 2: Timestamp & Basic Logging
#===============================================================================

# ts - Returns current timestamp in ISO format
# Usage: echo "$(ts) Something happened"
ts() { date "+%Y-%m-%d %H:%M:%S"; }

# _get_caller_context - Internal: get caller function, module, and line
_get_caller_context() {
    local depth="${1:-2}"  # Default: skip _log_with_context and actual log function
    local caller_func="${FUNCNAME[${depth}]:-<unknown>}"
    local caller_file="${BASH_SOURCE[${depth}]:-<unknown>}"
    local caller_line="${BASH_LINENO[$((depth-1))]:-0}"
    
    # Extract module name from file path
    local module_name
    if [[ "${caller_file}" == *"/lib/"* ]]; then
        module_name=$(basename "${caller_file}" .sh)
    else
        module_name=$(basename "${caller_file}")
    fi
    
    echo "${caller_func}|${module_name}|${caller_line}"
}

# _check_module_log_level - Internal: check if log level is enabled for module
_check_module_log_level() {
    local level="$1"
    local module="$2"
    
    # If no module specified, allow all
    [[ -z "${module}" ]] && return 0
    
    # Check module-specific level
    local module_level="${LOG_MODULE_LEVELS["${module}"]:-}"
    if [[ -n "${module_level}" ]]; then
        case "${module_level}" in
            DEBUG) return 0 ;;  # DEBUG allows all
            INFO) [[ "${level}" != "DEBUG" ]] && return 0 || return 1 ;;
            WARN) [[ "${level}" == "WARN" || "${level}" == "ERROR" || "${level}" == "FATAL" ]] && return 0 || return 1 ;;
            ERROR) [[ "${level}" == "ERROR" || "${level}" == "FATAL" ]] && return 0 || return 1 ;;
            *) return 0 ;;  # Unknown level, allow
        esac
    fi
    
    # Fall back to global LOG_LEVEL
    case "${level}" in
        DEBUG) [[ "${LOG_LEVEL}" -ge 3 ]] && return 0 || return 1 ;;
        INFO) [[ "${LOG_LEVEL}" -ge 1 ]] && return 0 || return 1 ;;
        *) return 0 ;;  # WARN, ERROR, FATAL always shown
    esac
}

# _log_prefix - Internal: generate log prefix with optional timestamp and context
_log_prefix() {
    local level="$1"
    local context="${2:-}"
    
    local prefix=""
    if [[ "${LOG_SHOW_TIMESTAMP}" == "1" ]]; then
        prefix="[$(ts)]"
    fi
    
    prefix="${prefix} [${level}]"
    
    # Add context if enabled
    if [[ "${LOG_SHOW_CONTEXT}" == "1" ]] && [[ -n "${context}" ]]; then
        local func module line
        IFS='|' read -r func module line <<< "${context}"
        prefix="${prefix} [${module}:${func}:${line}]"
    fi
    
    echo "${prefix}"
}

# _log_with_context - Internal: log with automatic context capture
# Usage: _log_with_context "LEVEL" "message..."
# Note: Depth is hardcoded to 2 to skip: (1) this function, (2) the calling wrapper (log/warn/die)
_log_with_context() {
    local level="${1?ERROR: _log_with_context requires level parameter}"
    shift
    local msg="$*"
    local depth=2  # Stack depth: skip _log_with_context + calling wrapper (log/warn/die/etc)
    
    # Get context
    local context
    context=$(_get_caller_context "${depth}")
    local func module line
    IFS='|' read -r func module line <<< "${context}"
    
    # Check module log level
    _check_module_log_level "${level}" "${module}" || return 0
    
    # Generate prefix
    local prefix
    prefix=$(_log_prefix "${level}" "${context}")
    
    # Structured logging (JSON)
    if [[ "${LOG_STRUCTURED}" == "1" ]]; then
        local timestamp
        timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%d %H:%M:%S")
        echo "{\"timestamp\":\"${timestamp}\",\"level\":\"${level}\",\"module\":\"${module}\",\"function\":\"${func}\",\"line\":${line},\"message\":\"${msg}\"}"
        return 0
    fi
    
    # Regular logging
    case "${level}" in
        DEBUG)
            echo -e "${_C_GRAY}${prefix} ${msg}${_C_RESET}"
            ;;
        INFO)
            echo "${prefix} ${msg}"
            ;;
        SUCCESS)
            echo -e "${_C_GREEN}${prefix} ${msg}${_C_RESET}"
            ;;
        WARN)
            echo -e "${_C_YELLOW}${prefix} ${msg}${_C_RESET}" >&2
            ;;
        ERROR|FATAL)
            echo -e "${_C_RED}${prefix} ${msg}${_C_RESET}" >&2
            ;;
        *)
            echo "${prefix} ${msg}"
            ;;
    esac
}

# log - Print timestamped message to stdout (with context)
# Usage: log "Starting process..."
log() { _log_with_context "INFO" "$@"; }

# warn - Print timestamped warning to stderr (with context)
# Usage: warn "Configuration file not found, using defaults"
warn() { _log_with_context "WARN" "$@"; }

# die - Print error message and exit with code 1 (with context)
# Usage: die "Fatal error: cannot continue"
die() {
    _log_with_context "FATAL" "$@"
    exit 1
}

#===============================================================================
# SECTION 3: Structured Log Levels
#===============================================================================

# log_debug - Debug level message (with context, respects module levels)
# Usage: log_debug "Variable x = ${x}"
log_debug() {
    _log_with_context "DEBUG" "$@"
    return 0
}

# log_info - Information message (with context)
# Usage: log_info "Processing started"
log_info() { _log_with_context "INFO" "$@"; }

# log_success - Success message (with context)
# Usage: log_success "Migration completed"
log_success() {
    _log_with_context "SUCCESS" "$@"
}

# log_error - Error message (with context, to stderr)
# Usage: log_error "Failed to connect"
log_error() {
    _log_with_context "ERROR" "$@"
}

#===============================================================================
# SECTION 4: Command Logging
#===============================================================================

# log_cmd - Log a command being executed
# Usage: log_cmd "impdp" "user/pass@db parfile=x.par"
# Shows: [CMD] impdp user/***@db parfile=x.par
log_cmd() {
    [[ "${LOG_SHOW_CMD}" != "1" ]] && return 0

    local cmd="${1?ERROR: log_cmd requires command parameter}"
    shift
    local args="$*"

    # Mask passwords (pattern: word/word@word)
    local masked_args
    masked_args=$(echo "$args" | sed -E 's|([A-Za-z0-9_]+)/[^@]+@|\\1/***@|g')

    echo -e "${_C_CYAN}$(_log_prefix CMD) ${_C_BOLD}${cmd}${_C_RESET}${_C_CYAN} ${masked_args}${_C_RESET}"
}

# log_cmd_start - Log start of a command execution
# Usage: log_cmd_start "impdp" "Starting import..."
log_cmd_start() {
    local cmd="$1"
    local desc="${2:-}"
    echo -e "${_C_CYAN}$(_log_prefix CMD) ▶ ${_C_BOLD}${cmd}${_C_RESET}${_C_CYAN}${desc:+ - ${desc}}${_C_RESET}"
}

# log_cmd_end - Log end of a command execution
# Usage: log_cmd_end "impdp" 0 "45s"
log_cmd_end() {
    local cmd="$1"
    local exit_code="$2"
    local duration="${3:-}"

    if [[ "${exit_code}" -eq 0 ]]; then
        echo -e "${_C_GREEN}$(_log_prefix CMD) ✓ ${cmd} completed${duration:+ (${duration})}${_C_RESET}"
    else
        echo -e "${_C_RED}$(_log_prefix CMD) ✗ ${cmd} failed (exit=${exit_code})${duration:+ (${duration})}${_C_RESET}"
    fi
}

#===============================================================================
# SECTION 5: SQL Logging
#===============================================================================

# log_sql - Log SQL statement being executed (with context)
# Usage: log_sql "SELECT" "SELECT CURRENT_SCN FROM V\$DATABASE@DBLINK"
log_sql() {
    [[ "${LOG_SHOW_SQL}" != "1" ]] && return 0

    local op="$1"
    local sql="$2"

    # Truncate long SQL for display
    local display_sql="$sql"
    if [[ ${#sql} -gt 100 ]]; then
        display_sql="${sql:0:100}..."
    fi

    # Get context
    local context
    context=$(_get_caller_context 2)
    local prefix
    prefix=$(_log_prefix "SQL" "${context}")

    echo -e "${_C_MAGENTA}${prefix} ${_C_BOLD}${op}${_C_RESET}${_C_MAGENTA}: ${display_sql}${_C_RESET}"
}

# log_sql_file - Log SQL file being executed
# Usage: log_sql_file "grants.sql" "/path/to/grants.sql"
log_sql_file() {
    [[ "${LOG_SHOW_SQL}" != "1" ]] && return 0

    local name="$1"
    local path="$2"

    echo -e "${_C_MAGENTA}$(_log_prefix SQL) Executing script: ${_C_BOLD}${name}${_C_RESET}${_C_MAGENTA} (${path})${_C_RESET}"
}

# log_sql_result - Log SQL execution result (with context)
# Usage: log_sql_result 0 "1234567890"
log_sql_result() {
    [[ "${LOG_SHOW_SQL}" != "1" ]] && return 0

    local exit_code="$1"
    local result="${2:-}"

    # Get context
    local context
    context=$(_get_caller_context 2)
    local prefix
    prefix=$(_log_prefix "SQL" "${context}")

    if [[ "${exit_code}" -eq 0 ]]; then
        if [[ -n "${result}" ]]; then
            echo -e "${_C_MAGENTA}${prefix} → Result: ${result}${_C_RESET}"
        else
            echo -e "${_C_MAGENTA}${prefix} → OK${_C_RESET}"
        fi
    else
        echo -e "${_C_RED}${prefix} → FAILED (exit=${exit_code})${_C_RESET}"
    fi
}

#===============================================================================
# SECTION 6: Blocking Operations Logging
#===============================================================================

# log_block_start - Log start of blocking operation
# Usage: log_block_start "WAIT" "Waiting for export to complete..."
# Usage: log_block_start "SECTION_NAME"  (desc is optional)
log_block_start() {
    [[ "${LOG_SHOW_BLOCK}" != "1" ]] && return 0

    local type="$1"
    local desc="${2:-}"

    if [[ -n "${desc}" ]]; then
        echo -e "${_C_YELLOW}$(_log_prefix BLOCK) ⏳ ${type}: ${desc}${_C_RESET}"
    else
        echo -e "${_C_YELLOW}$(_log_prefix BLOCK) ⏳ ${type}${_C_RESET}"
    fi
}

# log_block_end - Log end of blocking operation
# Usage: log_block_end "WAIT" "Export completed"
# Usage: log_block_end "SECTION_NAME"  (desc is optional)
log_block_end() {
    [[ "${LOG_SHOW_BLOCK}" != "1" ]] && return 0

    local type="$1"
    local desc="${2:-}"

    if [[ -n "${desc}" ]]; then
        echo -e "${_C_GREEN}$(_log_prefix BLOCK) ✓ ${type}: ${desc}${_C_RESET}"
    else
        echo -e "${_C_GREEN}$(_log_prefix BLOCK) ✓ ${type}${_C_RESET}"
    fi
}

# log_confirm - Log confirmation request
# Usage: log_confirm "Proceed with migration?" "YES"
log_confirm() {
    [[ "${LOG_SHOW_BLOCK}" != "1" ]] && return 0

    local question="$1"
    local token="$2"

    echo -e "${_C_YELLOW}$(_log_prefix CONFIRM) ${question} [type: ${token}]${_C_RESET}"
}

# log_lock - Log lock acquisition/release
# Usage: log_lock "ACQUIRE" "/tmp/migration.lock"
log_lock() {
    local action="$1"
    local lockfile="$2"

    case "${action}" in
        ACQUIRE)
            echo -e "${_C_BLUE}$(_log_prefix LOCK) Acquiring lock: ${lockfile}${_C_RESET}"
            ;;
        RELEASE)
            echo -e "${_C_BLUE}$(_log_prefix LOCK) Releasing lock: ${lockfile}${_C_RESET}"
            ;;
        BLOCKED)
            echo -e "${_C_RED}$(_log_prefix LOCK) Blocked by existing lock: ${lockfile}${_C_RESET}"
            ;;
    esac
}

#===============================================================================
# SECTION 7: Progress & Status Display
#===============================================================================

# log_progress - Log progress update
# Usage: log_progress 5 10 "Importing parfiles"
log_progress() {
    local current="$1"
    local total="$2"
    local desc="${3:-}"

    local pct=$((current * 100 / total))
    echo -e "${_C_BLUE}$(_log_prefix PROGRESS) [${current}/${total}] (${pct}%)${desc:+ ${desc}}${_C_RESET}"
}

# log_step - Log a step in a multi-step process
# Usage: log_step 3 "Validating configuration"
log_step() {
    local num="$1"
    local desc="$2"

    echo
    echo -e "${_C_BOLD}>> Step ${num}: ${desc}${_C_RESET}"
}

# log_phase - Log a major phase
# Usage: log_phase "A" "Validation & Discovery"
log_phase() {
    local id="$1"
    local name="$2"

    echo
    echo "════════════════════════════════════════════════════════════════════"
    echo -e "  ${_C_BOLD}PHASE ${id}: ${name}${_C_RESET}"
    echo "════════════════════════════════════════════════════════════════════"
}

#===============================================================================
# SECTION 8: Log Initialization
#===============================================================================

# runtime_init_logs - Initialize logging with tee to file
# Usage: runtime_init_logs "/var/log/myapp" "myapp_run"
# Creates: LOGDIR, MAIN_LOG variables and redirects all output to log file
runtime_init_logs() {
    local logdir="$1" base="$2"
    mkdir -p "${logdir}"
    LOGDIR="${logdir}"
    MAIN_LOG="${logdir}/${base}_$(date +%Y%m%d_%H%M%S).log"
    exec > >(tee -a "${MAIN_LOG}") 2>&1
    
    # Log initialization (use direct echo to avoid recursion)
    if [[ "${LOG_SHOW_TIMESTAMP}" == "1" ]]; then
        echo "[$(ts)] [INFO] Log initialized: ${MAIN_LOG}"
    else
        echo "[INFO] Log initialized: ${MAIN_LOG}"
    fi
}

# log_set_module_level - Set log level for specific module
# Usage: log_set_module_level "oracle" "DEBUG"
log_set_module_level() {
    local module="$1"
    local level="$2"
    LOG_MODULE_LEVELS["${module}"]="${level}"
    log_debug "Module ${module} log level set to ${level}"
}

# log_get_module_level - Get log level for specific module
# Usage: level=$(log_get_module_level "oracle")
log_get_module_level() {
    local module="$1"
    echo "${LOG_MODULE_LEVELS["${module}"]:-${LOG_LEVEL}}"
}

# log_configure_from_env - Configure logging from environment variables
# Usage: log_configure_from_env
# Reads: LOG_LEVEL, LOG_SHOW_*, LOG_MODULE_LEVELS_*, LOG_STRUCTURED, LOG_SHOW_CONTEXT
log_configure_from_env() {
    # Parse module levels from LOG_MODULE_LEVELS_* env vars
    local var
    for var in "${!LOG_MODULE_LEVELS_@}"; do
        local module="${var#LOG_MODULE_LEVELS_}"
        module="${module,,}"  # Convert to lowercase
        local level="${!var}"
        log_set_module_level "${module}" "${level}"
    done
    
    log_debug "Logging configured from environment"
}

# log_to_file - Log message to specific file (append)
# Usage: log_to_file "/path/to/file.log" "Message to log"
log_to_file() {
    local file="$1"
    shift
    echo "[$(ts)] $*" >> "${file}"
}

#===============================================================================
# SECTION 9: File Display
#===============================================================================

# show_file - Display first N lines of a file with header
# Usage: show_file "/path/to/file" 50
show_file() {
    local f="$1" n="${2:-200}"
    echo
    echo "─────────────────────────────────────────────────────────────"
    echo "  FILE: ${f}"
    echo "  (first ${n} lines)"
    echo "─────────────────────────────────────────────────────────────"
    if [[ -f "${f}" ]]; then
        sed -n "1,${n}p" "${f}" | cat -n
    else
        echo "  (file does not exist)"
    fi
    echo "─────────────────────────────────────────────────────────────"
}

#===============================================================================
# SECTION 10: Display Utilities
#===============================================================================

# runtime_print_kv - Print key-value pair aligned
# Usage: runtime_print_kv "Database Name" "PRODDB"
runtime_print_kv() {
    printf "  %-26s : %s\n" "$1" "$2"
}

# runtime_print_vars - Print section with multiple key=value pairs
# Usage: runtime_print_vars "Configuration" "USER=admin" "HOST=localhost"
runtime_print_vars() {
    local title="$1"; shift
    echo
    echo "┌─────────────────────────────────────────────────────────────┐"
    echo "│ ${title}"
    echo "├─────────────────────────────────────────────────────────────┤"
    local kv k v
    for kv in "$@"; do
        k="${kv%%=*}"
        v="${kv#*=}"
        runtime_print_kv "${k}" "${v}"
    done
    echo "└─────────────────────────────────────────────────────────────┘"
}

# runtime_print_section - Print section header
# Usage: runtime_print_section "Starting Phase 2"
runtime_print_section() {
    local title="$1"
    echo
    echo "================================================================"
    echo "  ${title}"
    echo "================================================================"
}

# runtime_print_separator - Print a separator line
# Usage: runtime_print_separator
runtime_print_separator() {
    echo "----------------------------------------------------------------"
}

# runtime_print_header - Print prominent header
# Usage: runtime_print_header "MIGRATION STARTED"
runtime_print_header() {
    local title="$1"
    echo
    echo "╔═══════════════════════════════════════════════════════════════╗"
    echo "║  ${title}"
    echo "╚═══════════════════════════════════════════════════════════════╝"
}

# runtime_print_step - Print step indicator
# Usage: runtime_print_step "Validating configuration"
runtime_print_step() {
    echo
    echo ">> $1"
}

#===============================================================================
# SECTION 11: Legacy Aliases (backward compatibility) - REMOVED
#===============================================================================
# Removed print_info, print_success, print_error, print_warning, print_step wrappers.
# Use direct functions: log_info, log_success, log_error, warn, log_step

#===============================================================================
# SECTION 12: Host Reporting
#===============================================================================

# runtime_write_host_report - Write system information to file
# Usage: runtime_write_host_report "/tmp/host_report.txt" [custom_callback]
runtime_write_host_report() {
    local outfile="$1"
    local custom_callback="${2:-}"

    {
        echo "=== DATE ==="; date; echo
        echo "=== UNAME ==="; uname -a; echo
        echo "=== USER ==="; id; echo
        echo "=== CPU ==="
        (command -v lscpu >/dev/null 2>&1 && lscpu) || (head -n 40 /proc/cpuinfo 2>/dev/null || echo "N/A")
        echo
        echo "=== MEM ==="; free -h 2>/dev/null || echo "N/A"; echo
        echo "=== ULIMIT ==="; ulimit -a 2>/dev/null || echo "N/A"; echo
        echo "=== DF (FS) ==="; df -h 2>/dev/null || echo "N/A"; echo

        if [[ -n "${custom_callback}" ]] && declare -F "${custom_callback}" >/dev/null; then
            echo "=== CUSTOM ==="
            "${custom_callback}"
            echo
        fi
    } > "${outfile}"

    log "Host report: ${outfile}"
}

#===============================================================================
# SECTION 13: Summary Tables
#===============================================================================

# log_summary_table - Print a summary table
# Usage: log_summary_table "MIGRATION SUMMARY" "Total|17" "Success|15" "Failed|2"
log_summary_table() {
    local title="$1"
    shift

    echo
    echo "┌─────────────────────────────────────────────────────────────┐"
    echo "│ ${title}"
    echo "├─────────────────────────────────────────────────────────────┤"
    for row in "$@"; do
        local key="${row%%|*}"
        local val="${row#*|}"
        printf "│  %-24s : %s\n" "${key}" "${val}"
    done
    echo "└─────────────────────────────────────────────────────────────┘"
}
