#!/usr/bin/env bash
# shellcheck shell=bash
#===============================================================================
# Datacosmos - Oracle Data Pump Migration Orchestrator v3.0
#
# Copyright (c) 2026 Datacosmos
# Licensed under the Apache License, Version 2.0
#===============================================================================
# File    : migrate_v2.sh
# Version : 3.0.0
# Date    : 2026-01-15
#===============================================================================
#
# DESCRIPTION:
#   Orchestrates Oracle Data Pump migrations using modular libraries.
#   Supports two modes:
#     - NETWORK_LINK: Direct import via database link
#     - OCI_DUMPFILES: Export to OCI Object Storage, then import
#
#   Uses the unified report.sh workflow system for:
#   - Phase/step tracking with automatic timing
#   - Interactive confirmations
#   - Dual output (console + markdown report)
#
# USAGE:
#   ./migrate_v2.sh [options]
#
# OPTIONS:
#   --no-scn              Disable flashback_scn
#   --metadata-only       Import metadata only (no data)
#   --use-dumpfiles       Use OCI Object Storage mode
#   --no-dumpfiles        Use network_link mode (default)
#   --max-concurrent N    Maximum concurrent processes
#   --parallel N          Parallel degree per process
#   --dry-run             Show what would be done
#   --auto-yes            Skip confirmations
#   --help                Show this help
#
# DEPENDS ON:
#   lib/core.sh (loads runtime), plus core-managed modules: config, queue, report
#   lib/oracle_sql.sh, lib/oracle_datapump.sh, lib/oracle_oci.sh
#
#===============================================================================

set -euo pipefail

#===============================================================================
# SECTION 1: Initialization (dcx Plugin)
#===============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="${SCRIPT_DIR}/.."
PLUGIN_LIB="${PLUGIN_DIR}/lib"

# Load dcx infrastructure if available (provides logging, runtime, config)
if [[ -n "${DC_LIB_DIR:-}" ]]; then
    # dcx is loaded - use its infrastructure
    :
else
    # Standalone mode - define minimal fallbacks
    log_info() { echo "[INFO] $*"; }
    log_error() { echo "[ERROR] $*" >&2; }
    log_warn() { echo "[WARN] $*" >&2; }
    log_debug() { [[ "${LOG_LEVEL:-1}" -ge 3 ]] && echo "[DEBUG] $*"; }
    die() { echo "[FATAL] $*" >&2; exit 1; }
fi

# Load plugin's Oracle libraries
source "${PLUGIN_LIB}/oracle.sh"

# Load additional Oracle modules for Data Pump
oracle_load_module datapump oci

# Load support libraries
source "${PLUGIN_LIB}/report.sh"
source "${PLUGIN_LIB}/queue.sh"

# Load Oracle libraries (oracle.sh uses core_require internally)
core_load oracle

# Load additional Oracle modules for Data Pump migration
core_load oracle_datapump oracle_oci

# Script version
VERSION="3.0.0"

#===============================================================================
# SECTION 2: Global Configuration
#===============================================================================

# Operation flags (set by arguments)
USE_FLASHBACK_SCN=1
METADATA_ONLY=0
USE_DUMPFILES=0
DRY_RUN=0
KEEP_DUMPFILES_AFTER_MIGRATION=0
REPORT_AUTO_YES="${AUTO_YES:-0}"

# Session variables (set during init)
SESSION_ID=""
LOG_DIR=""

#===============================================================================
# SECTION 3: Argument Parsing
#===============================================================================

mig_show_help() {
    cat << EOF
Oracle Data Pump Migration Orchestrator v${VERSION}

Usage: $(basename "$0") [options]

Modes:
  --use-dumpfiles       Use OCI Object Storage (expdp -> impdp)
  --no-dumpfiles        Use network_link direct import (default)

SCN Options:
  --no-scn              Disable flashback_scn (use current DB state)

Content Options:
  --metadata-only       Import metadata only (no data)

Parallelism:
  --max-concurrent N    Maximum concurrent processes (default: 4)
  --parallel N          Parallel degree per process (default: 5)

Dumpfile Cleanup:
  --keep-dumpfiles      Keep dumpfiles after migration
  --cleanup-dumpfiles   Remove dumpfiles after migration (default)

Other:
  --dry-run             Show what would be done without executing
  --auto-yes            Skip all confirmations
  --help, -h            Show this help message

Examples:
  $(basename "$0")                           # Default: network_link mode
  $(basename "$0") --use-dumpfiles           # OCI dumpfile mode
  $(basename "$0") --no-scn --metadata-only  # Metadata only, no SCN
  $(basename "$0") --max-concurrent 8        # 8 parallel processes

Configuration:
  Edit config/migration.conf for database credentials and settings.
EOF
    exit 0
}

mig_parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --no-scn)
                USE_FLASHBACK_SCN=0
                shift
                ;;
            --metadata-only)
                METADATA_ONLY=1
                shift
                ;;
            --use-dumpfiles)
                USE_DUMPFILES=1
                shift
                ;;
            --no-dumpfiles)
                USE_DUMPFILES=0
                shift
                ;;
            --max-concurrent)
                [[ $# -lt 2 ]] && die "Option $1 requires an argument"
                MAX_CONCURRENT_PROCESSES="${2?ERROR: --max-concurrent requires value}"
                shift 2
                ;;
            --parallel)
                [[ $# -lt 2 ]] && die "Option $1 requires an argument"
                DP_PARALLEL_DEGREE="${2?ERROR: --parallel requires value}"
                shift 2
                ;;
            --keep-dumpfiles)
                KEEP_DUMPFILES_AFTER_MIGRATION=1
                shift
                ;;
            --cleanup-dumpfiles)
                KEEP_DUMPFILES_AFTER_MIGRATION=0
                shift
                ;;
            --dry-run)
                DRY_RUN=1
                shift
                ;;
            --auto-yes)
                REPORT_AUTO_YES=1
                export REPORT_AUTO_YES
                shift
                ;;
            --help|-h)
                mig_show_help
                ;;
            *)
                die "Unknown parameter: $1. Use --help for options."
                ;;
        esac
    done
}

#===============================================================================
# SECTION 4: Session Management
#===============================================================================

mig_init_session() {
    SESSION_ID=$(date +%Y%m%d_%H%M%S)
    LOG_DIR="${SCRIPT_DIR}/../logs/${SESSION_ID}"

    runtime_ensure_dir "$LOG_DIR"
    runtime_ensure_dir "${LOG_DIR}/exports"
    runtime_ensure_dir "${LOG_DIR}/imports"

    export SESSION_ID LOG_DIR

    # Initialize report system
    report_init "Data Pump Migration" "${LOG_DIR}" "${SESSION_ID}"
}

#===============================================================================
# SECTION 5: Configuration Loading
#===============================================================================

mig_load_config() {
    log_debug "Loading migration configuration"
    
    # Load configuration hierarchically: defaults -> global -> local -> env
    config_load_with_profile "migration" "${SCRIPT_DIR}/../config" || {
        local config_file="${SCRIPT_DIR}/../config/migration.conf"
        [[ -f "$config_file" ]] && runtime_load_config "$config_file" || true
    }
    
    config_log_loaded || true
    
    # Validate required variables
    runtime_require_vars "DB_ADMIN_USER" "DB_ADMIN_PASSWORD" "DB_CONNECTION_STRING"

    # Build connection string
    CONNECTION="${DB_ADMIN_USER}/${DB_ADMIN_PASSWORD}@${DB_CONNECTION_STRING}"
    export CONNECTION

    # Record metadata
    report_meta "DB_CONNECTION" "${DB_CONNECTION_STRING}"
    report_meta "NETWORK_LINK" "${NETWORK_LINK:-N/A}"
    
    log_debug "Configuration loaded successfully"
}

#===============================================================================
# SECTION 6: Prerequisites Validation
#===============================================================================

mig_validate_prerequisites() {
    report_step "Validating prerequisites"

    # Discover Data Pump commands (from oracle_datapump.sh)
    dp_discover_commands
    report_item ok "Data Pump" "Commands discovered"

    # sqlplus discovered via oracle_core.sh (auto-init)
    report_item ok "SQL*Plus" "Discovered"

    # Test database connectivity
    if ! oracle_sql_test_connection "$CONNECTION" 10; then
        if ! report_confirm "Connection failed. Continue anyway?" "YES"; then
            report_item fail "Connectivity" "Failed and cancelled"
            report_step_done 1 "Connection failed"
            die "Migration cancelled"
        fi
        report_item warn "Connectivity" "Failed but continuing"
    else
        report_item ok "Connectivity" "Database connected"
    fi

    # Validate OCI config if dumpfile mode
    if [[ "$USE_DUMPFILES" -eq 1 ]]; then
        oracle_oci_validate_config
        report_item ok "OCI Config" "Validated"
    fi

    report_step_done 0
}

#===============================================================================
# SECTION 7: SQL Script Execution
#===============================================================================

mig_execute_pre_scripts() {
    if [[ "${EXECUTE_PRE_IMPORT_SCRIPTS:-0}" -eq 0 ]]; then
        log "Pre-import scripts disabled"
        return 0
    fi

    if [[ ${#PRE_IMPORT_SCRIPTS[@]} -eq 0 ]]; then
        log "No pre-import scripts configured"
        return 0
    fi

    report_step "Executing pre-import scripts"
    SQL_CONTINUE_ON_ERROR=1 oracle_sql_execute_batch "${PRE_IMPORT_SCRIPTS[@]}"
    report_item ok "Pre-scripts" "${#PRE_IMPORT_SCRIPTS[@]} executed"
    report_step_done 0
}

mig_execute_post_scripts() {
    if [[ "${EXECUTE_POST_IMPORT_SCRIPTS:-0}" -eq 0 ]]; then
        log "Post-import scripts disabled"
        return 0
    fi

    if [[ ${#POST_IMPORT_SCRIPTS[@]} -eq 0 ]]; then
        log "No post-import scripts configured"
        return 0
    fi

    report_step "Executing post-import scripts"
    SQL_CONTINUE_ON_ERROR=1 oracle_sql_execute_batch "${POST_IMPORT_SCRIPTS[@]}"
    report_item ok "Post-scripts" "${#POST_IMPORT_SCRIPTS[@]} executed"
    report_step_done 0
}

#===============================================================================
# SECTION 8: Network Link Migration
#===============================================================================

mig_run_networklink() {
    [[ $# -ge 1 ]] || die "mig_run_networklink requires at least SCN parameter"

    local scn="${1?ERROR: scn required}"
    shift
    local parfiles=("$@")

    [[ ${#parfiles[@]} -gt 0 ]] || die "No parfiles provided to mig_run_networklink"

    local total=${#parfiles[@]}
    local success=0 failed=0 current=0

    report_step "Network Link Migration"

    for parfile in "${parfiles[@]}"; do
        (( current++ )) || true
        local parfile_name
        parfile_name=$(basename "$parfile")
        local log_file="${LOG_DIR}/${parfile_name%.par}.log"

        log "[$current/$total] $parfile_name"

        set +e
        dp_execute_import_networklink \
            "$CONNECTION" \
            "$parfile" \
            "$NETWORK_LINK" \
            "$scn" \
            "$DIRECTORY" \
            "$log_file" \
            "$METADATA_ONLY" \
            "$USE_FLASHBACK_SCN"
        local exit_code=$?
        set -e

        if [[ $exit_code -eq 0 ]]; then
            (( success++ )) || true
            report_item ok "$parfile_name" "Import successful"
        else
            (( failed++ )) || true
            report_item fail "$parfile_name" "Import failed"
            warn "Continuing with next import..."
        fi
    done

    report_metric "total_parfiles" "$total"
    report_metric "imports_success" "$success" add
    report_metric "imports_failed" "$failed" add

    local exit_code
    exit_code=$([[ $failed -eq 0 ]] && echo 0 || echo 1)
    report_step_done "$exit_code"
    [[ $failed -eq 0 ]]
}

#===============================================================================
# SECTION 9: OCI Dumpfile Migration
#===============================================================================

mig_run_unified_queue() {
    [[ $# -ge 2 ]] || die "mig_run_unified_queue requires at least 2 parameters (oci_path, scn)"

    local oci_path="${1?ERROR: oci_path required}"
    local scn="${2?ERROR: scn required}"
    shift 2
    local parfiles=("$@")

    [[ ${#parfiles[@]} -gt 0 ]] || die "No parfiles provided to mig_run_unified_queue"

    local total=${#parfiles[@]}
    local max_concurrent="${MAX_CONCURRENT_PROCESSES:-4}"

    # Counters
    local exports_started=0 exports_completed=0 exports_success=0 exports_failed=0
    local imports_started=0 imports_completed=0 imports_success=0 imports_failed=0

    # Initialize queue
    queue_init "$max_concurrent"

    log "Total: $total | Concurrent: $max_concurrent"

    # Start initial exports
    while [[ $exports_started -lt $total ]] && queue_can_start; do
        local idx=$exports_started
        local parfile="${parfiles[$idx]}"
        local parfile_name
        parfile_name=$(basename "$parfile")
        local parfile_base="${parfile_name%.par}"
        local log_file="${LOG_DIR}/exports/${parfile_base}_export.log"
        local dumpfile_url
        dumpfile_url=$(oracle_oci_build_url "$oci_path" "$parfile_base")

        log "[$((exports_started + 1))/$total] EXPORT: $parfile_name"

        dp_execute_export_oci \
            "${SOURCE_DB_USER}/${SOURCE_DB_PASSWORD}@${SOURCE_DB_TNS}" \
            "$parfile" \
            "$dumpfile_url" \
            "$OCI_EXPORT_CREDENTIAL" \
            "$scn" \
            "$log_file" \
            "$METADATA_ONLY" \
            "$USE_FLASHBACK_SCN" &

        queue_register_job "$!" "export" "$idx" "$parfile_name"
        (( exports_started++ )) || true
    done

    # Main loop
    while [[ $imports_completed -lt $total ]]; do
        local completed_pid
        completed_pid=$(queue_wait_any)
        [[ -z "$completed_pid" ]] && continue

        local job_info
        job_info=$(queue_get_job_info "$completed_pid")
        local job_type idx job_name
        read -r job_type idx job_name <<< "$job_info"

        wait "$completed_pid" 2>/dev/null
        local exit_code=$?

        queue_unregister_job "$completed_pid"

        local parfile="${parfiles[$idx]}"
        local parfile_name
        parfile_name=$(basename "$parfile")
        local parfile_base="${parfile_name%.par}"

        if [[ "$job_type" == "export" ]]; then
            (( exports_completed++ )) || true
            queue_mark_ready "$LOG_DIR" "$parfile_base" "$exit_code"

            if [[ $exit_code -eq 0 ]]; then
                (( exports_success++ )) || true
                report_item ok "EXPORT: $job_name" "[$exports_completed/$total]"
            else
                (( exports_failed++ )) || true
                report_item fail "EXPORT: $job_name" "[$exports_completed/$total]"
            fi

            # Start import
            local import_log="${LOG_DIR}/imports/${parfile_base}_import.log"
            local dumpfile_url
            dumpfile_url=$(oracle_oci_build_url "$oci_path" "$parfile_base")

            (( imports_started++ )) || true
            log "[$imports_started/$total] IMPORT: $job_name"

            dp_execute_import_oci \
                "$CONNECTION" \
                "$parfile" \
                "$dumpfile_url" \
                "$OCI_IMPORT_CREDENTIAL" \
                "$import_log" \
                "$METADATA_ONLY" &

            queue_register_job "$!" "import" "$idx" "$job_name"

            # Start next export
            if [[ $exports_started -lt $total ]] && queue_can_start; then
                local next_idx=$exports_started
                local next_parfile="${parfiles[$next_idx]}"
                local next_name
                next_name=$(basename "$next_parfile")
                local next_base="${next_name%.par}"
                local next_log="${LOG_DIR}/exports/${next_base}_export.log"
                local next_dumpfile
                next_dumpfile=$(oracle_oci_build_url "$oci_path" "$next_base")

                log "[$((exports_started + 1))/$total] EXPORT: $next_name"

                dp_execute_export_oci \
                    "${SOURCE_DB_USER}/${SOURCE_DB_PASSWORD}@${SOURCE_DB_TNS}" \
                    "$next_parfile" \
                    "$next_dumpfile" \
                    "$OCI_EXPORT_CREDENTIAL" \
                    "$scn" \
                    "$next_log" \
                    "$METADATA_ONLY" \
                    "$USE_FLASHBACK_SCN" &

                queue_register_job "$!" "export" "$next_idx" "$next_name"
                (( exports_started++ )) || true
            fi

        elif [[ "$job_type" == "import" ]]; then
            (( imports_completed++ )) || true

            if [[ $exit_code -eq 0 ]]; then
                (( imports_success++ )) || true
                report_item ok "IMPORT: $job_name" "[$imports_completed/$total]"
            else
                (( imports_failed++ )) || true
                report_item fail "IMPORT: $job_name" "[$imports_completed/$total]"
            fi

            queue_print_status "Migration" "$imports_completed" "$total"
        fi
    done

    # Record metrics
    report_metric "exports_success" "$exports_success"
    report_metric "exports_failed" "$exports_failed"
    report_metric "imports_success" "$imports_success" add
    report_metric "imports_failed" "$imports_failed" add
    report_metric "total_parfiles" "$total"

    [[ $exports_failed -eq 0 ]] && [[ $imports_failed -eq 0 ]]
}

mig_run_dumpfile() {
    [[ $# -ge 1 ]] || die "mig_run_dumpfile requires at least SCN parameter"

    local scn="${1?ERROR: scn required}"
    shift
    local parfiles=("$@")

    [[ ${#parfiles[@]} -gt 0 ]] || die "No parfiles provided to mig_run_dumpfile"

    local oci_path
    oci_path=$(oracle_oci_generate_path)

    report_step "OCI Dumpfile Migration"

    oracle_oci_print_config
    report_vars "Migration Settings" \
        "OCI_PATH=${oci_path}" \
        "CONCURRENT=${MAX_CONCURRENT_PROCESSES:-4}" \
        "PARALLEL=${DP_PARALLEL_DEGREE:-5}" \
        "TOTAL_PARFILES=${#parfiles[@]}"

    set +e
    mig_run_unified_queue "$oci_path" "$scn" "${parfiles[@]}"
    local exit_code=$?
    set -e

    if [[ $exit_code -eq 0 ]] && [[ "${KEEP_DUMPFILES_AFTER_MIGRATION:-0}" -eq 0 ]]; then
        log "Dumpfiles at: ${oci_path}"
    fi

    report_step_done $exit_code
    return $exit_code
}

#===============================================================================
# SECTION 10: Main Entry Point
#===============================================================================

mig_print_banner() {
    cat << 'EOF'
╔═══════════════════════════════════════════════════════════════════════════════╗
║                    ORACLE DATA PUMP MIGRATION ORCHESTRATOR                     ║
║                              Datacosmos v3.0.0                                 ║
╚═══════════════════════════════════════════════════════════════════════════════╝
EOF
}

mig_print_configuration() {
    local mode_desc
    [[ "$USE_DUMPFILES" -eq 1 ]] && mode_desc="OCI Dumpfiles" || mode_desc="Network Link"

    local scn_desc
    [[ "$USE_FLASHBACK_SCN" -eq 1 ]] && scn_desc="ENABLED" || scn_desc="DISABLED"

    local content_desc
    [[ "$METADATA_ONLY" -eq 1 ]] && content_desc="METADATA_ONLY" || content_desc="FULL"

    report_meta "MODE" "${mode_desc}"
    report_meta "FLASHBACK_SCN" "${scn_desc}"
    report_meta "CONTENT" "${content_desc}"
    report_meta "CONCURRENT" "${MAX_CONCURRENT_PROCESSES:-4}"
    report_meta "PARALLEL" "${DP_PARALLEL_DEGREE:-5}"

    report_vars "Session" \
        "SESSION_ID=${SESSION_ID}" \
        "LOG_DIR=${LOG_DIR}"

    report_vars "Database" \
        "TARGET=${DB_CONNECTION_STRING}" \
        "NETWORK_LINK=${NETWORK_LINK:-N/A}"

    report_vars "Operation" \
        "MODE=${mode_desc}" \
        "FLASHBACK_SCN=${scn_desc}" \
        "CONTENT=${content_desc}" \
        "CONCURRENT=${MAX_CONCURRENT_PROCESSES:-4}" \
        "PARALLEL=${DP_PARALLEL_DEGREE:-5}"
}

mig_main() {
    clear
    mig_print_banner

    # Initialize
    mig_init_session
    mig_load_config

    # Phase 1: Configuration
    report_phase "Configuration & Validation"
    mig_print_configuration

    # Validate
    mig_validate_prerequisites

    # Get SCN
    local scn="N/A"
    if [[ "$USE_FLASHBACK_SCN" -eq 1 ]]; then
        report_step "Obtaining SCN"
        if scn=$(dp_get_scn "$CONNECTION" "$NETWORK_LINK" "${FLASHBACK_SCN:-}"); then
            scn=$(echo "$scn" | tr -d '[:space:]' | grep -E '^[0-9]+$')
            [[ -n "$scn" ]] || die "Invalid SCN received"
            report_item ok "SCN" "${scn}"
            report_meta "SCN" "${scn}"
        else
            report_item fail "SCN" "Could not obtain"
            report_step_done 1
            die "Could not obtain SCN"
        fi
        report_step_done 0
    else
        log "Flashback SCN disabled"
    fi

    # Get parfiles
    report_step "Listing parfiles"
    local parfiles_dir="${PARFILES_DIR:-${SCRIPT_DIR}/../parfiles}"
    mapfile -t parfiles < <(dp_list_parfiles "$parfiles_dir")

    [[ ${#parfiles[@]} -eq 0 ]] && die "No parfiles found in $parfiles_dir"

    for pf in "${parfiles[@]}"; do
        report_item ok "$(basename "$pf")" "Queued"
    done
    report_step_done 0

    # Dry run check
    if [[ "$DRY_RUN" -eq 1 ]]; then
        report_metric "status" "DRY_RUN"
        report_finalize
        log "DRY RUN: Would migrate ${#parfiles[@]} parfiles"
        exit 0
    fi

    # Countdown
    log "Starting in 3 seconds..."
    sleep 3

    # Phase 2: Pre-scripts
    report_phase "Pre-Migration"
    mig_execute_pre_scripts

    # Phase 3: Migration
    report_phase "Data Migration"

    local exit_code=0
    if [[ "$USE_DUMPFILES" -eq 1 ]]; then
        mig_run_dumpfile "$scn" "${parfiles[@]}" || exit_code=$?
    else
        mig_run_networklink "$scn" "${parfiles[@]}" || exit_code=$?
    fi

    # Phase 4: Post-scripts
    report_phase "Post-Migration"
    mig_execute_post_scripts

    # Cleanup
    dp_cleanup_temp_parfiles "$parfiles_dir"

    # Final status
    if [[ $exit_code -eq 0 ]]; then
        report_metric "status" "SUCCESS"
        log "Migration completed successfully"
    else
        report_metric "status" "COMPLETED_WITH_ERRORS"
        warn "Migration completed with errors"
    fi

    # Generate and display report
    report_finalize

    exit $exit_code
}

#===============================================================================
# SECTION 11: Signal Handling & Entry
#===============================================================================

mig_cleanup_on_exit() {
    warn "Interrupted"
    report_metric "status" "INTERRUPTED"
    report_finalize 2>/dev/null || true
    local parfiles_dir="${PARFILES_DIR:-${SCRIPT_DIR}/../parfiles}"
    dp_cleanup_temp_parfiles "$parfiles_dir" 2>/dev/null || true
    exit 130
}

trap mig_cleanup_on_exit INT TERM

# Parse arguments and run
mig_parse_arguments "$@"
mig_main
