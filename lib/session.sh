#!/usr/bin/env bash
# shellcheck shell=bash
#===============================================================================
# Datacosmos - Session Lifecycle Management
#
# Copyright (c) 2026 Datacosmos
# Licensed under the Apache License, Version 2.0
#===============================================================================
# File    : session.sh
# Version : 1.0.0
# Date    : 2026-01-15
#===============================================================================
#
# DESCRIPTION:
#   Centralized session lifecycle management. Provides ID generation,
#   initialization, and logging setup for coordinated script execution.
#
# USAGE:
#   source "$(dirname "$0")/lib/session.sh"
#   SESSION_ID=$(session_generate_id)
#   session_init "/tmp/logs" "myapp"
#   session_init_with_report "myscript" "My Script" "/tmp/logs/%s" "VAR1=val1"
#
# DEPENDS ON:
#   - runtime.sh (for directory, logging, error trap operations)
#   - logging.sh (for log output)
#   - report.sh (for report_init, report_meta) [lazy-loaded]
#
# EXPORTS:
#   - SESSION_ID: Unique session identifier (YYYYMMDD_HHMMSS)
#   - SESSION_DIR: Session log directory
#   - SESSION_LOG: Main session log file path
#
#===============================================================================

# Prevent double sourcing
[[ -n "${__SESSION_LOADED:-}" ]] && return 0
__SESSION_LOADED=1

_SESSION_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load dependencies
# shellcheck source=/dev/null
[[ -z "${__RUNTIME_LOADED:-}" ]] && source "${_SESSION_LIB_DIR}/runtime.sh" || true

#===============================================================================
# Global Session State
#===============================================================================

declare -g SESSION_ID=""           # Unique session identifier
declare -g SESSION_DIR=""          # Session log directory
declare -g SESSION_LOG=""          # Main session log file

#===============================================================================
# Session Management Functions
#===============================================================================

# session_generate_id - Generate unique session ID
# Usage: session_generate_id
# Returns: YYYYMMDD_HHMMSS format string on stdout
session_generate_id() {
    date +%Y%m%d_%H%M%S
}

# session_init - Initialize session with logs directory
# Usage: session_init <logs_base_dir> [prefix]
# Args:
#   logs_base_dir: Base directory for session logs
#   prefix: Log file prefix (default: "session")
# Exports:
#   SESSION_ID: Generated session identifier
#   SESSION_DIR: Full path to session log directory
#   SESSION_LOG: Full path to main session log file
session_init() {
    local logs_base="$1"
    local prefix="${2:-session}"

    SESSION_ID=$(session_generate_id)
    SESSION_DIR="${logs_base}/${SESSION_ID}"
    SESSION_LOG="${SESSION_DIR}/${prefix}_${SESSION_ID}.log"

    mkdir -p "${SESSION_DIR}"
    : > "${SESSION_LOG}"

    export SESSION_ID SESSION_DIR SESSION_LOG
    log_debug "Session initialized: ${SESSION_ID}"
}

# session_init_with_report - Initialize session + logging + report system
# Usage: session_init_with_report <script_name> <title> <logdir_pattern> [metadata_key1=val1 ...]
# Args:
#   script_name: Name of calling script (for logging)
#   title: Report title (displayed in output)
#   logdir_pattern: Log directory pattern (%s replaced with SESSION_ID)
#   metadata_key=val: Optional metadata pairs added to report
# Example:
#   session_init_with_report "restore" "RMAN Restore" "/tmp/restore_logs/%s" \
#     "ORACLE_SID=PROD" "TARGET_SID=RES"
# Exports:
#   SESSION_ID: Generated session identifier
#   LOGDIR: Full log directory path
session_init_with_report() {
    local script_name="${1?ERROR: session_init_with_report requires script_name}"
    local title="${2?ERROR: session_init_with_report requires title}"
    local logdir_pattern="${3?ERROR: session_init_with_report requires logdir_pattern}"
    shift 3

    # Load report.sh if not already loaded
    # shellcheck source=/dev/null
    [[ -z "${__REPORT_LOADED:-}" ]] && source "${_SESSION_LIB_DIR}/report.sh" || true

    # Generate session ID and setup logging
    export SESSION_ID="$(session_generate_id)"
    local logdir="$(printf "${logdir_pattern}" "${SESSION_ID}")"
    export LOGDIR="${logdir}"

    runtime_ensure_dir "${LOGDIR}"
    runtime_init_logs "${LOGDIR}" "${script_name}"
    runtime_enable_err_trap

    # Initialize report system
    report_init "${title}" "${LOGDIR}" "${SESSION_ID}"

    # Add metadata from arguments
    for kv in "$@"; do
        local key="${kv%%=*}"
        local val="${kv#*=}"
        report_meta "${key}" "${val}"
    done

    log_debug "Session initialized: ${SESSION_ID} (logdir=${LOGDIR})"
}

# session_get_current - Get current session ID
# Usage: session_get_current
# Returns: Current SESSION_ID on stdout
session_get_current() {
    echo "${SESSION_ID}"
}

# session_get_dir - Get session directory
# Usage: session_get_dir
# Returns: Current SESSION_DIR on stdout
session_get_dir() {
    echo "${SESSION_DIR}"
}

# session_get_log - Get session log file path
# Usage: session_get_log
# Returns: Current SESSION_LOG on stdout
session_get_log() {
    echo "${SESSION_LOG}"
}

# session_export_vars - Export session variables to environment
# Usage: session_export_vars
# Exports all session variables (SESSION_ID, SESSION_DIR, SESSION_LOG)
session_export_vars() {
    export SESSION_ID SESSION_DIR SESSION_LOG
}
