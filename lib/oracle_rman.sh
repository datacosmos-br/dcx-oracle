#!/usr/bin/env bash
# shellcheck shell=bash
#===============================================================================
# Datacosmos - Oracle RMAN Module (v3.1.2)
#===============================================================================
# Features: RAC Support (Thread#), Unified Transformation Engine, Fail Early,
#           Zero Duplication, CPU-based Auto-Channels, Full Reporting.
#
# REPORT INTEGRATION:
#   This module integrates with report.sh for RMAN operation tracking:
#   - Tracked Steps: Backup discovery, transformation initialization/generation/application
#   - Tracked Metrics: rman_datafiles, rman_tempfiles, rman_redologs, rman_transformations_total
#   - Tracked Items: File transformations with source/destination paths
#   - Metadata: DBID, backup root path, channel configuration, transformation counts
#   - Integration is graceful (NO-OP without report_init)
#   - All metrics have rman_ prefix for pattern-based aggregation
#===============================================================================

# Prevent double sourcing
[[ -n "${__ORACLE_RMAN_LOADED:-}" ]] && return 0
__ORACLE_RMAN_LOADED=1

_ORACLE_RMAN_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load dependencies
[[ -z "${__ORACLE_CORE_LOADED:-}" ]] && source "${_ORACLE_RMAN_LIB_DIR}/oracle_core.sh"
[[ -z "${__ORACLE_SQL_LOADED:-}" ]] && source "${_ORACLE_RMAN_LIB_DIR}/oracle_sql.sh"
[[ -z "${__RUNTIME_LOADED:-}" ]] && source "${_ORACLE_RMAN_LIB_DIR}/runtime.sh"
[[ -z "${__REPORT_LOADED:-}" ]] && source "${_ORACLE_RMAN_LIB_DIR}/report.sh"

#===============================================================================
# GLOBAL STATE (Transformation Map)
#===============================================================================
declare -gA _RMAN_TRANS_TYPE      # key -> DF|TF|RL
declare -gA _RMAN_TRANS_SRC       # key -> source_path
declare -gA _RMAN_TRANS_DST       # key -> dest_path
declare -ga _RMAN_TRANS_KEYS=()   # Ordered keys: "id|type"

# Configuration
ORACLE_LOG_VERBOSE="${ORACLE_LOG_VERBOSE:-0}"
RMAN_CHANNELS="${RMAN_CHANNELS:-4}"
RMAN_DEFAULT_TIMEOUT="${RMAN_DEFAULT_TIMEOUT:-0}"

#===============================================================================
# SECTION 1: Internal Helpers & Fail Early
#===============================================================================

_rman_ensure_mounted() {
    # Query actual database state from v$instance.status (STARTED/MOUNTED/OPEN)
    local state
    state=$(oracle_sql_sysdba_query "select status from v\$instance;" 2>/dev/null | tr -d '[:space:]')
    [[ "${state}" == "MOUNTED" || "${state}" == "OPEN" ]] || \
        die "Banco de dados precisa estar em MOUNT ou OPEN para esta operacao (Atual: ${state})"
}

_rman_validate_discovery() {
    local disc="${1:-${DISC:-}}"
    [[ -n "${disc}" ]] || die "Variavel DISC nao definida"
    [[ -f "${disc}" ]] || die "Arquivo de descoberta nao encontrado: ${disc}"
}

_rman_clean_name() {
    local path="${1?ERROR: Missing required parameter: path}"
    local ftype="${2:-dbf}"
    local fname="${path##*/}"

    if [[ "${fname}" =~ ^o1_mf_(.+)_[a-z0-9]+_\.dbf$ ]]; then fname="${BASH_REMATCH[1]}";
    elif [[ "${fname}" =~ ^([a-zA-Z_][a-zA-Z0-9_]*)\.[0-9]+\.[0-9]+$ ]]; then fname="${BASH_REMATCH[1]}";
    else fname="${fname%.*}"; fi

    # Optimization: Use bash substitution instead of tr/subshell for performance
    local clean="${fname//[^a-zA-Z0-9_]/}"
    echo "${clean}.${ftype,,}"
}

#===============================================================================
# SECTION 2: Channel Management
#===============================================================================

oracle_rman_auto_channels() {
    local n; n="$(nproc 2>/dev/null || echo 4)"
    if [[ -z "${RMAN_CHANNELS_OVERRIDE:-}" ]]; then
        RMAN_CHANNELS=$(( n >= 8 ? 8 : (n >= 4 ? 4 : n) ))
        log "[AUTO] RMAN_CHANNELS=${RMAN_CHANNELS} (CPUs: ${n})"
    else
        RMAN_CHANNELS="${RMAN_CHANNELS_OVERRIDE}"
        log "[CONFIG] RMAN_CHANNELS=${RMAN_CHANNELS} (Manual)"
    fi
}

oracle_rman_channels_alloc() {
    local i; for i in $(seq 1 "${RMAN_CHANNELS:-4}"); do
        echo "  allocate channel c${i} device type disk;"
    done
}

oracle_rman_channels_release() {
    local i; for i in $(seq 1 "${RMAN_CHANNELS:-4}"); do
        echo "  release channel c${i};"
    done
}

#===============================================================================
# SECTION 3: Backup Discovery & DBID Detection
#===============================================================================

oracle_rman_detect_dbid() {
    local auto="${1:-}"
    [[ -n "${auto}" ]] || return 1
    [[ -d "${auto}" ]] || return 1
    
    # shellcheck disable=SC2012
    local dbids; dbids="$(ls -1 "${auto}"/c-* 2>/dev/null | sed -n 's|.*/c-\([0-9]\+\)-.*|\1|p' | sort -u)"
    
    # Handle empty result
    [[ -z "${dbids}" ]] && return 1
    
    # Count unique DBIDs
    local cnt; cnt=$(echo "${dbids}" | wc -l)
    cnt="${cnt// /}"  # Remove whitespace from wc output
    
    if [[ "${cnt}" -eq 1 ]]; then
        echo "${dbids}"
        return 0
    elif [[ "${cnt}" -gt 1 ]]; then
        return 2
    fi
    return 1
}

oracle_rman_backup_discover() {
    local root="${1?ERROR: Missing required parameter: root}"
    local max_depth="${2:-10}"

    # Track operation
    report_track_step "Discover RMAN backups from ${root}"
    report_track_meta "rman_backup_root" "${root}"
    report_track_meta "rman_max_depth" "${max_depth}"

    [[ -d "${root}" ]] || die "Diretorio de backups nao encontrado: ${root}"
    log "[DISCOVER] Scanning: ${root} (max depth: ${max_depth})"

    # Initialize discovery variables
    AUTO=""           # Autobackup controlfile directory
    DBID=""           # Database ID

    # Find controlfile/spfile autobackup files (c-DBID-*) anywhere
    local ctrl_file
    ctrl_file=$(find "${root}" -maxdepth "${max_depth}" -type f -name "c-*" 2>/dev/null | head -n 1)
    if [[ -n "${ctrl_file}" ]]; then
        AUTO=$(dirname "${ctrl_file}")
        DBID=$(oracle_rman_detect_dbid "${AUTO}") || warn "Nao foi possivel detectar DBID unico em ${AUTO}"
    fi

    [[ -n "${AUTO}" ]] || die "Nenhum arquivo de controlfile autobackup (c-*) encontrado em ${root}"

    # Export discovery results - backup type will be detected AFTER cataloging
    export AUTO DBID
    export BACKUP_TYPE=""  # Will be set by oracle_rman_detect_catalog_contents()

    log "[DISCOVER] Results:"
    log "  AUTO: ${AUTO}"
    log "  DBID: ${DBID:-nao detectado}"
    log_success "[OK] Controlfile autobackup found"

    # Track results
    report_track_item "ok" "Backup Discovery" "Auto: ${AUTO}"
    report_track_meta "rman_dbid" "${DBID:-unknown}"
    report_track_meta "rman_autobackup_path" "${AUTO}"
    report_track_step_done 0 "Backups discovered: DBID=${DBID}"
}

#-------------------------------------------------------------------------------
# Detect what's in the RMAN catalog after cataloging
# Must be called AFTER catalog phase when database is MOUNTED
# Sets BACKUP_TYPE based on actual catalog contents
#-------------------------------------------------------------------------------
oracle_rman_detect_catalog_contents() {
    _rman_ensure_mounted

    log "[CATALOG-DETECT] Querying catalog for available backup types..."

    local catalog_info
    catalog_info=$(oracle_sql_sysdba_query "
        SELECT 'BACKUPSET_COUNT|'||COUNT(*) FROM v\$backup_set WHERE backup_type IN ('D','I');
        SELECT 'DATAFILE_COPY_COUNT|'||COUNT(*) FROM v\$datafile_copy WHERE status='A';
        SELECT 'ARCHIVELOG_COUNT|'||COUNT(*) FROM v\$archived_log WHERE status='A' AND name IS NOT NULL;
        SELECT 'BACKUP_REDOLOG_COUNT|'||COUNT(*) FROM v\$backup_redolog;
    " 2>/dev/null || true)

    local backupset_count=0 datafile_copy_count=0 archivelog_count=0 backup_redolog_count=0

    while IFS='|' read -r label count; do
        case "${label}" in
            BACKUPSET_COUNT)      backupset_count="${count//[^0-9]/}" ;;
            DATAFILE_COPY_COUNT)  datafile_copy_count="${count//[^0-9]/}" ;;
            ARCHIVELOG_COUNT)     archivelog_count="${count//[^0-9]/}" ;;
            BACKUP_REDOLOG_COUNT) backup_redolog_count="${count//[^0-9]/}" ;;
        esac
    done <<< "${catalog_info}"

    log "[CATALOG-DETECT] Results:"
    log "  Backup Sets (D/I): ${backupset_count}"
    log "  Datafile Copies:   ${datafile_copy_count}"
    log "  Archived Logs:     ${archivelog_count}"
    log "  Backup Redologs:   ${backup_redolog_count}"

    # Determine backup type based on what's cataloged
    local has_backupset=0 has_imagecopy=0
    [[ "${backupset_count:-0}" -gt 0 ]] && has_backupset=1
    [[ "${datafile_copy_count:-0}" -gt 0 ]] && has_imagecopy=1

    if [[ ${has_backupset} -eq 1 && ${has_imagecopy} -eq 1 ]]; then
        BACKUP_TYPE="both"
        log_success "[OK] Both backup sets AND image copies available"
    elif [[ ${has_imagecopy} -eq 1 ]]; then
        BACKUP_TYPE="imagecopy"
        log_success "[OK] Image copies available (SWITCH TO COPY)"
    elif [[ ${has_backupset} -eq 1 ]]; then
        BACKUP_TYPE="backupset"
        log_success "[OK] Backup sets available (RESTORE DATABASE)"
    else
        BACKUP_TYPE="backupset"
        warn "[WARN] No backups detected in catalog - defaulting to backupset mode"
    fi

    # Check archivelog availability for PITR
    local total_arch=$((archivelog_count + backup_redolog_count))
    if [[ ${total_arch} -gt 0 ]]; then
        log_success "[OK] ${total_arch} archived logs available for recovery"
    else
        warn "[WARN] No archived logs cataloged - PITR not available"
    fi

    export BACKUP_TYPE
    export CATALOG_BACKUPSET_COUNT="${backupset_count}"
    export CATALOG_IMAGECOPY_COUNT="${datafile_copy_count}"
    export CATALOG_ARCHIVELOG_COUNT="${total_arch}"
}

#===============================================================================
# SECTION 4: Unified Transformation Engine
#===============================================================================

oracle_rman_init_transformation() {
    local disc="${1:-${DISC:-}}"
    _rman_validate_discovery "${disc}"

    # Track operation
    report_track_step "Initialize RMAN transformation map"
    report_track_meta "rman_discovery_file" "${disc}"

    local base="${DEST_BASE:-/restore}/oradata/${TARGET_DB_UNIQUE_NAME:-restore}"
    local dest_type="${DEST_TYPE:-FS}"
    local dg="${DATA_DG:-+DATA}"

    report_track_meta "rman_dest_type" "${dest_type}"
    report_track_meta "rman_dest_base" "${base}"

    _RMAN_TRANS_KEYS=()
    local k; for k in "${!_RMAN_TRANS_TYPE[@]}"; do unset "_RMAN_TRANS_TYPE[$k]"; done

    local section=""
    declare -A name_counts
    declare -A redo_member_counts

    local df_count=0 tf_count=0 rl_count=0

    while IFS='|' read -r id path thread || [[ -n "${id}" ]]; do
        case "${id}" in
            "--DATAFILES--") section="DF"; continue ;;
            "--TEMPFILES--") section="TF"; continue ;;
            "--REDO--")      section="RL"; continue ;;
        esac
        if [[ -z "${section}" || -z "${path}" ]]; then continue; fi

        local key="${id}|${section}"
        local fname ext="dbf"
        if [[ "${section}" == "RL" ]]; then ext="log"; fi

        fname=$(_rman_clean_name "${path}" "${ext}")
        if [[ "${section}" == "TF" ]]; then fname="temp_${fname}"; fi

        local dst_path
        if [[ "${dest_type}" == "FS" ]]; then
            local final_name="${fname}"
            if [[ -n "${name_counts[$fname]+isset}" ]]; then
                (( name_counts[$fname]++ )) || true
                final_name="${fname%.*}_${name_counts[$fname]}.${ext}"
            else name_counts[$fname]=1; fi

            if [[ "${section}" == "RL" ]]; then
                # Initialize redo member count if not set
                [[ -n "${redo_member_counts[$id]+isset}" ]] || redo_member_counts[$id]=0
                (( redo_member_counts[$id]++ )) || true
                dst_path="${base}/redo_t${thread:-1}_g${id}_m${redo_member_counts[$id]}_${final_name}"
                (( rl_count++ )) || true
            else
                dst_path="${base}/${final_name}"
                if [[ "${section}" == "TF" ]]; then
                    (( ++tf_count ))
                else
                    (( ++df_count ))
                fi
            fi
        else
            dst_path="${dg}"
            if [[ "${section}" == "TF" ]]; then
                (( ++tf_count ))
            else
                (( ++df_count ))
            fi
        fi

        _RMAN_TRANS_KEYS+=("${key}")
        _RMAN_TRANS_TYPE["${key}"]="${section}"
        _RMAN_TRANS_SRC["${key}"]="${path}"
        _RMAN_TRANS_DST["${key}"]="${dst_path}"

        # Track each transformation as item
        report_track_item "ok" "${section}: ${id}" "→ ${dst_path}"
    done < "${disc}"

    # Track metrics
    local total_trans=$((df_count + tf_count + rl_count))
    report_track_metric "rman_datafiles" "${df_count}" "set"
    report_track_metric "rman_tempfiles" "${tf_count}" "set"
    report_track_metric "rman_redologs" "${rl_count}" "set"
    report_track_metric "rman_transformations_total" "${total_trans}" "set"

    report_track_step_done 0 "Built ${total_trans} transformations (${df_count} DF, ${tf_count} TF, ${rl_count} RL)"
}

oracle_rman_build_newname_lines() {
    if [[ ${#_RMAN_TRANS_KEYS[@]} -eq 0 ]]; then oracle_rman_init_transformation; fi
    for key in "${_RMAN_TRANS_KEYS[@]}"; do
        local id="${key%|*}" type="${_RMAN_TRANS_TYPE[$key]}"
        [[ "${type}" == "RL" ]] && continue || true
        local cmd="datafile"
        if [[ "${type}" == "TF" ]]; then cmd="tempfile"; fi
        printf "  set newname for %s %s to '%s';\n" "${cmd}" "${id}" "${_RMAN_TRANS_DST[$key]}"
    done
}

oracle_rman_build_redo_rename() {
    if [[ ${#_RMAN_TRANS_KEYS[@]} -eq 0 ]]; then oracle_rman_init_transformation; fi
    for key in "${_RMAN_TRANS_KEYS[@]}"; do
        [[ "${_RMAN_TRANS_TYPE[$key]}" == "RL" ]] || continue
        printf "alter database rename file '%s' to '%s';\n" "${_RMAN_TRANS_SRC[$key]}" "${_RMAN_TRANS_DST[$key]}"
    done
}

oracle_rman_build_tempfile_rename() {
    if [[ ${#_RMAN_TRANS_KEYS[@]} -eq 0 ]]; then oracle_rman_init_transformation; fi
    for key in "${_RMAN_TRANS_KEYS[@]}"; do
        [[ "${_RMAN_TRANS_TYPE[$key]}" == "TF" ]] || continue
        # Rename tempfile path in controlfile (same as redo logs)
        printf "alter database rename file '%s' to '%s';\n" "${_RMAN_TRANS_SRC[$key]}" "${_RMAN_TRANS_DST[$key]}"
    done
}

#===============================================================================
# SECTION 5: RMAN Operations
#===============================================================================

oracle_rman_generate_discovery_map() {
    local output="${1:-${DISC:-/tmp/discovery_map.txt}}"

    # Track operation
    report_track_step "Generate RMAN discovery map"
    report_track_meta "rman_discovery_output" "${output}"

    _rman_ensure_mounted
    log "[DISCOVERY] Generating map: ${output}"

    local sql_script="/tmp/discovery_$$.sql"
    cat > "${sql_script}" << 'EOSQL'
SET ECHO OFF FEEDBACK OFF HEADING OFF PAGES 0 LINES 500 TRIMSPOOL ON TERMOUT OFF
WHENEVER SQLERROR EXIT 1
SPOOL &1
SELECT '--DATAFILES--' FROM DUAL;
SELECT file#||'|'||name FROM v$datafile ORDER BY file#;
SELECT '--TEMPFILES--' FROM DUAL;
SELECT file#||'|'||name FROM v$tempfile ORDER BY file#;
SELECT '--REDO--' FROM DUAL;
SELECT l.group#||'|'||f.member||'|'||l.thread# FROM v$logfile f JOIN v$log l ON l.group#=f.group# ORDER BY l.thread#, l.group#, f.member;
SPOOL OFF
EXIT
EOSQL

    local sqlplus_bin start_time duration exit_code
    sqlplus_bin="$(oracle_core_get_binary sqlplus)"
    start_time=$(date +%s)

    set +e
    "${sqlplus_bin}" -s / as sysdba @"${sql_script}" "${output}"
    exit_code=$?
    set -e

    duration=$(($(date +%s) - start_time))
    rm -f "${sql_script}"

    if [[ ${exit_code} -eq 0 ]]; then
        # Count discovered items
        local df_cnt tf_cnt rl_cnt
        df_cnt=$(grep -c "^[0-9]" "${output}" 2>/dev/null | grep -v "^--" | head -1) || df_cnt=0
        report_track_item "ok" "Discovery Map" "Generated in ${duration}s"
        report_track_metric "rman_discovery_duration" "${duration}" "set"
        report_track_step_done 0 "Discovery map generated: ${output}"

        # Initialize transformation from the map
        oracle_rman_init_transformation "${output}"
    else
        report_track_item "fail" "Discovery Map" "Generation failed (exit ${exit_code})"
        report_track_step_done ${exit_code} "Failed to generate discovery map"
        die "Falha ao gerar mapa"
    fi
}

# Check RMAN log for errors that don't cause non-zero exit code
# Returns: 0 if no critical errors, 1 if errors found
# Note: Excludes expected warnings (RMAN-07517 for non-backup files, ORA-01917/01921 for grants)
_rman_check_log_errors() {
    local logfile="${1:?Missing logfile}"
    local errors

    if [[ ! -f "${logfile}" ]]; then
        warn "RMAN log file not found: ${logfile}"
        return 1
    fi

    # Check for RMAN and ORA errors (excluding expected ones)
    # RMAN-07517: File header corrupted (expected for non-backup files like .log)
    # RMAN-06169: could not read file header (expected during crosscheck for deleted backups)
    # ORA-01917/ORA-01921: User/role does not exist (expected for grants)
    errors=$(grep -E "^RMAN-[0-9]+:|^ORA-[0-9]+:" "${logfile}" 2>/dev/null \
        | grep -v "RMAN-07517" \
        | grep -v "RMAN-06169" \
        | grep -v "ORA-01917" \
        | grep -v "ORA-01921" \
        | head -10 || true)

    if [[ -n "${errors}" ]]; then
        log_error "[RMAN] Errors found in log:"
        echo "${errors}" | while read -r line; do
            log_error "  ${line}"
        done
        return 1
    fi

    return 0
}

oracle_rman_exec_verbose() {
    local cmdfile="${1?ERROR: Missing required parameter: cmdfile}"
    local logfile="${2?ERROR: Missing required parameter: logfile}"
    local desc="${3:-RMAN Operation}"

    rt_assert_file_exists "RMAN Script" "${cmdfile}"

    # Track operation
    report_track_step "Execute RMAN: ${desc}"
    report_track_meta "rman_cmdfile" "${cmdfile}"
    report_track_meta "rman_logfile" "${logfile}"

    log "[RMAN] ▶ Executing: ${desc}"

    local start dur rc
    start=$(date +%s)
    set +e
    rman target / cmdfile="${cmdfile}" log="${logfile}"
    rc=$?
    set -e

    dur=$(($(date +%s) - start))
    local dur_formatted
    dur_formatted=$(runtime_format_duration "${dur}")

    # Track result - check both exit code AND log content
    if [[ "${rc}" -eq 0 ]]; then
        # Check log for errors that RMAN might not have caught
        if _rman_check_log_errors "${logfile}"; then
            log_success "[OK] ${desc} concluido (${dur_formatted})"
            report_track_step_done 0 "RMAN completed in ${dur_formatted}"
            report_track_item "ok" "${desc}" "${dur_formatted}"
            report_track_metric "rman_execution_successful" "1" "add"
        else
            warn "[WARN] ${desc} completado com warnings (${dur_formatted})"
            warn "[WARN] Verifique o log: ${logfile}"
            report_track_step_done 0 "RMAN completed with warnings in ${dur_formatted}"
            report_track_item "ok" "${desc}" "${dur_formatted} (with warnings)"
            report_track_metric "rman_execution_warnings" "1" "add"
        fi
    else
        log_error "[FAIL] ${desc} falhou (exit=${rc}). Log: ${logfile}"
        report_track_step_done ${rc} "RMAN failed (exit ${rc})"
        report_track_item "fail" "${desc}" "exit ${rc}, log: ${logfile}"
        report_track_metric "rman_execution_failed" "1" "add"
    fi

    report_track_metric "rman_execution_duration_secs" "${dur}" "add"

    return "${rc}"
}

oracle_rman_write_cmdfile_run() {
    local file="$1"
    local dbid="${2:-}"
    local post="${3:-}"
    local body; body="$(cat)"
    {
        echo "set echo on;"
        if [[ -n "${dbid}" ]]; then echo "set dbid ${dbid};"; fi
        echo "run {"
        oracle_rman_channels_alloc
        echo "${body}"
        oracle_rman_channels_release
        echo "}"
        if [[ -n "${post}" ]]; then echo "${post}"; fi
    } > "${file}"
}

#===============================================================================
# SECTION 6: Summary & Previews
#===============================================================================

oracle_rman_print_discovery_summary() {
    if [[ ${#_RMAN_TRANS_KEYS[@]} -eq 0 ]]; then oracle_rman_init_transformation; fi
    
    local df=0 tf=0 rl=0
    for key in "${_RMAN_TRANS_KEYS[@]}"; do
        case "${_RMAN_TRANS_TYPE[$key]}" in
            "DF") ((df++)) || true ;;
            "TF") ((tf++)) || true ;;
            "RL") ((rl++)) || true ;;
        esac
    done

    echo
    echo "================================================================"
    echo "  DISCOVERY SUMMARY"
    echo "================================================================"
    report_kv "Datafiles" "${df}"
    report_kv "Tempfiles" "${tf}"
    report_kv "Redo Logs" "${rl}"
    echo "================================================================"
}

# Global variables for PITR window limits (set by oracle_rman_print_restore_options)
_RMAN_PITR_MIN=""
_RMAN_PITR_MAX=""
_RMAN_PITR_MIN_SCN=""
_RMAN_PITR_MAX_SCN=""

oracle_rman_print_restore_options() {
    echo
    echo "================================================================"
    echo "  RESTORE OPTIONS"
    echo "================================================================"
    report_kv "ORACLE_SID" "${ORACLE_SID:-}"
    report_kv "TARGET_DB" "${TARGET_DB_UNIQUE_NAME:-restore}"
    report_kv "DEST_TYPE" "${DEST_TYPE:-FS}"
    report_kv "DEST_BASE" "${DEST_BASE:-/restore}"
    report_kv "CHANNELS" "${RMAN_CHANNELS:-4}"

    # Show backup type and restore method
    local backup_desc=""
    case "${BACKUP_TYPE:-backupset}" in
        backupset)  backup_desc="Backup Sets (RESTORE DATABASE)" ;;
        imagecopy)  backup_desc="Image Copies (SWITCH TO COPY)" ;;
        both)       backup_desc="Both available (using Image Copy)" ;;
        *)          backup_desc="${BACKUP_TYPE:-unknown}" ;;
    esac
    report_kv "BACKUP_TYPE" "${backup_desc}"
    echo "================================================================"

    # Query restore window from catalog
    echo
    echo "================================================================"
    echo "  RESTORE WINDOW (Limites de Point-in-Time Recovery)"
    echo "================================================================"
    local window_data window_err=""
    # Capture both stdout and stderr, log errors for debugging
    if ! window_data=$(oracle_rman_get_restore_window 2>&1); then
        log_debug "Restore window query failed: ${window_data:-unknown error}"
        window_data=""
    fi
    # Filter out any error messages (keep only lines with pipe separators)
    window_data=$(echo "${window_data}" | grep -E '^(BKP_WINDOW|ARCH_WINDOW)\|' || true)

    local bkp_min="" bkp_max="" arch_min="" arch_max=""
    while IFS='|' read -r label min_time max_time; do
        case "${label}" in
            BKP_WINDOW)  bkp_min="${min_time}"; bkp_max="${max_time}" ;;
            ARCH_WINDOW) arch_min="${min_time}"; arch_max="${max_time}" ;;
        esac
    done <<< "${window_data}"

    if [[ -n "${bkp_min}" ]]; then
        report_kv "Backup Window" "${bkp_min} to ${bkp_max}"
    else
        report_kv "Backup Window" "(no backup datafiles cataloged)"
    fi

    if [[ -n "${arch_min}" ]]; then
        # Store limits in global variables for validation
        _RMAN_PITR_MIN="${arch_min}"
        _RMAN_PITR_MAX="${arch_max}"
        export _RMAN_PITR_MIN _RMAN_PITR_MAX

        echo "----------------------------------------------------------------"
        echo "  MÍNIMO (Earliest) : ${arch_min}"
        echo "  MÁXIMO (Latest)   : ${arch_max}"
        echo "----------------------------------------------------------------"
        echo
        echo "  Para Point-in-Time Recovery, use:"
        echo "    UNTIL_TIME='${arch_max}' ./restore.sh --resume-from=restore"
        echo
    else
        report_kv "Archive Window" "(no archived logs cataloged)"
        echo "----------------------------------------------------------------"
        echo "  AVISO: Sem archived logs catalogados, PITR não disponível"
        echo "----------------------------------------------------------------"
    fi
    echo "================================================================"
}

# oracle_rman_validate_pitr - Validate UNTIL_TIME/UNTIL_SCN against restore window
# Returns: 0 if valid, 1 if invalid
oracle_rman_validate_pitr() {
    local until_time="${UNTIL_TIME:-}"
    local until_scn="${UNTIL_SCN:-}"

    # No PITR requested - valid
    if [[ -z "${until_time}" && -z "${until_scn}" ]]; then
        return 0
    fi

    # Both specified - invalid
    if [[ -n "${until_time}" && -n "${until_scn}" ]]; then
        log_error "Cannot specify both UNTIL_TIME and UNTIL_SCN. Choose one."
        return 1
    fi

    # Validate UNTIL_TIME format (basic check)
    if [[ -n "${until_time}" ]]; then
        if ! [[ "${until_time}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}$ ]]; then
            log_error "Invalid UNTIL_TIME format: ${until_time}"
            log_error "Expected format: YYYY-MM-DD HH24:MI:SS (e.g., 2026-01-16 14:30:00)"
            return 1
        fi
        log_info "PITR requested: UNTIL_TIME='${until_time}'"

        # Check against limits if available
        if [[ -n "${_RMAN_PITR_MIN}" && -n "${_RMAN_PITR_MAX}" ]]; then
            # Simple string comparison works for YYYY-MM-DD HH:MI format
            local until_cmp="${until_time:0:16}"  # Trim seconds for comparison
            if [[ "${until_cmp}" < "${_RMAN_PITR_MIN}" ]]; then
                log_error "UNTIL_TIME '${until_time}' is BEFORE available window"
                log_error "Earliest available: ${_RMAN_PITR_MIN}"
                return 1
            fi
            if [[ "${until_cmp}" > "${_RMAN_PITR_MAX}" ]]; then
                log_error "UNTIL_TIME '${until_time}' is AFTER available window"
                log_error "Latest available: ${_RMAN_PITR_MAX}"
                return 1
            fi
            log_info "PITR time is within restore window: ${_RMAN_PITR_MIN} to ${_RMAN_PITR_MAX}"
        fi
    fi

    # Validate UNTIL_SCN (must be numeric)
    if [[ -n "${until_scn}" ]]; then
        if ! [[ "${until_scn}" =~ ^[0-9]+$ ]]; then
            log_error "Invalid UNTIL_SCN: ${until_scn} (must be numeric)"
            return 1
        fi
        log_info "PITR requested: UNTIL_SCN=${until_scn}"
    fi

    return 0
}

# oracle_rman_print_commands_preview - Display RMAN command file contents for user review
# Usage: oracle_rman_print_commands_preview "cmdfile" "description"
# Returns: 0 on success, 1 if file missing (with warning)
oracle_rman_print_commands_preview() {
    local cmdfile="${1:-}"
    local desc="${2:-RMAN Script}"
    local max_lines="${3:-50}"

    # Validate cmdfile parameter
    if [[ -z "${cmdfile}" ]]; then
        warn "[PREVIEW] ${desc}: No command file path provided"
        return 1
    fi

    # Check if file exists
    if [[ ! -f "${cmdfile}" ]]; then
        warn "[PREVIEW] ${desc}: Command file not found: ${cmdfile}"
        warn "[PREVIEW] ${desc}: Ensure the previous phase completed successfully"
        return 1
    fi

    echo
    echo "─────────────────────────────────────────────────────────────"
    echo "  FILE: ${cmdfile}"
    echo "  ${desc} (first ${max_lines} lines)"
    echo "─────────────────────────────────────────────────────────────"
    sed -n "1,${max_lines}p" "${cmdfile}" | cat -n
    echo "─────────────────────────────────────────────────────────────"
}

oracle_rman_generate_post_restore_sql() {
    local file="$1"
    {
        echo "-- Post-Restore SQL (Auto-generated)"
        echo "-- Order: Rename files (MOUNT) -> OPEN RESETLOGS"
        echo "set echo on serveroutput on;"
        echo ""
        echo "-- Step 1: Rename redo logs (database must be MOUNT)"
        oracle_rman_build_redo_rename
        echo ""
        echo "-- Step 2: Rename tempfiles (database must be MOUNT)"
        oracle_rman_build_tempfile_rename
        echo ""
        echo "-- Step 3: Open database with RESETLOGS"
        echo "alter database open resetlogs;"
        echo ""
        echo "exit;"
    } > "${file}"
}

# oracle_rman_print_post_restore_sql_preview - Display post-restore SQL for user review
# Usage: oracle_rman_print_post_restore_sql_preview "sqlfile"
# Returns: 0 on success, 1 if file missing (with warning)
oracle_rman_print_post_restore_sql_preview() {
    local file="${1:-}"

    # Validate file parameter
    if [[ -z "${file}" ]]; then
        warn "[PREVIEW] Post-Restore SQL: No file path provided"
        return 1
    fi

    # Check if file exists
    if [[ ! -f "${file}" ]]; then
        warn "[PREVIEW] Post-Restore SQL: File not found: ${file}"
        warn "[PREVIEW] Post-Restore SQL: Ensure command files were generated"
        return 1
    fi

    echo
    echo "─────────────────────────────────────────────────────────────"
    echo "  FILE: ${file}"
    echo "  Post-Restore SQL Commands (first 50 lines)"
    echo "─────────────────────────────────────────────────────────────"
    if [[ -f "${file}" ]]; then
        sed -n "1,50p" "${file}" | cat -n
    else
        echo "  (file does not exist)"
    fi
    echo "─────────────────────────────────────────────────────────────"
}

#===============================================================================
# SECTION 7: Reports & Window
#===============================================================================

oracle_rman_get_restore_window() {
    _rman_ensure_mounted
    # Query restore window from multiple sources to handle both:
    # 1. RMAN backup sets (V$BACKUP_SET, V$BACKUP_REDOLOG)
    # 2. Image copies / cataloged files (V$DATAFILE_COPY, V$ARCHIVED_LOG)
    #
    # BKP_WINDOW: Use V$BACKUP_SET for backup sets, V$DATAFILE_COPY for image copies
    # ARCH_WINDOW: Use V$ARCHIVED_LOG for cataloged archivelogs (image copies)
    #              Fall back to V$BACKUP_REDOLOG for archivelogs in backup sets
    oracle_sql_sysdba_query "
        -- Backup window: combine backup sets and datafile copies
        SELECT 'BKP_WINDOW|'||TO_CHAR(MIN(min_time),'YYYY-MM-DD HH24:MI')||'|'||TO_CHAR(MAX(max_time),'YYYY-MM-DD HH24:MI')
        FROM (
            SELECT MIN(start_time) min_time, MAX(completion_time) max_time FROM v\$backup_set WHERE backup_type IN ('D','I')
            UNION ALL
            SELECT MIN(creation_time) min_time, MAX(creation_time) max_time FROM v\$datafile_copy WHERE status='A'
        );
        -- Archive window: prefer V\$ARCHIVED_LOG (image copies), fallback to V\$BACKUP_REDOLOG (backup sets)
        SELECT 'ARCH_WINDOW|'||TO_CHAR(MIN(first_time),'YYYY-MM-DD HH24:MI')||'|'||TO_CHAR(MAX(next_time),'YYYY-MM-DD HH24:MI')
        FROM (
            SELECT first_time, next_time FROM v\$archived_log WHERE status='A' AND name IS NOT NULL
            UNION ALL
            SELECT first_time, next_time FROM v\$backup_redolog
        );
    "
}

oracle_rman_print_transformation_plan() {
    if [[ ${#_RMAN_TRANS_KEYS[@]} -eq 0 ]]; then oracle_rman_init_transformation; fi
    log_block_start "TRANSFORMATION PLAN"
    printf "  %-4s | %-10s | %-40s -> %s\n" "ID" "TYPE" "SOURCE" "DESTINATION"
    echo "  ------------------------------------------------------------------------------------------------"
    for key in "${_RMAN_TRANS_KEYS[@]}"; do
        local id="${key%|*}" type="${_RMAN_TRANS_TYPE[$key]}"
        printf "  %-4s | %-10s | %-40s -> %s\n" "${id}" "${type}" "${_RMAN_TRANS_SRC[$key]}" "${_RMAN_TRANS_DST[$key]}"
    done
    log_block_end "TRANSFORMATION PLAN"
}

#===============================================================================
# SECTION 10: Execution State Management
#===============================================================================
# PURPOSE:
#   Tracks execution state across DRY_RUN levels to enable intelligent step skipping.
#   State is persisted to ${LOGDIR}/execution_state.sh so that:
#   - DRY_RUN=1: Validates (preview/validate) and saves state
#   - DRY_RUN=0: Loads state and skips already-validated steps
#
# CASE DE USO PRINCIPAL:
#   1. User executes: DRY_RUN=1 ./restore.sh
#      → Executa preview/validate, salva estado, para antes do restore
#   2. User verifica logs e decide prosseguir
#   3. User executes: DRY_RUN=0 ./restore.sh
#      → Carrega estado, pula preview/validate, executa restore/recover
#
# EDGE CASES TRATADOS:
#   - Estado corrompido: _rman_state_load retorna 1, continua sem estado
#   - Concorrência: grep/mv atômico para evitar conflitos (best-effort)
#   - Falhas parciais: COMPLETED=0 quando step falha, permite retry
#
# PERFORMANCE:
#   - State file: ~200 bytes por step (5 variáveis × 8 bytes × 5 steps)
#   - Load: O(1) via source
#   - Write: O(n) onde n = número de keys (tipicamente < 50)
#   - Get: O(n) via grep (n = linhas no arquivo)
#===============================================================================

# _rman_state_file - Get path to execution state file
#
# Returns: Path to state file (${LOGDIR}/execution_state.sh or /tmp/execution_state.sh)
#
# Usage:
#   local state_file
#   state_file=$(_rman_state_file)
#
# Notes:
#   - Uses LOGDIR if defined (from session_init)
#   - Falls back to /tmp if LOGDIR not set
#   - File format: bash source-able (key="value" per line)
_rman_state_file() {
    # State no diretório pai (por SID) se LOGDIR tem subdir de sessão
    local base="${LOGDIR:-/tmp}"
    # Se LOGDIR termina com /YYYYMMDD_HHMMSS, usa o pai
    if [[ "${base}" =~ /[0-9]{8}_[0-9]{6}$ ]]; then
        base="${base%/*}"
    fi
    echo "${base}/execution_state.sh"
}

# _rman_state_load - Load previous execution state
#
# Returns:
#   0: State file exists and was sourced successfully
#   1: State file doesn't exist (first run) OR source failed (corrupted)
#
# Usage:
#   if _rman_state_load; then
#       echo "State loaded - can skip completed steps"
#   else
#       echo "No previous state - will execute all steps"
#   fi
#
# Notes:
#   - Uses bash 'source' to load variables
#   - Tolerates missing file (first run)
#   - Tolerates corrupted file (source returns 1)
#   - Caller should continue execution on failure (graceful degradation)
_rman_state_load() {
    local state_file
    state_file=$(_rman_state_file)
    if [[ -f "${state_file}" ]]; then
        # shellcheck source=/dev/null
        source "${state_file}"
        log_debug "Loaded execution state from: ${state_file}"
        return 0
    fi
    return 1
}

# _rman_state_set - Set a state variable
#
# Arguments:
#   key   - Variable name (e.g., "PREVIEW_COMPLETED")
#   value - Variable value (string, quoted in file)
#
# Usage:
#   _rman_state_set "PREVIEW_COMPLETED" "1"
#   _rman_state_set "PREVIEW_LOG" "/tmp/preview.log"
#
# Behavior:
#   1. Creates state file if doesn't exist
#   2. Removes old key if exists (prevents duplicates)
#   3. Appends new key="value" line
#
# Concurrency:
#   Uses grep → mv → append pattern (best-effort atomic)
#   NOT fully safe for concurrent writes from multiple processes
#   Recommend using lock file if concurrent execution expected
#
# Notes:
#   - Empty values are allowed
#   - Values are double-quoted in file (bash source-safe)
#   - Old value is completely replaced (not merged)
_rman_state_set() {
    local key="${1?ERROR: _rman_state_set requires key}"
    local value="${2:-}"
    local state_file
    state_file=$(_rman_state_file)

    # Create file if not exists
    [[ -f "${state_file}" ]] || echo "# RMAN Execution State - $(date)" > "${state_file}"

    # Remove existing key if present (grep -v returns 1 if no lines remain)
    if grep -q "^${key}=" "${state_file}" 2>/dev/null; then
        grep -v "^${key}=" "${state_file}" > "${state_file}.tmp" || true
        mv "${state_file}.tmp" "${state_file}"
    fi

    # Append new value
    echo "${key}=\"${value}\"" >> "${state_file}"
    log_debug "State set: ${key}=${value}"
}

# _rman_state_get - Get a state variable
#
# Arguments:
#   key     - Variable name to retrieve
#   default - Default value if key not found (optional)
#
# Returns:
#   - Value of key if exists
#   - Default value if key not found
#   - Empty string if key not found and no default
#
# Usage:
#   local log_path
#   log_path=$(_rman_state_get "PREVIEW_LOG" "/tmp/default.log")
#
#   local completed
#   completed=$(_rman_state_get "PREVIEW_COMPLETED" "0")
#
# Notes:
#   - Uses grep + head -1 (first match if duplicates)
#   - Extracts value between double quotes (cut -d'"' -f2)
#   - Tolerates missing state file (returns default)
#   - Performance: O(n) where n = lines in state file
_rman_state_get() {
    local key="${1?ERROR: _rman_state_get requires key}"
    local default="${2:-}"
    local state_file
    state_file=$(_rman_state_file)

    if [[ -f "${state_file}" ]]; then
        local value
        value=$(grep "^${key}=" "${state_file}" 2>/dev/null | head -1 | cut -d'"' -f2)
        echo "${value:-${default}}"
    else
        echo "${default}"
    fi
}

# _rman_state_step_completed - Check if a step completed successfully
#
# Arguments:
#   step - Step name (e.g., "PREVIEW", "VALIDATE", "RESTORE")
#
# Returns:
#   0 (true):  Step completed successfully (STEP_COMPLETED=1)
#   1 (false): Step not completed or never executed
#
# Usage:
#   if _rman_state_step_completed "PREVIEW"; then
#       echo "Preview já executado, pode pular"
#   else
#       echo "Preview precisa ser executado"
#   fi
#
# Notes:
#   - Checks {STEP}_COMPLETED variable
#   - Value "1" means success, any other value means incomplete
#   - Used by oracle_rman_exec_with_state for skip logic
_rman_state_step_completed() {
    local step="${1?ERROR: _rman_state_step_completed requires step name}"
    local completed
    completed=$(_rman_state_get "${step}_COMPLETED" "0")
    [[ "${completed}" == "1" ]]
}

#===============================================================================
# SECTION 11: Unified RMAN Execution with State
#===============================================================================

# oracle_rman_exec_with_state - Execute RMAN with state tracking
#
# PURPOSE:
#   Unified RMAN execution function that handles:
#   - Automatic skip of completed steps (DRY_RUN=1 → DRY_RUN=0)
#   - Command file preview before execution
#   - User confirmation (respects AUTO_YES)
#   - State persistence after success/failure
#
# SIGNATURE:
#   oracle_rman_exec_with_state "STEP_NAME" cmdfile logfile "description" [--skip-if-done] [--force]
#
# ARGUMENTS:
#   STEP_NAME   - State key (PREVIEW, VALIDATE, CROSSCHECK, CATALOG, RESTORE, RECOVER)
#   cmdfile     - Path to RMAN command file (.rcv)
#   logfile     - Path to RMAN log file (.log)
#   description - Human-readable description (shown in prompts/logs)
#   --skip-if-done - Skip if already completed (default behavior)
#   --force     - Force re-execution even if completed (for destructive ops)
#
# BEHAVIOR:
#   1. Check if step already completed (skip automático, exceto se --force)
#   2. Validate cmdfile exists
#   3. Show command file preview (via show_file)
#   4. Request confirmation via report_confirm (respects AUTO_YES)
#   5. Execute RMAN command via oracle_rman_exec_verbose
#   6. Update state file:
#      - Success: STEP_COMPLETED=1, EXIT_CODE=0, LOG=logfile, DURATION=seconds
#      - Failure: STEP_COMPLETED=0, EXIT_CODE=rc
#
# SKIP LOGIC:
#   - DRY_RUN=1 executes PREVIEW/VALIDATE, saves COMPLETED=1
#   - DRY_RUN=0 checks COMPLETED=1, skips execution
#   - RESTORE/RECOVER always use --force (never skip)
#
# EXAMPLE USAGE:
#   # Preview with automatic skip
#   oracle_rman_exec_with_state "PREVIEW" "${RMAN_PRE}" "${LOGDIR}/03_preview.log" "Restore Preview"
#
#   # Restore always executes (--force overrides skip)
#   oracle_rman_exec_with_state "RESTORE" "${RMAN_RES}" "${LOGDIR}/05_restore.log" "RESTORE DATABASE" --force
#
# AUTO_YES INTEGRATION:
#   - Respects REPORT_AUTO_YES environment variable
#   - AUTO_YES=1: skips confirmation, executes immediately
#   - AUTO_YES=0: prompts user for confirmation
#
oracle_rman_exec_with_state() {
    local step_name="${1?ERROR: oracle_rman_exec_with_state requires step name}"
    local cmdfile="${2?ERROR: oracle_rman_exec_with_state requires cmdfile}"
    local logfile="${3?ERROR: oracle_rman_exec_with_state requires logfile}"
    local desc="${4:-RMAN Operation}"
    shift 4

    local skip_if_done=1 force=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --skip-if-done) skip_if_done=1 ;;
            --force) force=1; skip_if_done=0 ;;
            *) break ;;
        esac
        shift
    done

    # Check if already completed (unless --force)
    if [[ ${skip_if_done} -eq 1 && ${force} -eq 0 ]]; then
        if _rman_state_step_completed "${step_name}"; then
            local prev_log
            prev_log=$(_rman_state_get "${step_name}_LOG")
            log_info "[SKIP] ${desc}: Already completed (log: ${prev_log})"
            report_item "skip" "${desc}" "Already completed in previous run" 2>/dev/null || true
            return 0
        fi
    fi

    # Validate cmdfile exists
    rt_assert_file_exists "RMAN Script (${step_name})" "${cmdfile}"

    # Preview
    log "[PREVIEW] File: ${cmdfile}"
    show_file "${cmdfile}" 200

    # Confirm (respects REPORT_AUTO_YES)
    if ! report_confirm "Executar ${desc}?" "YES"; then
        warn "Execucao cancelada pelo usuario"
        return 1
    fi

    # Execute
    local rc start_time duration
    start_time=$(date +%s)

    set +e
    oracle_rman_exec_verbose "${cmdfile}" "${logfile}" "${desc}"
    rc=$?
    set -e

    duration=$(($(date +%s) - start_time))

    # Update state
    if [[ ${rc} -eq 0 ]]; then
        _rman_state_set "${step_name}_COMPLETED" "1"
        _rman_state_set "${step_name}_LOG" "${logfile}"
        _rman_state_set "${step_name}_EXIT_CODE" "0"
        _rman_state_set "${step_name}_DURATION" "${duration}"
        _rman_state_set "${step_name}_TIMESTAMP" "$(date +%s)"
        log_debug "State updated: ${step_name} completed in ${duration}s"
    else
        _rman_state_set "${step_name}_COMPLETED" "0"
        _rman_state_set "${step_name}_EXIT_CODE" "${rc}"
        _rman_state_set "${step_name}_TIMESTAMP" "$(date +%s)"
    fi

    return ${rc}
}

#===============================================================================
# SECTION 12: Catalog Divergence Detection
#===============================================================================

# oracle_rman_check_catalog_divergence - Check if catalog may need refresh
#
# PURPOSE:
#   Detects if RMAN catalog may be stale and needs re-crosscheck.
#   Used to offer optional catalog refresh before preview/validate.
#
# RETURNS:
#   0 (no divergence):  Catalog is current, no re-crosscheck needed
#   1 (divergence):     Catalog may be stale, re-crosscheck recommended
#
# CHECKS PERFORMED:
#   1. First run check:
#      - No previous CROSSCHECK_TIMESTAMP → return 0 (no state to compare)
#      - Phase C crosscheck will run normally anyway
#
#   2. Staleness check:
#      - CROSSCHECK_TIMESTAMP > 1 hour old → return 1 (suggest re-crosscheck)
#      - Threshold: 3600 seconds (1 hour)
#
#   3. Archivelog drift check:
#      - More archivelogs on disk than in catalog → return 1
#      - Compares: find ${FRA_DIR}/archivelog vs _RMAN_CATALOG_ARCHIVELOG_COUNT
#
# INTEGRATION:
#   Called by phase_validate_and_restore() in restore.sh:
#     if ! oracle_rman_check_catalog_divergence; then
#         if report_confirm "Catalog may be stale. Re-run crosscheck?" "YES"; then
#             oracle_rman_exec_with_state "CROSSCHECK" ... --force
#         fi
#     fi
#
# EXAMPLE SCENARIOS:
#   Scenario 1: First run (no previous state)
#     → Returns 0 (no divergence, Phase C crosscheck runs normally)
#
#   Scenario 2: Crosscheck 30 minutes ago
#     → Returns 0 (recent, catalog is current)
#
#   Scenario 3: Crosscheck 3 hours ago
#     → Returns 1 (stale, offers re-crosscheck)
#
#   Scenario 4: 100 archivelogs on disk, 50 in catalog
#     → Returns 1 (drift detected, offers re-crosscheck)
#
# NOTES:
#   - Conservative: first run returns "no divergence" to avoid unnecessary prompt
#   - Threshold of 1 hour is arbitrary but reasonable for most use cases
#   - Archivelog drift check requires FRA_DIR to be set
#   - Does not force re-crosscheck, only suggests (user can decline)
#
oracle_rman_check_catalog_divergence() {
    local last_crosscheck_time
    last_crosscheck_time=$(_rman_state_get "CROSSCHECK_TIMESTAMP" "0")

    # First run: no previous crosscheck, so no divergence to check
    # The normal Phase C crosscheck will run anyway
    if [[ "${last_crosscheck_time}" == "0" ]]; then
        log_debug "First run - no previous crosscheck to compare"
        return 0
    fi

    local current_time
    current_time=$(date +%s)

    # If crosscheck was more than 1 hour ago, suggest re-run
    local max_age=3600
    if [[ $((current_time - last_crosscheck_time)) -gt ${max_age} ]]; then
        log_debug "Crosscheck is stale (>1h since last run: $((current_time - last_crosscheck_time))s)"
        return 1
    fi

    # Check if there are new archivelogs on disk not in catalog
    local arch_dest
    arch_dest="${FRA_DIR:-/restore/fast_recovery_area}/${ORACLE_SID:-}/archivelog"

    if [[ -d "${arch_dest}" ]]; then
        local disk_count catalog_count
        disk_count=$(find "${arch_dest}" -type f \( -name "*.arc" -o -name "*.dbf" \) 2>/dev/null | wc -l)
        catalog_count="${_RMAN_CATALOG_ARCHIVELOG_COUNT:-0}"

        if [[ ${disk_count} -gt ${catalog_count} ]]; then
            log_debug "More archivelogs on disk (${disk_count}) than in catalog (${catalog_count})"
            return 1
        fi
    fi

    log_debug "Catalog appears current (crosscheck age: $((current_time - last_crosscheck_time))s)"
    return 0
}

