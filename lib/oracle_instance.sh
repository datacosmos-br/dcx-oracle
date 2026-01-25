#!/usr/bin/env bash
# shellcheck shell=bash
#===============================================================================
# Datacosmos - Oracle Instance Management Module
#
# Copyright (c) 2026 Datacosmos
# Licensed under the Apache License, Version 2.0
#===============================================================================
# File    : oracle_instance.sh
# Version : 1.1.0
# Date    : 2026-01-15
#===============================================================================
#
# DESCRIPTION:
#   Oracle instance lifecycle management. Provides functions for instance state
#   detection, startup, shutdown, and runtime queries. Integrates with
#   oracle_cluster.sh for RAC-aware operations.
#
# DEPENDS ON:
#   - oracle_core.sh (base Oracle functionality)
#   - oracle_cluster.sh (RAC detection and operations)
#   - runtime.sh (runtime_capture, runtime_retry, runtime_format_duration)
#   - report.sh (report_confirm for interactive confirmations)
#   - logging.sh (logging functions)
#
# PROVIDES:
#   PMON Management:
#     - oracle_instance_list_sids()    - List active Oracle instances
#     - oracle_instance_get_pmon()     - Get PMON process for SID
#     - oracle_instance_is_pmon_running() - Check if PMON is running
#
#   State Detection:
#     - oracle_instance_get_state()    - Get instance state (UP/DOWN/ZOMBIE)
#     - oracle_instance_ping()         - Ping instance via SYSDBA
#
#   Lifecycle:
#     - oracle_instance_startup()      - Start instance (various modes)
#     - oracle_instance_shutdown()     - Shutdown instance (various modes)
#     - oracle_instance_ensure_down()  - Ensure instance is stopped
#     - oracle_instance_ensure_up()    - Ensure instance is running
#
#   Runtime Queries:
#     - oracle_instance_get_number()   - Get instance number (RAC)
#     - oracle_instance_get_thread()   - Get thread number (RAC)
#     - oracle_instance_get_undo_ts()  - Get undo tablespace name
#
#===============================================================================

# Prevent double sourcing
[[ -n "${__ORACLE_INSTANCE_LOADED:-}" ]] && return 0
__ORACLE_INSTANCE_LOADED=1

# Resolve library directory
_ORACLE_INSTANCE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load oracle_core.sh (provides oracle_core_* functions)
# shellcheck source=/dev/null
[[ -z "${__ORACLE_CORE_LOADED:-}" ]] && source "${_ORACLE_INSTANCE_LIB_DIR}/oracle_core.sh"

# Load oracle_cluster.sh (provides oracle_cluster_* functions)
# shellcheck source=/dev/null
[[ -z "${__ORACLE_CLUSTER_LOADED:-}" ]] && source "${_ORACLE_INSTANCE_LIB_DIR}/oracle_cluster.sh"

# Load runtime.sh (provides runtime_capture, runtime_retry, runtime_format_duration)
# shellcheck source=/dev/null
[[ -z "${__RUNTIME_LOADED:-}" ]] && source "${_ORACLE_INSTANCE_LIB_DIR}/runtime.sh"

# Load report.sh (provides report_confirm for interactive confirmations)
# shellcheck source=/dev/null
[[ -z "${__REPORT_LOADED:-}" ]] && source "${_ORACLE_INSTANCE_LIB_DIR}/report.sh"

# Load oracle_sql.sh (provides oracle_sql_sysdba_query for runtime queries)
# shellcheck source=/dev/null
[[ -z "${__ORACLE_SQL_LOADED:-}" ]] && source "${_ORACLE_INSTANCE_LIB_DIR}/oracle_sql.sh"

#===============================================================================
# SECTION 1: PMON Process Management
#===============================================================================

# oracle_instance_list_sids - List all running Oracle instances (from PMON)
# Usage: oracle_instance_list_sids | while read sid; do ...; done
# Note: Uses ps -eo args= to get full process name with correct case
oracle_instance_list_sids() {
    log_debug "[CHECK] Listing active PMON processes" >&2
    ps -eo args= | awk '/^ora_pmon_[A-Za-z0-9_]+$/ {sub(/^ora_pmon_/,""); print}' | sort -u
}

# oracle_instance_get_pmon - Get PMON process SID matching ORACLE_SID
# Usage: pmon_sid=$(oracle_instance_get_pmon [sid])
# Note: Case-insensitive match but returns the actual SID from process name
oracle_instance_get_pmon() {
    local want_sid="${1:-${ORACLE_SID:-}}"
    [[ -z "${want_sid}" ]] && return 1
    
    local want_lc
    want_lc="$(printf "%s" "${want_sid}" | tr '[:upper:]' '[:lower:]')"
    ps -eo args= | awk -v W="${want_lc}" '/^ora_pmon_[A-Za-z0-9_]+$/ {
        s=$0; sub(/^ora_pmon_/,"",s);
        if(tolower(s)==W){print s; exit}
    }'
}

# oracle_instance_is_pmon_running - Check if PMON is running for SID
# Usage: oracle_instance_is_pmon_running [sid] && echo "Running"
oracle_instance_is_pmon_running() {
    local sid="${1:-${ORACLE_SID:-}}"
    [[ -n "$(oracle_instance_get_pmon "${sid}")" ]]
}

#===============================================================================
# SECTION 2: Instance State Detection
#===============================================================================

# oracle_instance_ping - Ping instance via SYSDBA connection
# Usage: oracle_instance_ping [sid]
# Returns: 0=UP, 10=NOT_STARTED, 11=OTHER_ERROR
# Note: All log output goes to stderr
# Uses: oracle_sql_sysdba_ping_sid from oracle_sql.sh
oracle_instance_ping() {
    local sid="${1:-${ORACLE_SID:-}}"

    rt_assert_nonempty "sid" "${sid}"

    log_debug "[CHECK] Pinging instance SID=${sid}" >&2

    oracle_sql_sysdba_ping_sid "${sid}"
}

# oracle_instance_get_state - Get instance state: DOWN, UP, or ZOMBIE
# Usage: state=$(oracle_instance_get_state [sid])
# Returns: "DOWN", "UP", or "ZOMBIE" on stdout
oracle_instance_get_state() {
    local sid="${1:-${ORACLE_SID:-}}"
    
    log_debug "[CHECK] Checking instance state for SID=${sid}" >&2

    local pmon_sid
    pmon_sid="$(oracle_instance_get_pmon "${sid}")"
    
    if [[ -z "${pmon_sid}" ]]; then
        log_debug "[STATE] DOWN - No PMON process found" >&2
        echo "DOWN"
        return 0
    fi

    log_debug "[STATE] PMON found: ${pmon_sid}" >&2
    
    if oracle_instance_ping "${pmon_sid}"; then
        log_debug "[STATE] UP - Instance responding" >&2
        echo "UP"
        return 0
    fi

    log_debug "[STATE] ZOMBIE - PMON exists but instance not responding" >&2
    echo "ZOMBIE"
}

#===============================================================================
# SECTION 3: Instance Lifecycle - Startup
#===============================================================================

# oracle_instance_startup - Start instance with various options
# Usage: oracle_instance_startup [options]
# Options:
#   --mode MODE       Startup mode: nomount, mount, open (default: open)
#   --pfile PATH      Use PFILE for startup
#   --sid SID         Instance SID (default: ORACLE_SID)
#   --db-name NAME    Database unique name (for srvctl)
#   --use-srvctl      Prefer srvctl if available
#   --retry N         Retry count (default: 1)
#   --retry-delay S   Retry delay in seconds (default: 5)
oracle_instance_startup() {
    local mode="open" pfile="" sid="${ORACLE_SID:-}"
    local db_name="${ORACLE_UNQNAME:-}" use_srvctl=0
    local retry=1 retry_delay=5
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --mode)       mode="$2"; shift 2 ;;
            --pfile)      pfile="$2"; shift 2 ;;
            --sid)        sid="$2"; shift 2 ;;
            --db-name)    db_name="$2"; shift 2 ;;
            --use-srvctl) use_srvctl=1; shift ;;
            --retry)      retry="$2"; shift 2 ;;
            --retry-delay) retry_delay="$2"; shift 2 ;;
            *) warn "Unknown option: $1"; shift ;;
        esac
    done

    rt_assert_nonempty "sid" "${sid}"
    rt_assert_enum "mode" "${mode}" "nomount" "mount" "open"

    # Track operation in report
    report_track_step "Starting Oracle instance ${sid} (mode: ${mode})"

    log "[STARTUP] Starting instance ${sid} (mode: ${mode})"

    # Skip if test mode
    if oracle_core_skip_oracle_cmds; then
        report_track_step_done 0 "Test mode - skipping actual startup"
        log "[TEST] Skipping startup in test mode"
        return 0
    fi

    # Use srvctl if available and requested
    if [[ ${use_srvctl} -eq 1 ]] && oracle_cluster_detect && [[ -n "${db_name}" ]]; then
        log "[STARTUP] Using srvctl for instance ${sid}"
        runtime_retry ${retry} ${retry_delay} oracle_cluster_start_instance "${db_name}" "${sid}" -o "${mode}"
        return $?
    fi

    log_cmd "sqlplus" "/ as sysdba"

    local sql_cmd
    if [[ -n "${pfile}" ]]; then
        rt_assert_file_exists "pfile" "${pfile}"
        sql_cmd="startup ${mode} pfile='${pfile}';"
        log_sql "STARTUP" "STARTUP ${mode^^} PFILE='${pfile}'"
    else
        sql_cmd="startup ${mode};"
        log_sql "STARTUP" "STARTUP ${mode^^}"
    fi

    local out rc start duration
    start=$(date +%s)

    _oracle_instance_startup_exec() {
        local _sid="$1" _sql_cmd="$2"
        oracle_sql_sysdba_exec_sid_capture out "${_sid}" "whenever sqlerror exit 1
${_sql_cmd}"
    }

    if runtime_retry ${retry} ${retry_delay} _oracle_instance_startup_exec "${sid}" "${sql_cmd}"; then
        rc=0
    else
        rc=1
    fi

    duration="$(runtime_format_duration $(($(date +%s) - start)))"

    printf "%s\n" "${out:-}" | sed 's/^/[sqlplus] /'

    if [[ "${rc}" -eq 0 ]]; then
        report_track_step_done 0 "Instance ${sid} started successfully in ${duration}"
        log "[OK] Instance ${sid} started (mode: ${mode}) (${duration})"
        return 0
    else
        report_track_step_done 1 "Startup failed for ${sid}"
        die "Startup failed for ${sid} (exit=${rc})"
    fi
}

# oracle_instance_startup_nomount - Start instance in NOMOUNT mode with PFILE
# Usage: oracle_instance_startup_nomount <pfile> [sid]
oracle_instance_startup_nomount() {
    local pfile="$1"
    local sid="${2:-${ORACLE_SID:-}}"
    
    oracle_instance_startup --mode nomount --pfile "${pfile}" --sid "${sid}"
}

#===============================================================================
# SECTION 4: Instance Lifecycle - Shutdown
#===============================================================================

# oracle_instance_shutdown - Shutdown instance with various options
# Usage: oracle_instance_shutdown [options]
# Options:
#   --mode MODE       Shutdown mode: immediate, abort, transactional, normal (default: immediate)
#   --sid SID         Instance SID (default: ORACLE_SID)
#   --db-name NAME    Database unique name (for srvctl)
#   --use-srvctl      Prefer srvctl if available
#   --timeout SECS    Timeout in seconds (default: 300)
oracle_instance_shutdown() {
    local mode="immediate" sid="${ORACLE_SID:-}"
    local db_name="${ORACLE_UNQNAME:-}" use_srvctl=0
    local timeout=300
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --mode)       mode="$2"; shift 2 ;;
            --sid)        sid="$2"; shift 2 ;;
            --db-name)    db_name="$2"; shift 2 ;;
            --use-srvctl) use_srvctl=1; shift ;;
            --timeout)    timeout="$2"; shift 2 ;;
            *) warn "Unknown option: $1"; shift ;;
        esac
    done

    rt_assert_nonempty "sid" "${sid}"
    rt_assert_enum "mode" "${mode}" "immediate" "abort" "transactional" "normal"

    # Track operation in report
    report_track_step "Shutting down Oracle instance ${sid} (mode: ${mode})"

    log "[SHUTDOWN] Shutting down instance ${sid} (mode: ${mode})"

    # Skip if test mode
    if oracle_core_skip_oracle_cmds; then
        report_track_step_done 0 "Test mode - skipping actual shutdown"
        log "[TEST] Skipping shutdown in test mode"
        return 0
    fi

    # Try srvctl if available and requested
    if [[ ${use_srvctl} -eq 1 ]] && oracle_cluster_detect && [[ -n "${db_name}" ]]; then
        log "[SHUTDOWN] Using srvctl for instance ${sid}"
        oracle_cluster_stop_instance "${db_name}" "${sid}" -o "${mode}"
        return $?
    fi

    log_cmd "sqlplus" "/ as sysdba"
    log_sql "SHUTDOWN" "SHUTDOWN ${mode^^}"

    local out rc start duration
    start=$(date +%s)

    oracle_sql_sysdba_exec_sid_timeout out "${sid}" "shutdown ${mode};" "${timeout}"
    rc=$?

    duration="$(runtime_format_duration $(($(date +%s) - start)))"

    printf "%s\n" "${out:-}" | sed 's/^/[sqlplus] /'

    if [[ "${rc}" -eq 0 ]]; then
        report_track_step_done 0 "Instance ${sid} shutdown successfully in ${duration}"
        log "[OK] Instance ${sid} shutdown (mode: ${mode}) (${duration})"
        return 0
    else
        report_track_step_done 1 "Shutdown failed for ${sid}"
        warn "Shutdown failed for ${sid} (exit=${rc})"
        return ${rc}
    fi
}

# oracle_instance_shutdown_abort - Shutdown instance with ABORT
# Usage: oracle_instance_shutdown_abort [sid]
oracle_instance_shutdown_abort() {
    local sid="${1:-${ORACLE_SID:-}}"
    oracle_instance_shutdown --mode abort --sid "${sid}"
}

#===============================================================================
# SECTION 5: Instance State Management
#===============================================================================

# oracle_instance_ensure_down - Ensure instance is down, stop if running
# Usage: oracle_instance_ensure_down [options]
# Options:
#   --sid SID            Instance SID
#   --allow-cleanup      Allow stopping running instance
#   --auto-yes           Skip confirmation prompts
#   --shutdown-mode MODE Shutdown mode (default: abort)
oracle_instance_ensure_down() {
    local sid="${ORACLE_SID:-}"
    local allow_cleanup=0 auto_yes=0
    local shutdown_mode="abort"
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --sid)            sid="$2"; shift 2 ;;
            --allow-cleanup)  allow_cleanup=1; shift ;;
            --auto-yes)       auto_yes=1; shift ;;
            --shutdown-mode)  shutdown_mode="$2"; shift 2 ;;
            *) warn "Unknown option: $1"; shift ;;
        esac
    done

    rt_assert_nonempty "sid" "${sid}"

    local state
    state="$(oracle_instance_get_state "${sid}")"
    log "[GUARD] Instance ${sid} state: ${state}"

    case "${state}" in
        DOWN)
            log "[GUARD] Instance is DOWN - ready to proceed"
            return 0
            ;;
        ZOMBIE)
            die "ZOMBIE detectado para ${sid}. Resolva manualmente (kill PMON ou cleanup SGA)."
            ;;
        UP)
            if [[ "${allow_cleanup}" != "1" ]]; then
                die "${sid} esta UP. Use --allow-cleanup para permitir parada."
            fi

            local pmon_sid
            pmon_sid="$(oracle_instance_get_pmon "${sid}")"
            log "[GUARD] Instance ${pmon_sid} is UP - requesting confirmation to stop"

            # Use REPORT_AUTO_YES from report.sh (set by auto_yes parameter)
            local orig_auto_yes="${REPORT_AUTO_YES:-0}"
            [[ "${auto_yes}" == "1" ]] && REPORT_AUTO_YES=1
            
            if ! report_confirm "Parar instancia ${pmon_sid}?" "STOP-${sid}"; then
                REPORT_AUTO_YES="${orig_auto_yes}"
                die "Confirmacao negada pelo usuario"
            fi
            REPORT_AUTO_YES="${orig_auto_yes}"

            log "[GUARD] Executing: shutdown ${shutdown_mode}"
            oracle_instance_shutdown --mode "${shutdown_mode}" --sid "${pmon_sid}"
            sleep 2

            # Verify it's down
            state="$(oracle_instance_get_state "${sid}")"
            if [[ "${state}" != "DOWN" ]]; then
                die "Falha ao parar ${sid}. Estado atual: ${state}"
            fi

            log "[GUARD] Instance ${sid} stopped successfully"
            return 0
            ;;
        *)
            die "Estado desconhecido: ${state}"
            ;;
    esac
}

# oracle_instance_ensure_up - Ensure instance is running
# Usage: oracle_instance_ensure_up [options]
# Options:
#   --sid SID       Instance SID
#   --mode MODE     Startup mode (default: open)
#   --pfile PATH    Use PFILE for startup
oracle_instance_ensure_up() {
    local sid="${ORACLE_SID:-}"
    local mode="open" pfile=""
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --sid)   sid="$2"; shift 2 ;;
            --mode)  mode="$2"; shift 2 ;;
            --pfile) pfile="$2"; shift 2 ;;
            *) warn "Unknown option: $1"; shift ;;
        esac
    done

    rt_assert_nonempty "sid" "${sid}"

    local state
    state="$(oracle_instance_get_state "${sid}")"
    log "[GUARD] Instance ${sid} state: ${state}"

    case "${state}" in
        UP)
            log "[GUARD] Instance is UP - ready to proceed"
            return 0
            ;;
        DOWN)
            log "[GUARD] Instance is DOWN - starting..."
            local startup_args=(--mode "${mode}" --sid "${sid}")
            [[ -n "${pfile}" ]] && startup_args+=(--pfile "${pfile}")
            oracle_instance_startup "${startup_args[@]}"
            return $?
            ;;
        ZOMBIE)
            die "ZOMBIE detectado para ${sid}. Resolva manualmente."
            ;;
        *)
            die "Estado desconhecido: ${state}"
            ;;
    esac
}

#===============================================================================
# SECTION 6: Runtime Queries
#===============================================================================

# oracle_instance_get_number - Get instance number for current SID (RAC)
# Usage: inst_num=$(oracle_instance_get_number [sid])
# Returns: Instance number (1, 2, 3, etc.) or 1 for single instance
oracle_instance_get_number() {
    local sid="${1:-${ORACLE_SID:-}}"
    
    # Check if RAC
    if oracle_cluster_is_rac; then
        # Try srvctl first
        if oracle_cluster_detect && [[ -n "${ORACLE_UNQNAME:-}" ]]; then
            local info
            info="$(oracle_cluster_get_instance_info "${ORACLE_UNQNAME}" "${sid}" 2>/dev/null || echo "")"
            if [[ -n "${info}" ]]; then
                local inst_num
                inst_num="$(echo "${info}" | grep -oP 'Instance number:\s*\K[0-9]+' || echo "")"
                if [[ -n "${inst_num}" ]]; then
                    echo "${inst_num}"
                    return 0
                fi
            fi
        fi
        
        # Query from database
        if ! oracle_core_skip_oracle_cmds && declare -f oracle_sql_sysdba_query >/dev/null 2>&1; then
            local inst_num
            inst_num="$(oracle_sql_sysdba_query "SELECT instance_number FROM v\$instance;" 2>/dev/null | tr -d '[:space:]' || echo "")"
            if [[ -n "${inst_num}" ]]; then
                echo "${inst_num}"
                return 0
            fi
        fi
    fi
    
    # Default for single instance
    echo "1"
}

# oracle_instance_get_thread - Get thread number for current SID (RAC)
# Usage: thread=$(oracle_instance_get_thread [sid])
# Returns: Thread number (usually same as instance number) or 1 for single instance
oracle_instance_get_thread() {
    local sid="${1:-${ORACLE_SID:-}}"
    
    # Check if RAC
    if oracle_cluster_is_rac; then
        # Query from database
        if ! oracle_core_skip_oracle_cmds && declare -f oracle_sql_sysdba_query >/dev/null 2>&1; then
            local thread
            thread="$(oracle_sql_sysdba_query "SELECT thread# FROM v\$instance;" 2>/dev/null | tr -d '[:space:]' || echo "")"
            if [[ -n "${thread}" ]]; then
                echo "${thread}"
                return 0
            fi
        fi
    fi
    
    # Default for single instance
    echo "1"
}

# oracle_instance_get_undo_ts - Get undo tablespace name for current instance
# Usage: undo_ts=$(oracle_instance_get_undo_ts)
# Returns: Undo tablespace name (e.g., "UNDOTBS1") or "UNDOTBS1" as fallback
oracle_instance_get_undo_ts() {
    if ! oracle_core_skip_oracle_cmds && declare -f oracle_sql_sysdba_query >/dev/null 2>&1; then
        local undo_ts
        undo_ts="$(oracle_sql_sysdba_query "SELECT value FROM v\$parameter WHERE name='undo_tablespace';" 2>/dev/null | tr -d '[:space:]' || echo "")"
        if [[ -n "${undo_ts}" && "${undo_ts}" != "NONE" ]]; then
            echo "${undo_ts}"
            return 0
        fi
    fi
    
    # Default fallback
    echo "UNDOTBS1"
}

#===============================================================================
# SECTION 8: Instance Information
#===============================================================================

# oracle_instance_print_info - Print instance information
# Usage: oracle_instance_print_info [sid]
oracle_instance_print_info() {
    local sid="${1:-${ORACLE_SID:-}}"
    
    echo
    echo "==================== Instance Information ===================="
    runtime_print_kv "ORACLE_SID" "${sid}"
    
    if [[ -n "${sid}" ]]; then
        local state pmon
        state="$(oracle_instance_get_state "${sid}" 2>/dev/null || echo "UNKNOWN")"
        pmon="$(oracle_instance_get_pmon "${sid}" 2>/dev/null || echo "")"
        
        runtime_print_kv "State" "${state}"
        runtime_print_kv "PMON" "${pmon:-<not running>}"
        
        if [[ "${state}" == "UP" ]]; then
            runtime_print_kv "Instance Number" "$(oracle_instance_get_number "${sid}" 2>/dev/null || echo "1")"
            runtime_print_kv "Thread" "$(oracle_instance_get_thread "${sid}" 2>/dev/null || echo "1")"
            runtime_print_kv "Undo Tablespace" "$(oracle_instance_get_undo_ts 2>/dev/null || echo "UNDOTBS1")"
        fi
    fi
    
    echo "=============================================================="
}