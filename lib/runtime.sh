#!/usr/bin/env bash
# shellcheck shell=bash
#===============================================================================
# Datacosmos - Runtime Utilities Library
#
# Copyright (c) 2026 Datacosmos
# Licensed under the Apache License, Version 2.0
#===============================================================================
# File    : runtime.sh
# Version : 3.2.0
# Date    : 2026-01-15
#===============================================================================
#
# DESCRIPTION:
#   Runtime utilities for bash scripts. Provides functions for error handling,
#   command validation, validators, output capture, lock files, retry/timeout,
#   filesystem operations, and time utilities.
#
# NOTE: Interactive confirmations (pause, confirm_token, etc.) have been moved
#       to report.sh as part of the unified workflow system.
#
# USAGE:
#   source "$(dirname "$0")/lib/runtime.sh"
#
# DEPENDS ON:
#   - logging.sh (for log, warn, die, ts, etc.)
#
#===============================================================================

# Prevent double sourcing
[[ -n "${__RUNTIME_LOADED:-}" ]] && return 0
__RUNTIME_LOADED=1

# Resolve library directory
_RUNTIME_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load logging.sh first (provides ts, log, warn, die, show_file, runtime_print_*, etc)
# shellcheck source=/dev/null
[[ -z "${__LOGGING_LOADED:-}" ]] && source "${_RUNTIME_LIB_DIR}/logging.sh"

# Load report.sh for operation tracking (optional, graceful)
# shellcheck source=/dev/null
[[ -z "${__REPORT_LOADED:-}" ]] && source "${_RUNTIME_LIB_DIR}/report.sh" 2>/dev/null || true

#===============================================================================
# SECTION 1: Error Handling
#===============================================================================

# on_err - Error trap handler for 'set -e' scripts
# Usage: trap 'on_err $LINENO "$BASH_COMMAND"' ERR
# Note: logging.sh is always loaded first, no fallback needed
on_err() {
    local exit_code=$?
    local line="$1"
    local cmd="$2"
    
    log_error "FALHA (exit=${exit_code}) linha ${line}: ${cmd}"
    [[ -n "${MAIN_LOG:-}" ]] && log_error "Log: ${MAIN_LOG}"
    exit "${exit_code}"
}

# runtime_enable_err_trap - Enable error trap with on_err handler
# Usage: runtime_enable_err_trap
runtime_enable_err_trap() {
    trap 'on_err $LINENO "$BASH_COMMAND"' ERR
}

#===============================================================================
# SECTION 2: Command Validation
# need_cmd - Assert command exists or die
# Usage: need_cmd sqlplus
need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Comando nao encontrado: $1"
}

# require_cmds - Assert multiple commands exist
# Usage: require_cmds sqlplus rman awk sed
require_cmds() {
    for c in "$@"; do
        need_cmd "${c}"
    done
}

# has_cmd - Check if command exists (returns boolean)
# Usage: has_cmd timeout && timeout 10 cmd || cmd
has_cmd() {
    command -v "$1" >/dev/null 2>&1
}

#===============================================================================
# SECTION 3: Validators
#===============================================================================

# rt_assert_nonempty - Assert variable is not empty
# Usage: rt_assert_nonempty "VAR_NAME" "${VAR_VALUE}"
rt_assert_nonempty() {
    [[ -n "${2:-}" ]] || die "${1} vazio."
}

# rt_assert_abs_path - Assert path is absolute
# Usage: rt_assert_abs_path "CONFIG_PATH" "${CONFIG_PATH}"
rt_assert_abs_path() {
    [[ "${2}" == /* ]] || die "${1} deve ser absoluto: ${2}"
}

# rt_assert_dir_exists - Assert directory exists
# Usage: rt_assert_dir_exists "BACKUP_DIR" "${BACKUP_DIR}"
rt_assert_dir_exists() {
    [[ -d "${2}" ]] || die "${1} nao existe: ${2}"
}

# rt_assert_file_exists - Assert file exists
# Usage: rt_assert_file_exists "CONFIG_FILE" "${CONFIG_FILE}"
rt_assert_file_exists() {
    [[ -f "${2}" ]] || die "${1} nao existe: ${2}"
}

# rt_assert_enum - Assert value is one of allowed values
# Usage: rt_assert_enum "MODE" "${MODE}" "FS" "ASM"
rt_assert_enum() {
    local name="$1" val="$2"
    shift 2
    for a in "$@"; do
        [[ "${val}" == "${a}" ]] && return 0
    done
    die "${name} invalido: '${val}'. Permitidos: $*"
}

# rt_assert_bool01 - Assert value is 0 or 1
# Usage: rt_assert_bool01 "ENABLED" "${ENABLED}"
rt_assert_bool01() {
    [[ "${2}" == "0" || "${2}" == "1" ]] || die "${1} invalido: '${2}' (use 0|1)"
}

# rt_assert_uint - Assert value is unsigned integer
# Usage: rt_assert_uint "COUNT" "${COUNT}"
rt_assert_uint() {
    [[ "${2}" =~ ^[0-9]+$ ]] || die "${1} invalido: '${2}' (deve ser inteiro)"
}

# rt_assert_sid_token - Assert value is valid SID token
# Usage: rt_assert_sid_token "SID" "${SID}"
rt_assert_sid_token() {
    [[ "${2}" =~ ^[A-Za-z0-9_]+$ ]] || die "${1} invalido: '${2}' ([A-Za-z0-9_])"
}

# rt_assert_regex - Assert value matches regex pattern
# Usage: rt_assert_regex "EMAIL" "${EMAIL}" '^[a-z]+@[a-z]+\.[a-z]+$'
rt_assert_regex() {
    local name="$1" val="$2" pattern="$3"
    [[ "${val}" =~ ${pattern} ]] || die "${1} invalido: '${val}' (pattern: ${pattern})"
}

#===============================================================================
# SECTION 4: Output Capture
#===============================================================================

# runtime_capture - Capture command output to variable
# Usage: runtime_capture output_var command args...
# Returns: command exit code, output in variable
# Note: Uses __-prefixed locals to avoid name collision with caller's variable
runtime_capture() {
    local __outvar="$1"
    shift
    local __out __rc
    set +e
    __out="$("$@" 2>&1)"
    __rc=$?
    set -e
    printf -v "${__outvar}" '%s' "${__out}"
    return "${__rc}"
}

#===============================================================================
# SECTION 5: Lock Files
#===============================================================================

# runtime_lock_file - Acquire exclusive lock via file
# Usage: runtime_lock_file "/tmp/myapp.lock"
runtime_lock_file() {
    local lf="$1"
    mkdir -p "$(dirname "${lf}")"
    if [[ -f "${lf}" ]]; then
        local p
        p="$(cat "${lf}" 2>/dev/null)"
        if [[ -n "$p" ]] && kill -0 "$p" 2>/dev/null; then
            die "Ja em execucao (PID=$p)"
        fi
        rm -f "${lf}"
    fi
    echo $$ > "${lf}"
    # shellcheck disable=SC2064  # Intentional: expand lf NOW, not at trap time
    trap "rm -f '${lf}'" EXIT
}

# runtime_unlock_file - Release lock file
# Usage: runtime_unlock_file "/tmp/myapp.lock"
runtime_unlock_file() {
    rm -f "$1"
}

#===============================================================================
# SECTION 6: Retry & Timeout
#===============================================================================

# runtime_retry - Retry command with exponential backoff
# Usage: runtime_retry MAX_ATTEMPTS INITIAL_DELAY command args...
# Example: runtime_retry 3 5 curl -f http://example.com
runtime_retry() {
    local max="$1" delay="$2"
    shift 2
    local attempt=1
    while [[ ${attempt} -le ${max} ]]; do
        "$@" && return 0
        if [[ ${attempt} -lt ${max} ]]; then
            warn "Tentativa ${attempt}/${max} falhou. Retry em ${delay}s"
            sleep "${delay}"
            delay=$((delay * 2))
        fi
        (( attempt++ )) || true
    done
    return 1
}

# runtime_timeout - Run command with timeout (if available)
# Usage: runtime_timeout SECONDS command args...
runtime_timeout() {
    local seconds="$1"
    shift
    has_cmd timeout && timeout "${seconds}" "$@" || "$@"
}

#===============================================================================
# SECTION 7: Filesystem Utilities
#===============================================================================

# runtime_fs_available_gb - Get available space in GB
# Usage: avail=$(runtime_fs_available_gb /path)
runtime_fs_available_gb() {
    df -PB1 "$1" 2>/dev/null | awk 'NR==2{print int($4/1024/1024/1024)}'
}

# runtime_fs_used_percent - Get used space percentage
# Usage: used=$(runtime_fs_used_percent /path)
runtime_fs_used_percent() {
    df -P "$1" 2>/dev/null | awk 'NR==2{gsub(/%/,"",$5); print $5}'
}

# runtime_ensure_dir - Create directory if not exists
# Usage: runtime_ensure_dir "/path/to/dir"
runtime_ensure_dir() {
    [[ -d "$1" ]] || mkdir -p "$1"
}

# runtime_backup_file - Create timestamped backup of file
# Usage: runtime_backup_file "/path/to/file"
# Note: Always returns 0 (no-op if file doesn't exist)
runtime_backup_file() {
    [[ -f "$1" ]] && cp "$1" "$1.bak_$(date +%Y%m%d_%H%M%S)" || true
}

#===============================================================================
# SECTION 8: Time Utilities
#===============================================================================

# runtime_format_duration - Format seconds as human-readable duration
# Usage: echo "Elapsed: $(runtime_format_duration 3665)"  # "1h 1m 5s"
runtime_format_duration() {
    local s="$1"
    local h=$((s / 3600))
    local m=$(((s % 3600) / 60))
    local sec=$((s % 60))
    if [[ ${h} -gt 0 ]]; then
        echo "${h}h ${m}m ${sec}s"
    elif [[ ${m} -gt 0 ]]; then
        echo "${m}m ${sec}s"
    else
        echo "${sec}s"
    fi
}

# runtime_elapsed_since - Calculate seconds elapsed since timestamp
# Usage: start=$(date +%s); ...; elapsed=$(runtime_elapsed_since $start)
runtime_elapsed_since() {
    echo $(($(date +%s) - $1))
}

#===============================================================================
# SECTION 9: Command Execution with Logging
#===============================================================================

# runtime_exec_logged - Execute command with full logging and timing
# Usage: runtime_exec_logged "description" "command" [args...]
# Returns: command exit code, logs start/end with duration
# Output is captured and printed with prefix
runtime_exec_logged() {
    local __desc="$1" __cmd="$2"
    shift 2
    local __start __rc __out __duration

    __start=$(date +%s)
    log_cmd_start "${__cmd}" "${__desc}"

    # Track command execution in report
    report_track_step "Executing: ${__cmd}"

    set +e
    __out="$("${__cmd}" "$@" 2>&1)"
    __rc=$?
    set -e

    __duration="$(runtime_format_duration $(($(date +%s) - __start)))"

    # Report command completion
    if [[ ${__rc} -eq 0 ]]; then
        report_track_step_done 0 "Command completed in ${__duration}"
    else
        report_track_step_done ${__rc} "Command failed (exit ${__rc}) in ${__duration}"
    fi

    # Print output if not empty
    [[ -n "${__out}" ]] && printf "%s\n" "${__out}" | sed 's/^/  /'

    log_cmd_end "${__cmd}" "${__rc}" "${__duration}"
    return "${__rc}"
}

# runtime_exec_logged_to_file - Execute command with logging, output to file
# Usage: runtime_exec_logged_to_file "description" "log_file" "command" [args...]
# Returns: command exit code, logs start/end with duration
# Output is written to log_file instead of stdout
runtime_exec_logged_to_file() {
    local __desc="$1" __logfile="$2" __cmd="$3"
    shift 3
    local __start __rc __duration
    
    __start=$(date +%s)
    log_cmd_start "${__cmd}" "${__desc}"
    log_cmd "${__cmd}" "$*"
    
    set +e
    "${__cmd}" "$@" > "${__logfile}" 2>&1
    __rc=$?
    set -e
    
    __duration="$(runtime_format_duration $(($(date +%s) - __start)))"
    
    log_cmd_end "${__cmd}" "${__rc}" "${__duration}"
    
    if [[ "${__rc}" -eq 0 ]]; then
        log_success "${__desc} concluido (${__duration})"
    else
        log_error "${__desc} falhou (exit=${__rc}, ${__duration})"
    fi
    
    return "${__rc}"
}

# runtime_exec_silent - Execute command silently with timing, only log on error
# Usage: runtime_exec_silent "description" "command" [args...]
# Returns: command exit code
# Output is captured but only shown on failure
runtime_exec_silent() {
    local __desc="$1" __cmd="$2"
    shift 2
    local __start __rc __out __duration
    
    __start=$(date +%s)
    
    set +e
    __out="$("${__cmd}" "$@" 2>&1)"
    __rc=$?
    set -e
    
    __duration="$(runtime_format_duration $(($(date +%s) - __start)))"
    
    if [[ "${__rc}" -ne 0 ]]; then
        log_error "${__desc} falhou (exit=${__rc}, ${__duration})"
        [[ -n "${__out}" ]] && printf "%s\n" "${__out}" | sed 's/^/  /' >&2
    fi
    
    return "${__rc}"
}

#===============================================================================
# SECTION 10: Temporary File Utilities
#===============================================================================

# runtime_with_tempfile - Execute callback with auto-cleanup temp file
# Usage: runtime_with_tempfile callback_func [callback_args...]
# The callback receives the temp file path as first argument
# Example:
#   my_func() { local tmpfile="$1"; echo "test" > "$tmpfile"; cat "$tmpfile"; }
#   runtime_with_tempfile my_func
runtime_with_tempfile() {
    local __callback="$1"
    shift
    local __tmpfile
    __tmpfile=$(mktemp)
    
    # Set trap to cleanup on RETURN (when function returns)
    # shellcheck disable=SC2064  # Intentional: expand __tmpfile NOW
    trap "rm -f '${__tmpfile}'" RETURN
    
    # Call the callback with tmpfile as first arg, followed by other args
    "${__callback}" "${__tmpfile}" "$@"
}

# runtime_with_tempdir - Execute callback with auto-cleanup temp directory
# Usage: runtime_with_tempdir callback_func [callback_args...]
# The callback receives the temp dir path as first argument
runtime_with_tempdir() {
    local __callback="$1"
    shift
    local __tmpdir
    __tmpdir=$(mktemp -d)
    
    # shellcheck disable=SC2064  # Intentional: expand __tmpdir NOW
    trap "rm -rf '${__tmpdir}'" RETURN
    
    "${__callback}" "${__tmpdir}" "$@"
}

# runtime_mktemp - Create temp file and register for cleanup at EXIT
# Usage: tmpfile=$(runtime_mktemp)
# Note: File is automatically cleaned up when script exits
runtime_mktemp() {
    local __tmpfile
    __tmpfile=$(mktemp)
    # shellcheck disable=SC2064  # Intentional: expand __tmpfile NOW
    trap "rm -f '${__tmpfile}'" EXIT
    echo "${__tmpfile}"
}

# runtime_mktemp_dir - Create temp directory and register for cleanup at EXIT
# Usage: tmpdir=$(runtime_mktemp_dir)
# Note: Directory is automatically cleaned up when script exits
runtime_mktemp_dir() {
    local __tmpdir
    __tmpdir=$(mktemp -d)
    # shellcheck disable=SC2064  # Intentional: expand __tmpdir NOW
    trap "rm -rf '${__tmpdir}'" EXIT
    echo "${__tmpdir}"
}
