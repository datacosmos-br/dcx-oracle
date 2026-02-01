#!/usr/bin/env bash
# shellcheck shell=bash
#===============================================================================
# Datacosmos - Oracle 19c RMAN Restore (DISK -> FS/ASM)
#
# Copyright (c) 2026 Datacosmos
# Licensed under the Apache License, Version 2.0
#===============================================================================
# File    : restore.sh
# Version : 8.0.1
# Date    : 2026-01-23
#===============================================================================
#
# DESCRIPTION:
#   Automated RMAN restore/clone from disk backup to filesystem or ASM.
#   Orchestrates a 12-step process: validation, backup discovery, guards,
#   memory sizing, bootstrap, SPFILE/CONTROLFILE restore, PFILE sanitization,
#   catalog, preview, validate, space check, and full restore.
#
#   Uses the unified report.sh workflow system for:
#   - Phase/step tracking with automatic timing
#   - Interactive confirmations
#   - Dual output (console + markdown report)
#
# USAGE:
#   ORACLE_HOME=/u01/app/oracle/product/19c TARGET_SID=RESTORE ./restore.sh
#
# ENV VARS:
#   ORACLE_HOME    - Required. Path to Oracle home
#   TARGET_SID     - Target database SID (default: ORACLE_SID or RES)
#   BACKUP_ROOT    - Backup root directory (default: /backup-prod/rman)
#   DEST_BASE      - Destination base path (default: /restore)
#   DEST_TYPE      - FS or ASM (default: FS)
#   DRY_RUN        - 0=full (skips validated steps), 1=stop after validate (saves state), 2=stop after config
#   AUTO_YES       - 0=interactive, 1=skip confirmations (maps to REPORT_AUTO_YES)
#   ALLOW_CLEANUP  - 0=refuse, 1=allow stopping running instance
#   SGA_TARGET     - Override SGA (e.g., 12G)
#   PGA_TARGET     - Override PGA (e.g., 4G)
#   DBID           - Force specific DBID
#   LOG_LEVEL      - 0=quiet, 1=normal, 2=verbose, 3=debug (default: 2)
#
#===============================================================================

set -Eeuo pipefail

#===============================================================================
# LIBRARY LOADING (dcx Plugin)
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

# Load additional Oracle modules for RMAN restore
oracle_load_module rman

# Load support libraries
source "${PLUGIN_LIB}/report.sh"
source "${PLUGIN_LIB}/session.sh"

#===============================================================================
# CONFIGURATION LOADING
#===============================================================================

# Load plugin defaults if available
if [[ -f "${PLUGIN_DIR}/etc/defaults.yaml" ]] && command -v yq &>/dev/null; then
    : # Config loaded via dcx yq
fi

# Load hierarchical config if available
if type -t config_load_hierarchical &>/dev/null; then
    config_load_hierarchical "restore" "/etc/restore.conf" "${PLUGIN_DIR}/etc/restore.conf" || true
fi

# Set defaults for restore-specific variables (fallback function)
runtime_set_default() {
    local var="$1" default="$2"
    if [[ -z "${!var:-}" ]]; then
        export "$var"="$default"
    fi
}
runtime_set_default "AUTO_YES" "0"
runtime_set_default "DRY_RUN" "0"
runtime_set_default "ALLOW_CLEANUP" "0"
runtime_set_default "SKIP_ORACLE_CMDS" "0"  # Set to 1 for testing without Oracle
runtime_set_default "ALLOW_DROP_DATABASE" "0"
runtime_set_default "DEST_TYPE" "FS"
runtime_set_default "DEST_BASE" "/restore"
runtime_set_default "BACKUP_ROOT" "/backup-prod/rman"
runtime_set_default "DATA_DG" "+DATA"
runtime_set_default "FRA_DG" "+RECO"
runtime_set_default "SANITIZE_DROP_HIDDEN" "0"
runtime_set_default "CONTINUE_MODE" "0"   # 0=normal, 1=resume from current state
runtime_set_default "RESUME_FROM" ""       # catalog, restore, recover (skip to specific phase)

# Point-in-Time Recovery (PITR) parameters
runtime_set_default "UNTIL_TIME" ""        # e.g., "2026-01-16 14:30:00" (format: YYYY-MM-DD HH24:MI:SS)
runtime_set_default "UNTIL_SCN" ""         # e.g., "1234567890" (System Change Number)

# Map AUTO_YES to REPORT_AUTO_YES for unified confirmation handling
REPORT_AUTO_YES="${AUTO_YES}"
export REPORT_AUTO_YES

# SID handling
ORACLE_SID_ORIG="${ORACLE_SID:-}"
runtime_set_default "TARGET_SID" "${ORACLE_SID_ORIG:-RES}"
export ORACLE_SID="${TARGET_SID}"
runtime_set_default "TARGET_DB_UNIQUE_NAME" "${ORACLE_SID}"

# Log loaded configuration
config_log_loaded || true

# Validate required
runtime_require_vars "ORACLE_HOME"
export PATH="${ORACLE_HOME}/bin:${PATH}"
umask 022

#===============================================================================
# SESSION & LOGGING INITIALIZATION
#===============================================================================

# Initialize session and logging with report system
session_init_with_report "restore" "RMAN Restore - ${ORACLE_SID}" \
    "/tmp/restore_${ORACLE_SID}_logs/%s" \
    "ORACLE_SID=${ORACLE_SID}" \
    "TARGET_SID=${TARGET_SID}" \
    "DEST_TYPE=${DEST_TYPE}" \
    "DEST_BASE=${DEST_BASE}" \
    "BACKUP_ROOT=${BACKUP_ROOT}"

# Log configuration summary
log "Configuration loaded for restore operation"
log_debug "ORACLE_SID=${ORACLE_SID}, TARGET_SID=${TARGET_SID}, DEST_TYPE=${DEST_TYPE}"

# Lock file to prevent concurrent execution
LOCK_FILE="/tmp/restore_${ORACLE_SID}.lock"
log_lock "ACQUIRE" "${LOCK_FILE}"
runtime_lock_file "${LOCK_FILE}"
log_debug "Lock acquired: PID=$$"

#===============================================================================
# FILE PATHS
#===============================================================================
BOOT="/tmp/init_${ORACLE_SID}_bootstrap.ora"
PFILE_RAW="/tmp/pfile_raw_${ORACLE_SID}.ora"
PFILE_CLEAN="/tmp/init_${ORACLE_SID}_clean.ora"
DISC="${LOGDIR}/discovery_${ORACLE_SID}.txt"

RMAN_BOOT="${LOGDIR}/01_bootstrap.rcv"     # SPFILE + CONTROLFILE
RMAN_XCHK="${LOGDIR}/02a_crosscheck.rcv"   # Crosscheck & cleanup expired
RMAN_CAT="${LOGDIR}/02b_catalog.rcv"       # Catalog backup pieces
RMAN_PRE="${LOGDIR}/03_preview.rcv"
RMAN_VAL="${LOGDIR}/04_validate.rcv"
RMAN_RES="${LOGDIR}/05_restore.rcv"
RMAN_REC="${LOGDIR}/06_recover.rcv"
POST_SQL="${LOGDIR}/07_post_restore.sql"
RENAME_SQL="${LOGDIR}/08_rename_files.sql"

# Globals set by oracle functions
CONTROL_DIR="" DATA_DIR="" FRA_DIR="" ADMIN_DIR=""
AUTO="" ORIG_DB_NAME=""
SGA="" PGA=""

#===============================================================================
# VALIDATION
#===============================================================================
validate_all() {
    log_debug "AUTO_YES=${AUTO_YES} DRY_RUN=${DRY_RUN} ALLOW_CLEANUP=${ALLOW_CLEANUP}"
    log_debug "DEST_TYPE=${DEST_TYPE} DEST_BASE=${DEST_BASE}"

    rt_assert_bool01 "AUTO_YES" "${AUTO_YES}"
    rt_assert_enum "DRY_RUN" "${DRY_RUN}" 0 1 2
    rt_assert_bool01 "ALLOW_CLEANUP" "${ALLOW_CLEANUP}"
    rt_assert_enum "DEST_TYPE" "${DEST_TYPE}" FS ASM
    rt_assert_sid_token "TARGET_SID" "${TARGET_SID}"
    rt_assert_abs_path "DEST_BASE" "${DEST_BASE}"
    rt_assert_abs_path "BACKUP_ROOT" "${BACKUP_ROOT}"

    oracle_core_validate_home
    oracle_core_check_oratab_mismatch "${ORACLE_SID}" || true

    if [[ -n "${SGA_TARGET:-}" ]]; then oracle_config_validate_mem_value "${SGA_TARGET}"; fi
    if [[ -n "${PGA_TARGET:-}" ]]; then oracle_config_validate_mem_value "${PGA_TARGET}"; fi
}

#===============================================================================
# GUARDS
#===============================================================================
ensure_guards() {
    # List active instances (informational)
    log_info "Active Oracle instances:"
    oracle_instance_list_sids 2>/dev/null | sed 's/^/  - /' || log_info "  (none)"

    # Main guard: ensure target instance is DOWN (or stop it if ALLOW_CLEANUP=1)
    local ensure_args=()
    [[ "${ALLOW_CLEANUP}" == "1" ]] && ensure_args+=(--allow-cleanup)
    [[ "${AUTO_YES}" == "1" ]] && ensure_args+=(--auto-yes)
    oracle_instance_ensure_down "${ensure_args[@]}"
    report_item ok "Instance ${ORACLE_SID}" "DOWN - ready for restore"

    # Create destination directories
    runtime_ensure_dir "${CONTROL_DIR}"
    runtime_ensure_dir "${ADMIN_DIR}"
    [[ "${DEST_TYPE}" == "FS" ]] && {
        runtime_ensure_dir "${DATA_DIR}"
        runtime_ensure_dir "${FRA_DIR}"
    }
    report_item ok "Directories" "CONTROL=${CONTROL_DIR}, ADMIN=${ADMIN_DIR}"

    # Check for existing controlfiles (would conflict with restore)
    if ls -1 "${CONTROL_DIR}"/control*.ctl >/dev/null 2>&1; then
        warn "Controlfiles existentes em ${CONTROL_DIR}"
        [[ "${ALLOW_CLEANUP}" == "1" ]] || die "Use ALLOW_CLEANUP=1 para limpar"

        if report_confirm "Limpar destino ${CONTROL_DIR}?" "WIPE-${ORACLE_SID}"; then
            rm -f "${CONTROL_DIR}"/control*.ctl "${CONTROL_DIR}"/*.dbf "${CONTROL_DIR}"/*.log 2>/dev/null || true
            report_item ok "Cleanup" "Destination cleaned"
        else
            die "Cleanup negado pelo usuario"
        fi
    fi
}

#===============================================================================
# RMAN CMDFILE WRITERS
#===============================================================================
write_rman_spfile() {
    log_debug "Writing RMAN cmdfile: ${RMAN_BOOT}"
    # Restore both SPFILE and CONTROLFILE in a single RMAN execution
    # Controlfile is restored to CONTROL_DIR which matches bootstrap PFILE's control_files
    oracle_rman_write_cmdfile_run "${RMAN_BOOT}" "${DBID}" "" <<EOF
  set controlfile autobackup format for device type disk to '${AUTO}/%F';
  restore spfile from autobackup;
  restore controlfile to '${CONTROL_DIR}/control01.ctl' from autobackup;
EOF
    log_debug "RMAN cmdfile ready: ${RMAN_BOOT}"
}

write_rman_crosscheck() {
    # Crosscheck and remove expired backups BEFORE catalog
    # This speeds up catalog by cleaning stale entries first
    log_debug "Writing RMAN cmdfile: ${RMAN_XCHK}"
    oracle_rman_write_cmdfile_run "${RMAN_XCHK}" "" "" <<EOF
  crosscheck backup;
  crosscheck copy;
  delete noprompt expired backup;
  delete noprompt expired copy;
EOF
    log_debug "RMAN cmdfile ready: ${RMAN_XCHK}"
}

write_rman_catalog() {
    # Note: No DBID - database is MOUNTED, RMAN reads DBID from controlfile
    # Catalog EVERYTHING from BACKUP_ROOT - RMAN will automatically identify:
    # - Backup sets (backup pieces)
    # - Datafile copies
    # - Archivelog backups
    # The backup type will be detected AFTER cataloging by querying V$ views
    log_debug "Writing RMAN cmdfile: ${RMAN_CAT}"

    # Note: report schema removed - causes RMAN-06139 warning with backup controlfile
    local post="list backup summary;
list archivelog all;
list incarnation;"

    oracle_rman_write_cmdfile_run "${RMAN_CAT}" "" "${post}" <<EOF
  # Catalog all backup files from root directory
  # RMAN will automatically identify backup sets, datafile copies, and archivelogs
  catalog start with '${BACKUP_ROOT}/' noprompt;
EOF
    log_debug "RMAN cmdfile ready: ${RMAN_CAT}"
}

write_rman_preview() {
    log_debug "Writing RMAN cmdfile: ${RMAN_PRE}"
    oracle_rman_write_cmdfile_run "${RMAN_PRE}" "" "" <<EOF
$(oracle_rman_build_newname_lines)
  restore database preview summary;
EOF
    log_debug "RMAN cmdfile ready: ${RMAN_PRE}"
}

write_rman_validate() {
    log_debug "Writing RMAN cmdfile: ${RMAN_VAL}"
    oracle_rman_write_cmdfile_run "${RMAN_VAL}" "" "" <<EOF
$(oracle_rman_build_newname_lines)
  restore database validate;
EOF
    log_debug "RMAN cmdfile ready: ${RMAN_VAL}"
}

write_rman_restore() {
    log_debug "Writing RMAN cmdfile: ${RMAN_RES}"
    log_debug "BACKUP_TYPE=${BACKUP_TYPE:-backupset}"

    # Order: SET UNTIL (if PITR) → SET NEWNAME → RESTORE/SWITCH → SWITCH DATAFILE
    # Note: Tempfiles are NOT restored by RMAN - they are recreated after OPEN RESETLOGS

    # Build UNTIL clause for PITR
    local until_clause=""
    if [[ -n "${UNTIL_TIME:-}" ]]; then
        until_clause="set until time \"to_date('${UNTIL_TIME}','YYYY-MM-DD HH24:MI:SS')\";"
        log_info "PITR: Restore UNTIL TIME '${UNTIL_TIME}'"
    elif [[ -n "${UNTIL_SCN:-}" ]]; then
        until_clause="set until scn ${UNTIL_SCN};"
        log_info "PITR: Restore UNTIL SCN ${UNTIL_SCN}"
    fi

    # Generate restore commands - always use SET NEWNAME + RESTORE + SWITCH
    # RMAN will automatically choose best source (image copy or backupset)
    local restore_cmds=""
    log_info "Using BACKUP_TYPE=${BACKUP_TYPE:-backupset} - RMAN selects best source"
    restore_cmds="$(oracle_rman_build_newname_lines)"$'\n'
    restore_cmds+="  restore database;"$'\n'
    restore_cmds+="  switch datafile all;"

    oracle_rman_write_cmdfile_run "${RMAN_RES}" "" "" <<EOF
${until_clause}
${restore_cmds}
EOF
    log_debug "RMAN cmdfile ready: ${RMAN_RES}"
}

write_rman_recover() {
    log_debug "Writing RMAN cmdfile: ${RMAN_REC}"
    # Build recover command with UNTIL if PITR requested
    local recover_cmd="recover database"
    if [[ -n "${UNTIL_TIME:-}" ]]; then
        recover_cmd="recover database until time \"to_date('${UNTIL_TIME}','YYYY-MM-DD HH24:MI:SS')\""
        log_info "PITR: Recover UNTIL TIME '${UNTIL_TIME}'"
    elif [[ -n "${UNTIL_SCN:-}" ]]; then
        recover_cmd="recover database until scn ${UNTIL_SCN}"
        log_info "PITR: Recover UNTIL SCN ${UNTIL_SCN}"
    fi

    oracle_rman_write_cmdfile_run "${RMAN_REC}" "" "" <<EOF
  ${recover_cmd};
EOF
    log_debug "RMAN cmdfile ready: ${RMAN_REC}"
}

sanitize_pfile() {
    local args=(
        "${PFILE_RAW}"
        "${PFILE_CLEAN}"
        "${ORIG_DB_NAME}"
        "${TARGET_DB_UNIQUE_NAME}"
        "${SGA}"
        "${PGA}"
        "${DEST_TYPE}"
        "${DEST_BASE}"
        "${ADMIN_DIR}"
        "${CONTROL_DIR}"
        "${DATA_DIR}"
        "${FRA_DIR}"
    )

    # Add optional flags
    [[ "${SANITIZE_DROP_HIDDEN}" == "1" ]] && args+=(--drop-hidden)

    oracle_config_pfile_sanitize "${args[@]}"
}

#===============================================================================
# PHASE A: Validation & Discovery (safe, read-only)
#===============================================================================
phase_validate_and_discover() {
    report_phase "Validation & Discovery"

    log "==[START] Session: ${SESSION_ID}"
    log "==[START] Log: ${MAIN_LOG}"

    # Required commands - skip Oracle cmds in test mode
    require_cmds awk sed find df free
    if [[ "${SKIP_ORACLE_CMDS:-0}" != "1" ]]; then
        require_cmds sqlplus rman
    else
        log_debug "SKIP_ORACLE_CMDS=1: Skipping sqlplus/rman check (test mode)"
    fi

    # Step 1: Validate
    report_step "Validating parameters"
    validate_all
    oracle_config_resolve_paths "${DEST_TYPE}" "${DEST_BASE}" "${TARGET_DB_UNIQUE_NAME}" "${DATA_DG}" "${FRA_DG}"
    oracle_rman_auto_channels
    report_step_done 0

    # Step 2: Backup discovery
    report_step "Discovering backup"
    oracle_rman_backup_discover "${BACKUP_ROOT}" || die "Backup nao encontrado: ${BACKUP_ROOT}"
    report_item ok "Backup" "Found: ${BACKUP_ROOT}"

    if [[ -z "${DBID:-}" ]]; then
        DBID="$(oracle_rman_detect_dbid "${AUTO}")" || die "DBID nao detectado"
    fi
    report_item ok "DBID" "${DBID}"
    report_meta "DBID" "${DBID}"
    report_step_done 0

    # Salvar DBID no estado para --resume-from
    _rman_state_set "DBID" "${DBID}"

    runtime_write_host_report "${LOGDIR}/host.txt" "oracle_config_host_report_callback"

    # Display configuration
    report_vars "Configuration" \
        "DRY_RUN=${DRY_RUN}" \
        "TARGET_SID=${TARGET_SID}" \
        "DBID=${DBID}" \
        "DEST_TYPE=${DEST_TYPE}" \
        "DEST_BASE=${DEST_BASE}" \
        "BACKUP_ROOT=${BACKUP_ROOT}" \
        "RMAN_CHANNELS=${RMAN_CHANNELS}"

    report_confirm "Variaveis corretas?" "YES" || die "Configuracao rejeitada"

    # Step 3: Guards
    report_step "Checking instance state"
    ensure_guards
    report_step_done 0

    # Step 4: Memory sizing
    report_step "Calculating memory targets"
    read -r SGA PGA < <(oracle_config_calc_memory)
    report_item ok "Memory" "SGA=${SGA} PGA=${PGA}"
    report_metric "SGA" "${SGA}"
    report_metric "PGA" "${PGA}"
    report_step_done 0

    log "==[PHASE-A] Completed"
}

#===============================================================================
# PHASE B: Bootstrap & Restore Metadata (writes to /tmp, reversible)
#===============================================================================
phase_bootstrap_and_metadata() {
    report_phase "Bootstrap & Metadata"

    # Step 5: Bootstrap NOMOUNT
    report_step "Creating bootstrap PFILE"
    oracle_config_pfile_write_bootstrap "${BOOT}" "${SGA}" "${PGA}" \
        "${TARGET_DB_UNIQUE_NAME}" "${DEST_BASE}" "${ADMIN_DIR}" "${CONTROL_DIR}"
    show_file "${BOOT}" 120
    report_confirm "Subir NOMOUNT?" "YES" || die "Bootstrap cancelado"
    oracle_instance_startup_nomount "${BOOT}"
    report_item ok "NOMOUNT" "Instance started"
    report_step_done 0

    # Step 6: Restore SPFILE
    report_step "Restoring SPFILE from autobackup"
    write_rman_spfile
    report_preview_exec "${RMAN_BOOT}" oracle_rman_exec_verbose "${RMAN_BOOT}" "${LOGDIR}/01_bootstrap.log" "Restore SPFILE"
    report_item ok "SPFILE" "Restored from autobackup"
    report_step_done 0

    # Step 7: Sanitize PFILE
    report_step "Sanitizing PFILE"
    oracle_sql_sysdba_exec "CREATE PFILE='${PFILE_RAW}' FROM SPFILE;"
    show_file "${PFILE_RAW}" 200

    ORIG_DB_NAME="$(oracle_config_pfile_parse_db_name "${PFILE_RAW}")"
    rt_assert_nonempty "db_name" "${ORIG_DB_NAME}"
    report_meta "ORIG_DB_NAME" "${ORIG_DB_NAME}"
    log "==[DB] origem=${ORIG_DB_NAME} destino=${TARGET_DB_UNIQUE_NAME}"

    report_confirm "Sanear PFILE?" "YES" || die "Sanitizacao cancelada"
    sanitize_pfile
    show_file "${PFILE_CLEAN}" 200
    report_confirm_retype "Confirma db_name=${ORIG_DB_NAME} / db_unique_name=${TARGET_DB_UNIQUE_NAME}?" "YES-ID"
    report_item ok "PFILE" "Sanitized for clone"
    report_step_done 0

    # Step 8: Recreate instance with clean PFILE
    report_step "Recreating instance with clean PFILE"
    oracle_sql_sysdba_exec "SHUTDOWN ABORT;
STARTUP NOMOUNT PFILE='${PFILE_CLEAN}';
CREATE SPFILE FROM PFILE='${PFILE_CLEAN}';
SHUTDOWN ABORT;
STARTUP NOMOUNT;"
    report_item ok "Instance" "Restarted with clean PFILE"
    report_step_done 0

    # Step 9: Copy controlfile + MOUNT
    # Controlfile was already restored to CONTROL_DIR in Step 6 (along with SPFILE)
    report_step "Mounting database"
    cp "${CONTROL_DIR}/control01.ctl" "${CONTROL_DIR}/control02.ctl"
    oracle_sql_sysdba_exec "alter database mount;"
    report_item ok "Database" "Mounted with restored controlfile"
    report_step_done 0

    # Step 10: Discovery map
    report_step "Generating discovery map"
    oracle_rman_generate_discovery_map "${DISC}"
    oracle_rman_print_discovery_summary "${DISC}"
    oracle_rman_print_transformation_plan "${DISC}"
    report_item ok "Discovery" "Map created: ${DISC}"
    report_step_done 0

    log "==[PHASE-B] Completed"
}

#===============================================================================
# Helper: Collect RMAN diagnostic information for troubleshooting
# Called when catalog detection returns 0 items
#===============================================================================
collect_rman_diagnostics() {
    local diagfile="${LOGDIR}/rman_diagnostics.log"
    log_info "Collecting RMAN diagnostics to: ${diagfile}"

    {
        echo "=== RMAN Diagnostics - $(date) ==="
        echo ""
        echo "=== V\$BACKUP_DATAFILE (first 20) ==="
        oracle_sql_sysdba_query "SELECT FILE#, STATUS, COMPLETION_TIME FROM V\$BACKUP_DATAFILE WHERE ROWNUM <= 20;"

        echo ""
        echo "=== V\$BACKUP_SET (first 20) ==="
        oracle_sql_sysdba_query "SELECT BS_KEY, BACKUP_TYPE, STATUS, COMPLETION_TIME FROM V\$BACKUP_SET WHERE ROWNUM <= 20;"

        echo ""
        echo "=== V\$DATAFILE_COPY (first 20) ==="
        oracle_sql_sysdba_query "SELECT FILE#, STATUS, NAME FROM V\$DATAFILE_COPY WHERE ROWNUM <= 20;"

        echo ""
        echo "=== LIST COPY Summary ==="
        oracle_rman_exec_silent "LIST COPY SUMMARY;" 2>&1 || echo "(RMAN command failed)"

        echo ""
        echo "=== LIST BACKUP Summary ==="
        oracle_rman_exec_silent "LIST BACKUP SUMMARY;" 2>&1 || echo "(RMAN command failed)"

        echo ""
        echo "=== REPORT SCHEMA ==="
        oracle_rman_exec_silent "REPORT SCHEMA;" 2>&1 || echo "(RMAN command failed)"
    } > "${diagfile}" 2>&1

    log_info "Diagnostics saved to: ${diagfile}"
}

#===============================================================================
# Helper: Generate all RMAN command files
#===============================================================================
generate_all_command_files() {
    write_rman_preview
    write_rman_validate
    write_rman_restore
    write_rman_recover
    oracle_rman_generate_post_restore_sql "${POST_SQL}"
}

#===============================================================================
# PHASE C: Catalog & Preview (safe after catalog)
#===============================================================================
phase_catalog_and_preview() {
    report_phase "Catalog & Preview"

    # Step: Crosscheck and cleanup expired backups
    report_step "Crosscheck and cleanup expired backups"
    write_rman_crosscheck
    report_preview_exec "${RMAN_XCHK}" oracle_rman_exec_verbose "${RMAN_XCHK}" "${LOGDIR}/02a_crosscheck.log" "Crosscheck backups"
    report_item ok "Crosscheck" "Expired backups removed"
    report_step_done 0

    # Step: Catalog backups
    report_step "Cataloging backup pieces"
    write_rman_catalog
    report_preview_exec "${RMAN_CAT}" oracle_rman_exec_verbose "${RMAN_CAT}" "${LOGDIR}/02b_catalog.log" "Catalog backups"
    report_item ok "Catalog" "Backup pieces cataloged"
    report_step_done 0

    # Step: Validate catalog results (verify something was cataloged)
    report_step "Validating catalog results"
    local cat_files cat_total
    # Count "File Name:" entries in the "List of Cataloged Files" section
    # Note: grep -c returns exit 1 when no matches, so use || true
    cat_files=$(grep -c "^File Name:" "${LOGDIR}/02b_catalog.log" 2>/dev/null || true)
    cat_files="${cat_files:-0}"
    cat_total="${cat_files}"
    if [[ "${cat_total}" -eq 0 ]]; then
        warn "No files were cataloged"
        warn "Check backup path: ${BACKUP_ROOT}"
        warn "This may indicate backups already cataloged or path issues"
    else
        report_item ok "Cataloged" "${cat_total} files"
    fi
    report_step_done 0

    # Step: Detect backup type from catalog
    report_step "Detecting backup type from catalog"
    oracle_rman_detect_catalog_contents
    report_item ok "Detection" "BACKUP_TYPE=${BACKUP_TYPE}"
    report_step_done 0

    # Step: Restore Window Analysis
    report_step "Analyzing restore options"
    oracle_rman_print_restore_options
    report_step_done 0

    # Step: Generate All Command Files
    report_step "Generating RMAN command files"
    generate_all_command_files
    report_item ok "Command files" "Generated (preview, validate, restore, recover)"
    report_step_done 0

    # Show commands preview (tolerate missing files from skipped phases)
    report_section "Commands Preview"
    oracle_rman_print_commands_preview "${RMAN_BOOT}" "RESTORE SPFILE + CONTROLFILE" || true
    oracle_rman_print_commands_preview "${RMAN_CAT}" "CATALOG BACKUPS" || true
    oracle_rman_print_commands_preview "${RMAN_PRE}" "RESTORE PREVIEW" || true
    oracle_rman_print_commands_preview "${RMAN_VAL}" "RESTORE VALIDATE" || true
    oracle_rman_print_commands_preview "${RMAN_RES}" "RESTORE DATABASE" || true
    oracle_rman_print_commands_preview "${RMAN_REC}" "RECOVER DATABASE" || true
    oracle_rman_print_post_restore_sql_preview "${POST_SQL}" || true

    log "==[PHASE-C] Completed"
}

#===============================================================================
# PHASE D: Validate & Full Restore (destructive)
#===============================================================================
phase_validate_and_restore() {
    report_phase "Validate & Restore"

    # Load previous execution state (from DRY_RUN=1 or previous run)
    _rman_state_load || log_debug "No previous execution state found"

    # Skip preview/validate if --resume-from=restore or later
    # When resuming from restore/recover, catalog is already done and validate was
    # either already run (DRY_RUN=1 previous run) or intentionally skipped
    local skip_validation=0
    if [[ "${RESUME_FROM:-}" == "restore" || "${RESUME_FROM:-}" == "recover" ]]; then
        skip_validation=1
        log_info "[SKIP] Preview/Validate: Skipped due to --resume-from=${RESUME_FROM}"
    fi

    # Validate PITR parameters if specified (always run, even in skip mode)
    if [[ -n "${UNTIL_TIME:-}" || -n "${UNTIL_SCN:-}" ]]; then
        report_step "Validating Point-in-Time Recovery parameters"
        if ! oracle_rman_validate_pitr; then
            die "PITR validation failed. Check UNTIL_TIME or UNTIL_SCN values."
        fi
        if [[ -n "${UNTIL_TIME:-}" ]]; then
            report_item ok "PITR Mode" "UNTIL_TIME='${UNTIL_TIME}'"
        else
            report_item ok "PITR Mode" "UNTIL_SCN=${UNTIL_SCN}"
        fi
        report_step_done 0
    fi

    # Check catalog divergence (skip if resume mode)
    if [[ "${skip_validation}" -eq 0 ]] && ! oracle_rman_check_catalog_divergence; then
        report_step "Checking catalog state"
        if report_confirm "Catalog may be stale. Re-run crosscheck?" "YES"; then
            write_rman_crosscheck
            oracle_rman_exec_with_state "CROSSCHECK" "${RMAN_XCHK}" "${LOGDIR}/02a_crosscheck_refresh.log" "Crosscheck backups" --force
        else
            log_info "Skipping crosscheck refresh (user decision)"
        fi
        report_step_done 0
    fi

    # DRY_RUN controla O QUE EXECUTA:
    #   2 = Para antes de restaurar controlfile (já parou em Phase A)
    #   1 = Executa até validate, NÃO executa restore
    #   0 = Pula validate, executa restore direto
    #
    # --resume-from controla DE ONDE COMEÇA (independente do DRY_RUN)
    # When skip_validation=1, skip preview/validate regardless of DRY_RUN

    if [[ "${DRY_RUN}" == "1" && "${skip_validation}" -eq 0 ]]; then
        # DRY_RUN=1: Executa preview + validate e para
        report_step "Running restore preview"
        oracle_rman_exec_with_state "PREVIEW" "${RMAN_PRE}" "${LOGDIR}/03_preview.log" "Restore Preview"
        report_item ok "Preview" "Completed"
        report_step_done 0

        report_step "Running restore validate"
        oracle_rman_exec_with_state "VALIDATE" "${RMAN_VAL}" "${LOGDIR}/04_validate.log" "Restore Validate"
        report_item ok "Validate" "Completed"
        report_step_done 0

        # EXIT POINT: DRY_RUN=1 para aqui
        report_metric "status" "DRY_RUN_1_VALIDATED"
        report_finalize

        echo ""
        echo "================================================================"
        echo "  DRY_RUN=1 COMPLETED - PREVIEW & VALIDATE OK"
        echo "================================================================"
        echo "  BACKUP_TYPE: ${BACKUP_TYPE:-unknown}"
        echo "  State saved to: $(_rman_state_file)"
        echo "  Restore Preview:  ${LOGDIR}/03_preview.log"
        echo "  Restore Validate: ${LOGDIR}/04_validate.log"
        echo ""
        echo "  TO EXECUTE RESTORE:"
        echo "    DRY_RUN=0 ./restore.sh --resume-from=restore"
        echo "================================================================"
        exit 0
    fi

    # DRY_RUN=0 or skip_validation=1: Skip validate, go to restore
    if [[ "${skip_validation}" -eq 0 ]]; then
        log_info "[SKIP] Preview/Validate: DRY_RUN=0 skips validation, executing restore"
    fi

    # Step: Space check
    report_step "Checking available space"
    oracle_config_space_check "${DEST_BASE}/oradata/${TARGET_DB_UNIQUE_NAME}"
    report_item ok "Space" "Check passed"
    report_step_done 0

    # Step: Full Restore (always executes - destructive operation)
    report_step "Executing full database restore"
    oracle_rman_exec_with_state "RESTORE" "${RMAN_RES}" "${LOGDIR}/05_restore.log" "RESTORE DATABASE" --force
    report_item ok "Restore" "Database restored"
    report_metric "restore_completed" "1"
    report_step_done 0

    # Step: Recover (always executes - destructive operation)
    report_step "Applying archived logs"
    oracle_rman_exec_with_state "RECOVER" "${RMAN_REC}" "${LOGDIR}/06_recover.log" "RECOVER DATABASE" --force
    report_item ok "Recover" "Database recovered"
    report_step_done 0

    # Step 19: Rename redo logs and tempfiles (must be in MOUNT)
    report_step "Renaming redo logs and tempfiles"
    {
        echo "-- Redo log renames"
        oracle_rman_build_redo_rename
        echo "-- Tempfile renames"
        oracle_rman_build_tempfile_rename
    } > "${RENAME_SQL}"
    show_file "${RENAME_SQL}" 50

    report_confirm "Executar file renames?" "RENAME-FILES" || die "Rename cancelado"
    while IFS= read -r rename_cmd; do
        [[ -z "${rename_cmd}" || "${rename_cmd}" == "--"* ]] && continue
        log "[SQL] ${rename_cmd}"
        oracle_sql_sysdba_exec "${rename_cmd}" || log_warning "Rename failed (file may not exist yet)"
    done < "${RENAME_SQL}"
    report_item ok "Redo logs" "Paths updated in controlfile"
    report_item ok "Tempfiles" "Paths updated in controlfile"
    report_step_done 0

    # Step 20: Open Database
    report_step "Opening database with RESETLOGS"
    rt_assert_file_exists "POST_SQL" "${POST_SQL}"
    show_file "${POST_SQL}" 100

    report_confirm "Executar ALTER DATABASE OPEN RESETLOGS?" "OPEN-RESETLOGS" || die "Open cancelado"
    oracle_sql_sysdba_exec "ALTER DATABASE OPEN RESETLOGS;"
    oracle_sql_sysdba_exec "SELECT NAME, OPEN_MODE, DATABASE_ROLE FROM V\$DATABASE;"
    report_item ok "Database" "Opened with RESETLOGS"
    report_step_done 0

    # Step 21: Set NOARCHIVELOG mode
    report_step "Setting NOARCHIVELOG mode"
    report_confirm "Desabilitar archivelog?" "NOARCHIVELOG" || log_warning "Archivelog mode unchanged"
    oracle_sql_sysdba_exec "SHUTDOWN IMMEDIATE;"
    oracle_sql_sysdba_exec "STARTUP MOUNT;"
    oracle_sql_sysdba_exec "ALTER DATABASE NOARCHIVELOG;"
    oracle_sql_sysdba_exec "ALTER DATABASE OPEN;"
    oracle_sql_sysdba_exec "SELECT LOG_MODE FROM V\$DATABASE;"
    report_item ok "NOARCHIVELOG" "Mode set"
    report_step_done 0

    # Step 22: Final Verification
    report_step "Final verification"
    oracle_sql_sysdba_exec "SELECT INSTANCE_NAME, STATUS, DATABASE_STATUS FROM V\$INSTANCE;"
    oracle_sql_sysdba_exec "SELECT COUNT(*) AS DATAFILE_COUNT FROM V\$DATAFILE;"
    oracle_sql_sysdba_exec "SELECT TABLESPACE_NAME, FILE_NAME, BYTES/1024/1024/1024 AS SIZE_GB FROM DBA_TEMP_FILES ORDER BY 1,2;"
    report_item ok "Verification" "Complete"
    report_metric "status" "SUCCESS"
    report_step_done 0

    log "==[PHASE-D] Completed"
}

#===============================================================================
# ARGUMENT PARSING
#===============================================================================
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --continue|-c)
                CONTINUE_MODE=1
                shift
                ;;
            --resume-from=*)
                RESUME_FROM="${1#*=}"
                shift
                ;;
            --resume-from)
                RESUME_FROM="$2"
                shift 2
                ;;
            --until-time=*)
                UNTIL_TIME="${1#*=}"
                shift
                ;;
            --until-time)
                UNTIL_TIME="$2"
                shift 2
                ;;
            --until-scn=*)
                UNTIL_SCN="${1#*=}"
                shift
                ;;
            --until-scn)
                UNTIL_SCN="$2"
                shift 2
                ;;
            --help|-h)
                cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --continue, -c         Resume restore from current database state
                         (skip phases already completed based on instance status)
  --resume-from=PHASE    Skip directly to a specific phase:
                           catalog  = Skip to Phase C (catalog & preview)
                           restore  = Skip to Phase D (validate & restore)
                           recover  = Skip to Phase D, Step 18 (recover only)
  --until-time=TIME      Point-in-time recovery: restore to specific time
                         Format: 'YYYY-MM-DD HH24:MI:SS' (e.g., '2026-01-16 14:30:00')
  --until-scn=NUMBER     Point-in-time recovery: restore to specific SCN
  --help, -h             Show this help message

Environment Variables:
  ORACLE_HOME      Required. Oracle home path
  TARGET_SID       Target SID (default: ORACLE_SID or RES)
  DRY_RUN          0=full restore, 1=stop after validate (saves state), 2=stop after config
  AUTO_YES         0=interactive, 1=skip confirmations
  CONTINUE_MODE    0=normal, 1=resume from current state
  RESUME_FROM      Phase to resume from (catalog, restore, recover)
  UNTIL_TIME       Point-in-time recovery timestamp
  UNTIL_SCN        Point-in-time recovery SCN
  (see script header for full list)

State Tracking:
  - DRY_RUN=1 saves execution state to \${LOGDIR}/execution_state.sh
  - DRY_RUN=0 skips preview/validate if already completed in previous run
  - Use --force-preview to re-run preview/validate even if already done

Examples:
  # Normal restore from scratch
  ORACLE_HOME=/u01/app/oracle/product/19c TARGET_SID=NEWDB ./restore.sh

  # Resume from current state (database already MOUNTED)
  ORACLE_HOME=/u01/app/oracle/product/19c TARGET_SID=NEWDB ./restore.sh --continue

  # Skip to restore phase (after catalog is complete)
  ORACLE_HOME=/u01/app/oracle/product/19c TARGET_SID=NEWDB ./restore.sh --resume-from=restore

  # Point-in-time recovery to specific time
  ./restore.sh --resume-from=restore --until-time='2026-01-16 14:30:00'

  # Point-in-time recovery to specific SCN
  ./restore.sh --resume-from=restore --until-scn=1234567890

  # Validate only - preview and validate without restore (DRY_RUN=1)
  DRY_RUN=1 ./restore.sh

  # Full restore after DRY_RUN=1 (skips preview/validate)
  DRY_RUN=0 ./restore.sh
EOF
                exit 0
                ;;
            *)
                die "Unknown option: $1. Use --help for usage."
                ;;
        esac
    done
}

#===============================================================================
# CONTINUE MODE: State Detection
#===============================================================================
detect_db_state() {
    # Detect current database state for CONTINUE_MODE
    # Returns: DOWN, STARTED, MOUNTED, OPEN
    # V$INSTANCE.STATUS values: STARTED=NOMOUNT, MOUNTED=MOUNT, OPEN=OPEN
    local status query_failed=0

    # Try SQL query first (most reliable when instance is accessible)
    status=$(oracle_sql_sysdba_query "SELECT STATUS FROM V\$INSTANCE;" 2>/dev/null | tr -d '[:space:]') || query_failed=1

    if [[ "${query_failed}" -eq 0 && -n "${status}" ]]; then
        case "${status}" in
            STARTED)
                log_debug "V\$INSTANCE.STATUS=STARTED (NOMOUNT state)"
                echo "STARTED"
                ;;
            MOUNTED)
                log_debug "V\$INSTANCE.STATUS=MOUNTED"
                echo "MOUNTED"
                ;;
            OPEN)
                log_debug "V\$INSTANCE.STATUS=OPEN"
                echo "OPEN"
                ;;
            *)
                log_debug "V\$INSTANCE.STATUS=${status} (unexpected)"
                echo "STARTED"  # Conservative: treat unknown as NOMOUNT
                ;;
        esac
        return 0
    fi

    # Fallback: Check if pmon process exists (SQL failed or returned empty)
    if pgrep -f "ora_pmon_${ORACLE_SID}" >/dev/null 2>&1; then
        log_debug "SQL query failed but pmon process exists - assuming NOMOUNT"
        echo "STARTED"
        return 0
    fi

    # No instance running
    log_debug "No pmon process for ${ORACLE_SID} - database is DOWN"
    echo "DOWN"
}

determine_skip_to_phase() {
    # Based on database state, determine which phase to skip to
    local state="$1"

    case "${state}" in
        MOUNTED)
            # Database is mounted - skip to catalog phase
            echo "catalog"
            log_info "CONTINUE_MODE: Database is MOUNTED, skipping to Phase C (Catalog)"
            ;;
        STARTED)
            # Instance started but not mounted - need to restore controlfile
            echo "bootstrap"
            log_info "CONTINUE_MODE: Database is STARTED (NOMOUNT), skipping to Phase B"
            ;;
        OPEN)
            # Database is open - nothing to restore
            log_warning "CONTINUE_MODE: Database is already OPEN!"
            echo "done"
            ;;
        *)
            # Database is down - start from beginning
            echo ""
            log_info "CONTINUE_MODE: Database is DOWN, starting from Phase A"
            ;;
    esac
}

#===============================================================================
# MAIN
#===============================================================================
main() {
    local skip_to=""

    # Handle RESUME_FROM: explicit phase skip (takes precedence over CONTINUE_MODE)
    if [[ -n "${RESUME_FROM}" ]]; then
        case "${RESUME_FROM}" in
            catalog|phase-c)
                skip_to="catalog"
                log_info "RESUME_FROM=${RESUME_FROM}: Skipping to Phase C (Catalog & Preview)"
                ;;
            restore|phase-d)
                skip_to="restore"
                log_info "RESUME_FROM=${RESUME_FROM}: Skipping to Phase D (Validate & Restore)"
                ;;
            recover)
                skip_to="recover"
                log_info "RESUME_FROM=${RESUME_FROM}: Skipping to Phase D, Step 18 (Recover)"
                ;;
            *)
                die "Invalid RESUME_FROM value: ${RESUME_FROM}. Valid: catalog, restore, recover"
                ;;
        esac
        report_meta "RESUME_FROM" "${RESUME_FROM}"
        report_meta "SKIP_TO" "${skip_to}"
    # Handle CONTINUE_MODE: detect current state and skip completed phases
    elif [[ "${CONTINUE_MODE}" == "1" ]]; then
        log_info "CONTINUE_MODE enabled - detecting database state..."
        local db_state
        db_state=$(detect_db_state)
        skip_to=$(determine_skip_to_phase "${db_state}")

        if [[ "${skip_to}" == "done" ]]; then
            log_warning "Database is already OPEN. Nothing to restore."
            echo "================================================================"
            echo "  Database ${ORACLE_SID} is already OPEN"
            echo "  Use normal mode (without --continue) to start fresh"
            echo "================================================================"
            exit 0
        fi

        report_meta "CONTINUE_MODE" "1"
        report_meta "SKIP_TO" "${skip_to:-none}"
    fi

    # Phase A: Validation & Discovery (read-only)
    if [[ "${skip_to}" != "catalog" && "${skip_to}" != "bootstrap" && "${skip_to}" != "restore" && "${skip_to}" != "recover" ]]; then
        phase_validate_and_discover
        if [[ "${DRY_RUN}" == "2" ]]; then
            report_metric "status" "DRY_RUN_2"
            report_finalize
            log_info "DRY_RUN=2: Stopping after validation phase"
            exit 0
        fi
    else
        # Minimal setup for skip mode - banco já está montado com controlfile restaurado
        log_info "SKIP_TO=${skip_to}: Skipping Phase A (Validation & Discovery)"
        validate_all
        oracle_config_resolve_paths "${DEST_TYPE}" "${DEST_BASE}" "${TARGET_DB_UNIQUE_NAME}" "${DATA_DG}" "${FRA_DG}"
        oracle_rman_auto_channels
        # Não precisa discovery - catalog já foi feito e está no controlfile
    fi

    # Phase B: Bootstrap & Metadata (spfile, controlfile, pfile, mount)
    if [[ "${skip_to}" != "catalog" && "${skip_to}" != "restore" && "${skip_to}" != "recover" ]]; then
        phase_bootstrap_and_metadata
    else
        # For skip mode, need to initialize transformation from mounted DB
        log_info "SKIP_TO=${skip_to}: Skipping Phase B (Bootstrap & Metadata)"
        log_info "SKIP_TO=${skip_to}: Initializing transformation map from mounted database..."

        # Get db_name from mounted database
        ORIG_DB_NAME=$(oracle_sql_sysdba_query "SELECT NAME FROM V\$DATABASE;" | tr -d '[:space:]')
        report_meta "ORIG_DB_NAME" "${ORIG_DB_NAME}"
        log "==[DB] origem=${ORIG_DB_NAME} destino=${TARGET_DB_UNIQUE_NAME}"

        # Generate discovery map
        oracle_rman_generate_discovery_map "${DISC}"
    fi

    # Phase C: Catalog & Preview (analyze restore window, show commands)
    # Catalog persists in controlfile. Skip mode assumes catalog was done previously.
    if [[ "${skip_to}" != "restore" && "${skip_to}" != "recover" ]]; then
        phase_catalog_and_preview
    else
        log_info "SKIP_TO=${skip_to}: Skipping Phase C (Catalog & Preview) - assuming catalog already done"
        report_phase "Catalog & Preview (Skip Mode)"

        # ONLY detect what's already in the catalog - DO NOT re-catalog
        # Catalog persists in controlfile, so we assume it was done previously
        report_step "Detecting backup type from existing catalog"
        oracle_rman_detect_catalog_contents

        # If no backups detected, collect diagnostics
        if [[ "${_RMAN_BACKUPSET_COUNT:-0}" -eq 0 ]] && [[ "${_RMAN_IMAGECOPY_COUNT:-0}" -eq 0 ]]; then
            warn "No backups detected in catalog - collecting diagnostics"
            collect_rman_diagnostics
        fi

        report_item ok "Detection" "BACKUP_TYPE=${BACKUP_TYPE}"
        report_step_done 0

        # Analyze restore options (sets PITR globals)
        report_step "Analyzing restore options"
        oracle_rman_print_restore_options
        report_step_done 0

        # Generate command files based on detected backup type
        report_step "Generating command files"
        generate_all_command_files
        report_item ok "Command files" "Generated"
        report_step_done 0
    fi

    # Phase D: Validate & Full Restore (destructive)
    # Note: DRY_RUN=1 exits from within phase_validate_and_restore() after validation
    phase_validate_and_restore

    # Finalize report
    report_finalize

    echo ""
    echo "================================================================"
    echo "  RESTORE COMPLETED SUCCESSFULLY"
    echo "================================================================"
    echo "  Database:     ${TARGET_DB_UNIQUE_NAME}"
    echo "  Source:       ${ORIG_DB_NAME}"
    echo "  Location:     ${DEST_BASE}/oradata/${TARGET_DB_UNIQUE_NAME}"
    echo "  Report:       ${LOGDIR}/${SESSION_ID}_report.md"
    echo "================================================================"
    echo ""
    echo "  Next steps:"
    echo "    1. Verify all tablespaces are ONLINE"
    echo "    2. Run: rman target / <<< 'crosscheck backup; delete noprompt obsolete;'"
    echo "    3. Take a fresh level 0 backup"
    echo "    4. Test application connectivity"
    echo "================================================================"
    echo ""
}

# Parse command line arguments first
parse_args "$@"

# Run main
main
