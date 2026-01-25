#!/usr/bin/env bash
# shellcheck shell=bash
#===============================================================================
# Datacosmos - Oracle Configuration Module
#
# Copyright (c) 2026 Datacosmos
# Licensed under the Apache License, Version 2.0
#===============================================================================
# File    : oracle_config.sh
# Version : 1.1.0
# Date    : 2026-01-15
#===============================================================================
#
# DESCRIPTION:
#   Oracle database configuration management: PFILE operations, memory sizing,
#   filesystem operations, and path resolution. Uses runtime.sh functions for
#   robust file and filesystem handling.
#
# DEPENDS ON:
#   - oracle_core.sh (base Oracle functionality)
#   - runtime.sh (filesystem utilities: runtime_fs_*, runtime_ensure_dir, runtime_backup_file)
#   - logging.sh (logging functions)
#
# PROVIDES:
#   PFILE Operations:
#     - oracle_config_pfile_parse_param()    - Parse parameter from PFILE
#     - oracle_config_pfile_parse_db_name()  - Parse db_name from PFILE
#     - oracle_config_pfile_write_bootstrap()- Write bootstrap PFILE
#     - oracle_config_pfile_sanitize()       - Sanitize PFILE for restore
#
#   Memory Sizing:
#     - oracle_config_calc_memory()          - Calculate SGA/PGA from system memory
#     - oracle_config_validate_mem_value()   - Validate memory value format
#
#   Filesystem Operations:
#     - runtime_fs_available_gb()            - Get available space (via runtime.sh)
#     - oracle_config_space_check()          - Check space requirements
#     - oracle_config_estimate_db_size()     - Estimate DB size from controlfile
#
#   Path Management:
#     - oracle_config_resolve_paths()        - Resolve destination paths
#     - oracle_config_create_dirs()          - Create required directories
#
#   Wallet Management:
#     - oracle_config_wallet_create()        - Create Oracle Wallet from credentials
#     - oracle_config_wallet_create_from_keyring() - Create wallet from keyring env
#     - oracle_config_wallet_create_all()    - Create wallets for all keyring envs
#     - oracle_config_wallet_delete()        - Remove wallet directory
#     - oracle_config_wallet_list()          - List existing wallets
#
# REPORT INTEGRATION:
#   This module integrates with report.sh for configuration tracking:
#   - Tracked Steps: Space checking, path resolution, directory creation, PFILE sanitization
#   - Tracked Metrics: config_db_size_gb, config_paths_resolved, config_dirs_created
#   - Tracked Metadata: config_db_size_gb, config_required_gb, config_available_gb
#   - Tracked Items: Each directory created and path transformation
#   - Integration is graceful (NO-OP without report_init)
#   - All metrics have config_ prefix for pattern-based aggregation
#
#===============================================================================

# Prevent double sourcing
[[ -n "${__ORACLE_CONFIG_LOADED:-}" ]] && return 0
__ORACLE_CONFIG_LOADED=1

# Resolve library directory
_ORACLE_CONFIG_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load oracle_core.sh (provides oracle_core_* functions)
# shellcheck source=/dev/null
[[ -z "${__ORACLE_CORE_LOADED:-}" ]] && source "${_ORACLE_CONFIG_LIB_DIR}/oracle_core.sh"

# Load runtime.sh (provides runtime_fs_*, runtime_ensure_dir, runtime_backup_file)
# shellcheck source=/dev/null
[[ -z "${__RUNTIME_LOADED:-}" ]] && source "${_ORACLE_CONFIG_LIB_DIR}/runtime.sh"

#===============================================================================
# SECTION 1: Memory Value Validation
#===============================================================================

# oracle_config_validate_mem_value - Validate memory value format
# Usage: oracle_config_validate_mem_value "4G"
# Valid formats: 4G, 4096M, 4194304K, 4294967296 (bytes)
oracle_config_validate_mem_value() {
    local val="$1"
    if [[ ! "${val}" =~ ^[0-9]+[GMKgmk]?$ ]]; then
        die "Formato de memoria invalido: ${val} (use: 4G, 4096M, 4294967296)"
    fi
}

# oracle_config_mem_to_bytes - Convert memory value to bytes
# Usage: bytes=$(oracle_config_mem_to_bytes "4G")
oracle_config_mem_to_bytes() {
    local val="$1"
    local num="${val%[GMKgmk]}"
    local unit="${val: -1}"
    
    case "${unit}" in
        G|g) echo $((num * 1024 * 1024 * 1024)) ;;
        M|m) echo $((num * 1024 * 1024)) ;;
        K|k) echo $((num * 1024)) ;;
        *)   echo "${val}" ;;
    esac
}

# oracle_config_bytes_to_human - Convert bytes to human readable
# Usage: human=$(oracle_config_bytes_to_human 4294967296)
oracle_config_bytes_to_human() {
    local bytes="$1"
    local gb=$((bytes / 1024 / 1024 / 1024))
    local mb=$((bytes / 1024 / 1024))
    
    if [[ ${gb} -gt 0 ]]; then
        echo "${gb}G"
    elif [[ ${mb} -gt 0 ]]; then
        echo "${mb}M"
    else
        echo "${bytes}"
    fi
}

#===============================================================================
# SECTION 2: Memory Sizing
#===============================================================================

# oracle_config_calc_memory - Calculate SGA/PGA based on available memory
# Usage: read -r sga pga < <(oracle_config_calc_memory [sga_override] [pga_override] [sga_percent] [pga_percent] [min_avail_gb])
# Parameters (all optional):
#   sga_override  - Override SGA value (e.g., "12G") - if set, uses this and pga_override
#   pga_override  - Override PGA value (e.g., "4G")
#   sga_percent   - SGA percentage of available memory (default: 45)
#   pga_percent   - PGA percentage of available memory (default: 20)
#   min_avail_gb  - Minimum available memory required in GB (default: 4)
# Returns: "SGA PGA" on stdout (e.g., "4G 2G")
# Note: All log output goes to stderr to keep stdout clean for return values
# Example:
#   # Auto-calculate from system memory
#   read -r sga pga < <(oracle_config_calc_memory)
#   # Use overrides
#   read -r sga pga < <(oracle_config_calc_memory "12G" "4G")
#   # Custom percentages
#   read -r sga pga < <(oracle_config_calc_memory "" "" 50 25)
oracle_config_calc_memory() {
    local sga_override="${1:-}"
    local pga_override="${2:-}"
    local sga_percent="${3:-45}"
    local pga_percent="${4:-20}"
    local min_avail_gb="${5:-4}"

    # Validate percentage inputs
    if [[ -n "${sga_percent}" ]] && ! [[ "${sga_percent}" =~ ^[0-9]+$ ]]; then
        die "sga_percent must be a positive integer: ${sga_percent}"
    fi
    if [[ -n "${pga_percent}" ]] && ! [[ "${pga_percent}" =~ ^[0-9]+$ ]]; then
        die "pga_percent must be a positive integer: ${pga_percent}"
    fi
    if [[ -n "${min_avail_gb}" ]] && ! [[ "${min_avail_gb}" =~ ^[0-9]+$ ]]; then
        die "min_avail_gb must be a positive integer: ${min_avail_gb}"
    fi
    
    # Warn if percentages exceed 100%
    local total_percent=$((sga_percent + pga_percent))
    if [[ "${total_percent}" -gt 100 ]]; then
        log_debug "[WARN] SGA (${sga_percent}%) + PGA (${pga_percent}%) = ${total_percent}% exceeds 100%" >&2
    fi

    log_debug "[SIZING] Calculating memory targets" >&2

    # Check for overrides
    if [[ -n "${sga_override}" && -n "${pga_override}" ]]; then
        oracle_config_validate_mem_value "${sga_override}"
        oracle_config_validate_mem_value "${pga_override}"
        log_debug "[SIZING] Using provided values: SGA=${sga_override} PGA=${pga_override}" >&2
        printf "%s %s\n" "${sga_override}" "${pga_override}"
        return 0
    fi

    # Fallback to environment variables
    if [[ -n "${SGA_TARGET:-}" && -n "${PGA_TARGET:-}" ]]; then
        log_debug "[SIZING] Using environment overrides: SGA=${SGA_TARGET} PGA=${PGA_TARGET}" >&2
        printf "%s %s\n" "${SGA_TARGET}" "${PGA_TARGET}"
        return 0
    fi

    log_debug "[CHECK] Reading available memory" >&2
    local avail_gb sga_gb pga_gb
    # Handle both English "Mem:" and Portuguese "Mem.:" locales
    avail_gb="$(free -b | awk '/^Mem[.:]/ {print int($7/1024/1024/1024)}')"
    log_debug "[MEM] Available: ${avail_gb}GB" >&2

    [[ "${avail_gb}" -ge ${min_avail_gb} ]] || die "Memoria insuficiente (${avail_gb}G < ${min_avail_gb}G)."

    sga_gb=$(( avail_gb * sga_percent / 100 ))
    pga_gb=$(( avail_gb * pga_percent / 100 ))
    (( sga_gb < 2 )) && sga_gb=2
    (( pga_gb < 1 )) && pga_gb=1

    log_debug "[SIZING] Calculated: SGA=${sga_gb}G (${sga_percent}%), PGA=${pga_gb}G (${pga_percent}%)" >&2
    printf "%sG %sG\n" "${sga_gb}" "${pga_gb}"
}

# Alias for backward compatibility
calc_sga_pga() { oracle_config_calc_memory "$@"; }

#===============================================================================
# SECTION 3: Filesystem Operations
#===============================================================================

# oracle_config_estimate_db_size - Estimate DB size from controlfile
# Usage: size=$(oracle_config_estimate_db_size)
# Note: Requires oracle_sql.sh to be loaded for oracle_sql_sysdba_query
oracle_config_estimate_db_size() {
    log_debug "[SQL] Estimating DB size: SELECT CEIL(SUM(bytes)/1024/1024/1024) FROM V\$DATAFILE"

    # Check if oracle_sql_sysdba_query is available
    if ! declare -f oracle_sql_sysdba_query >/dev/null 2>&1; then
        warn "oracle_sql_sysdba_query not available, cannot estimate DB size"
        return 1
    fi

    oracle_sql_sysdba_query "select ceil(sum(bytes)/1024/1024/1024) from v\$datafile;"
}

# oracle_config_space_check - Verify sufficient space for database operations
# Usage: oracle_config_space_check <dest_path> [margin_percent] [db_size_gb] [extra_gb]
# Parameters:
#   dest_path      - Destination directory to check
#   margin_percent - Margin percentage (default: 20)
#   db_size_gb     - Database size in GB (optional, will query if not provided)
#   extra_gb       - Extra space required in GB (default: 20)
# Returns: 0 if sufficient space, dies if insufficient
# Example:
#   # Auto-detect DB size from controlfile
#   oracle_config_space_check "/restore/oradata/DB" 20
#   # Provide DB size explicitly
#   oracle_config_space_check "/restore/oradata/DB" 20 100
oracle_config_space_check() {
    local dest="$1"
    local margin="${2:-20}"
    local db_size_gb="${3:-}"
    local extra_gb="${4:-20}"
    local db_gb need_gb avail_gb

    # Track operation
    report_track_step "Check filesystem space requirements"
    report_track_meta "config_dest_path" "${dest}"
    report_track_meta "config_margin_percent" "${margin}"
    report_track_meta "config_extra_gb" "${extra_gb}"

    # Validate inputs
    rt_assert_nonempty "dest_path" "${dest}"
    rt_assert_uint "margin_percent" "${margin}"
    rt_assert_uint "extra_gb" "${extra_gb}"

    # Validate margin is reasonable (0-100%)
    if [[ "${margin}" -gt 100 ]]; then
        warn "Margin percentage ${margin}% is unusually high, using 100%"
        margin=100
    fi

    log "[SPACE] Checking destination: ${dest}"

    # Get DB size if not provided
    if [[ -z "${db_size_gb}" ]]; then
        local db_size_output
        db_size_output="$(oracle_config_estimate_db_size | tr -d '[:space:]' | tail -n 1)"
        if [[ "${db_size_output}" =~ ^[0-9]+$ ]]; then
            db_gb="${db_size_output}"
        else
            die "Falha ao estimar tamanho DB."
        fi
    else
        db_gb="${db_size_gb}"
    fi

    need_gb=$(( db_gb + (db_gb * margin / 100) + extra_gb ))
    avail_gb="$(runtime_fs_available_gb "${dest}")"

    log "[SPACE] DB size: ~${db_gb}GB"
    log "[SPACE] Required (${margin}% margin + ${extra_gb}GB): ${need_gb}GB"
    log "[SPACE] Available: ${avail_gb}GB"

    # Track metrics
    report_track_metric "config_db_size_gb" "${db_gb}" "set"
    report_track_metric "config_required_gb" "${need_gb}" "set"
    report_track_metric "config_available_gb" "${avail_gb}" "set"

    if (( avail_gb >= need_gb )); then
        log "[OK] Sufficient space available"
        report_track_item "ok" "Space Check" "${avail_gb}GB available (need ${need_gb}GB)"
        report_track_step_done 0 "Space check passed"
        return 0
    else
        report_track_item "fail" "Space Check" "${avail_gb}GB < ${need_gb}GB"
        report_track_step_done 1 "Insufficient space"
        die "Espaco insuficiente: ${avail_gb}GB < ${need_gb}GB"
    fi
}

# Alias for backward compatibility
oracle_space_check() { oracle_config_space_check "$@"; }

#===============================================================================
# SECTION 4: Path Management
#===============================================================================

# oracle_config_resolve_paths - Resolve destination paths for database operations
# Usage: oracle_config_resolve_paths <dest_type> <dest_base> <db_unique_name> [data_dg] [fra_dg] [output_prefix]
# Parameters:
#   dest_type      - Destination type: "FS" or "ASM"
#   dest_base      - Base directory for filesystem destinations
#   db_unique_name - Database unique name
#   data_dg        - Data diskgroup (for ASM) or data directory path (for FS) (default: "+DATA" for ASM)
#   fra_dg         - FRA diskgroup (for ASM) or FRA directory path (for FS) (default: "+RECO" for ASM)
#   output_prefix  - Optional prefix for output variables (default: "" - sets ADMIN_DIR, DATA_DIR, etc.)
# Sets (or exports with prefix): ADMIN_DIR, DATA_DIR, FRA_DIR, CONTROL_DIR
oracle_config_resolve_paths() {
    local dest_type="$1" dest_base="$2" db_unique_name="$3"
    local data_dg="${4:-+DATA}" fra_dg="${5:-+RECO}"
    local prefix="${6:-}"

    # Track operation
    report_track_step "Resolve database paths"
    report_track_meta "config_dest_type" "${dest_type}"
    report_track_meta "config_dest_base" "${dest_base}"
    report_track_meta "config_db_unique_name" "${db_unique_name}"

    rt_assert_nonempty "dest_type" "${dest_type}"
    rt_assert_nonempty "dest_base" "${dest_base}"
    rt_assert_nonempty "db_unique_name" "${db_unique_name}"
    rt_assert_enum "dest_type" "${dest_type}" "FS" "ASM"

    log_debug "[PATHS] Resolving destination paths"
    log_debug "[PARAM] DEST_TYPE=${dest_type}, DEST_BASE=${dest_base}, DB_UNIQUE_NAME=${db_unique_name}"

    local admin_dir data_dir fra_dir control_dir

    admin_dir="${dest_base}/admin/${db_unique_name}/adump"

    if [[ "${dest_type}" == "FS" ]]; then
        # For FS, check if provided paths are ASM defaults (start with +) or actual FS paths
        if [[ "${data_dg}" =~ ^\+ ]]; then
            # ASM default provided, derive FS paths from dest_base
            data_dir="${dest_base}/oradata/${db_unique_name}"
            fra_dir="${dest_base}/fra/${db_unique_name}"
        else
            # Custom FS paths provided
            data_dir="${data_dg}"
            fra_dir="${fra_dg}"
        fi
        control_dir="${data_dir}"
        log_debug "[PATH] ADMIN_DIR=${admin_dir}"
        log_debug "[PATH] DATA_DIR=${data_dir}"
        log_debug "[PATH] FRA_DIR=${fra_dir}"
        log_debug "[PATH] CONTROL_DIR=${control_dir}"
        report_track_item "ok" "Path Resolution" "FS: admin=${admin_dir}, data=${data_dir}, fra=${fra_dir}"
    else
        # For ASM, control files go to filesystem, data/FRA to diskgroups
        control_dir="${dest_base}/oradata/${db_unique_name}"
        data_dir="${data_dg}"
        fra_dir="${fra_dg}"
        log_debug "[PATH] ADMIN_DIR=${admin_dir}"
        log_debug "[PATH] CONTROL_DIR=${control_dir}"
        log_debug "[PATH] DATA_DG=${data_dir}"
        log_debug "[PATH] FRA_DG=${fra_dir}"
        report_track_item "ok" "Path Resolution" "ASM: admin=${admin_dir}, control=${control_dir}, data=${data_dir}, fra=${fra_dir}"
    fi

    # Export variables with optional prefix
    export "${prefix}ADMIN_DIR=${admin_dir}"
    export "${prefix}DATA_DIR=${data_dir}"
    export "${prefix}FRA_DIR=${fra_dir}"
    export "${prefix}CONTROL_DIR=${control_dir}"

    # For backward compatibility, also set without prefix
    if [[ -z "${prefix}" ]]; then
        ADMIN_DIR="${admin_dir}"
        DATA_DIR="${data_dir}"
        FRA_DIR="${fra_dir}"
        CONTROL_DIR="${control_dir}"
    fi

    report_track_step_done 0 "Paths resolved: admin, data, fra, control"
    report_track_metric "config_paths_resolved" "1" "set"
}

# Alias for backward compatibility
oracle_resolve_dest_paths() { oracle_config_resolve_paths "$@"; }

# oracle_config_create_dirs - Create required directories for database
# Usage: oracle_config_create_dirs [admin_dir] [data_dir] [fra_dir] [control_dir]
# Note: Uses global variables if parameters not provided
oracle_config_create_dirs() {
    local admin_dir="${1:-${ADMIN_DIR:-}}"
    local data_dir="${2:-${DATA_DIR:-}}"
    local fra_dir="${3:-${FRA_DIR:-}}"
    local control_dir="${4:-${CONTROL_DIR:-}}"

    # Track operation
    report_track_step "Create required directories"
    local dir_count=0
    [[ -n "${admin_dir}" ]] && (( dir_count++ ))
    [[ -n "${data_dir}" ]] && (( dir_count++ ))
    [[ -n "${fra_dir}" ]] && (( dir_count++ ))
    [[ -n "${control_dir}" ]] && (( dir_count++ ))
    report_track_meta "config_dirs_to_create" "${dir_count}"

    log_debug "[DIRS] Creating required directories"

    for dir in "${admin_dir}" "${data_dir}" "${fra_dir}" "${control_dir}"; do
        if [[ -n "${dir}" ]] && [[ ! "${dir}" =~ ^\+ ]]; then
            runtime_ensure_dir "${dir}"
            log_debug "[DIR] Created: ${dir}"
            report_track_item "ok" "Directory: ${dir}" "created"
        fi
    done

    report_track_step_done 0 "Created ${dir_count} directories"
    report_track_metric "config_dirs_created" "${dir_count}" "set"
}

#===============================================================================
# SECTION 5: PFILE Parsing
#===============================================================================

# oracle_config_pfile_parse_param - Extract any parameter from PFILE
# Usage: value=$(oracle_config_pfile_parse_param "/tmp/init.ora" "sga_target")
# Note: All log output goes to stderr to keep stdout clean for return value
oracle_config_pfile_parse_param() {
    local pfile="$1" param="$2"
    
    rt_assert_file_exists "pfile" "${pfile}"
    rt_assert_nonempty "param" "${param}"
    
    log_debug "[PARSE] Extracting ${param} from ${pfile}" >&2
    local value
    value=$(awk -v P="${param}" 'BEGIN{IGNORECASE=1} $0 ~ ("\\." P "[[:space:]]*=") {
        line=$0; sub(/^[^=]*=/,"",line); gsub(/[[:space:]'"'"'\"]/,"",line); print line; exit
    }' "${pfile}")
    log_debug "[PARSE] ${param}=${value}" >&2
    echo "${value}"
}

# oracle_config_pfile_parse_db_name - Extract db_name from PFILE
# Usage: db_name=$(oracle_config_pfile_parse_db_name "/tmp/init.ora")
oracle_config_pfile_parse_db_name() {
    local pfile="$1"
    oracle_config_pfile_parse_param "${pfile}" "db_name"
}

# Aliases for backward compatibility
oracle_parse_param_from_pfile() { oracle_config_pfile_parse_param "$@"; }
oracle_parse_db_name_from_pfile() { oracle_config_pfile_parse_db_name "$@"; }

#===============================================================================
# SECTION 6: PFILE Writing
#===============================================================================

# oracle_config_pfile_write_bootstrap - Generate minimal PFILE for NOMOUNT startup
# Usage: oracle_config_pfile_write_bootstrap <outfile> <sga> <pga> <db_unique_name> <dest_base> <admin_dir> <control_dir> [options...]
# Options:
#   --cluster-db TRUE|FALSE  - cluster_database setting (default: FALSE)
#   --processes N            - processes setting (default: 1500)
#   --local-listener STR     - local_listener setting (default: '')
oracle_config_pfile_write_bootstrap() {
    local outfile="$1" sga="$2" pga="$3"
    local db_unique_name="$4" dest_base="$5" admin_dir="$6" control_dir="$7"
    shift 7
    
    # Parse options
    local cluster_db="FALSE" processes="1500" local_listener=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --cluster-db)     cluster_db="$2"; shift 2 ;;
            --processes)      processes="$2"; shift 2 ;;
            --local-listener) local_listener="$2"; shift 2 ;;
            *) warn "Unknown option: $1"; shift ;;
        esac
    done

    rt_assert_nonempty "outfile" "${outfile}"
    rt_assert_nonempty "sga" "${sga}"
    rt_assert_nonempty "pga" "${pga}"
    rt_assert_nonempty "db_unique_name" "${db_unique_name}"
    rt_assert_nonempty "dest_base" "${dest_base}"
    rt_assert_nonempty "admin_dir" "${admin_dir}"
    rt_assert_nonempty "control_dir" "${control_dir}"

    log "[WRITE] Creating bootstrap PFILE: ${outfile}"
    log_debug "[PARAM] db_unique_name=${db_unique_name}"
    log_debug "[PARAM] sga_target=${sga}, pga_aggregate_target=${pga}"
    log_debug "[PARAM] diagnostic_dest=${dest_base}"
    log_debug "[PARAM] audit_file_dest=${admin_dir}"
    log_debug "[PARAM] control_files=${control_dir}/control0[12].ctl"
    log_debug "[PARAM] cluster_database=${cluster_db}, processes=${processes}"

    # Backup existing file if present
    runtime_backup_file "${outfile}"

    cat > "${outfile}" <<EOF
*.db_name='DUMMY'
*.db_unique_name='${db_unique_name}'
*.diagnostic_dest='${dest_base}'
*.audit_file_dest='${admin_dir}'
*.control_files='${control_dir}/control01.ctl','${control_dir}/control02.ctl'
*.sga_target=${sga}
*.pga_aggregate_target=${pga}
*.processes=${processes}
*.cluster_database=${cluster_db}
*.local_listener='${local_listener}'
EOF

    log "[OK] Bootstrap PFILE created ($(wc -l < "${outfile}") lines)"
}

# Alias for backward compatibility
oracle_write_bootstrap_pfile() { oracle_config_pfile_write_bootstrap "$@"; }

#===============================================================================
# SECTION 7: PFILE Sanitization
#===============================================================================

# oracle_config_pfile_sanitize - Sanitize PFILE for restore/clone operations
# Usage: oracle_config_pfile_sanitize <src> <dst> <db_name> <db_unique_name> <sga> <pga> \
#                                     <dest_type> <dest_base> <admin_dir> <control_dir> \
#                                     <data_dg> <fra_dg> [options...]
# Parameters:
#   src          - Source PFILE path
#   dst          - Destination PFILE path
#   db_name      - Original database name
#   db_unique_name - Target database unique name
#   sga          - SGA target (e.g., "4G")
#   pga          - PGA target (e.g., "2G")
#   dest_type    - Destination type: "FS" or "ASM"
#   dest_base    - Base directory for filesystem destinations
#   admin_dir    - Admin directory path (e.g., "/restore/admin/DB/adump")
#   control_dir  - Control file directory
#   data_dg      - Data diskgroup (for ASM) or data directory (for FS)
#   fra_dg       - FRA diskgroup (for ASM) or FRA directory (for FS)
# Options:
#   --drop-hidden         - Drop hidden parameters (_*)
#   --cluster-db TRUE|FALSE - cluster_database setting (default: FALSE)
#   --instance-number N   - instance_number setting (default: 1)
#   --thread N            - thread setting (default: 1)
#   --undo-tablespace TS  - undo_tablespace setting (default: UNDOTBS1)
#   --processes N         - processes setting (default: 1500)
#   --local-listener STR  - local_listener setting (default: '')
#   --fra-size SIZE       - db_recovery_file_dest_size (default: 1500G)
oracle_config_pfile_sanitize() {
    local src="$1" dst="$2"
    local db="$3" unq="$4"
    local sga="$5" pga="$6"
    local dtype="$7" dbase="$8"
    local admin="$9" ctldir="${10}"
    local data_dg="${11}" fra_dg="${12}"
    shift 12

    # Parse options
    local drop_hidden="0" cluster_db="FALSE" instance_num="1" thread="1"
    local undo_ts="UNDOTBS1" processes="1500" local_listener="" fra_size="1500G"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --drop-hidden)      drop_hidden="1"; shift ;;
            --cluster-db)       cluster_db="$2"; shift 2 ;;
            --instance-number)  instance_num="$2"; shift 2 ;;
            --thread)           thread="$2"; shift 2 ;;
            --undo-tablespace)  undo_ts="$2"; shift 2 ;;
            --processes)        processes="$2"; shift 2 ;;
            --local-listener)   local_listener="$2"; shift 2 ;;
            --fra-size)         fra_size="$2"; shift 2 ;;
            *) warn "Unknown option: $1"; shift ;;
        esac
    done

    # Validate required parameters
    rt_assert_file_exists "src" "${src}"
    rt_assert_nonempty "dst" "${dst}"
    rt_assert_nonempty "db_name" "${db}"
    rt_assert_nonempty "db_unique_name" "${unq}"
    rt_assert_nonempty "sga" "${sga}"
    rt_assert_nonempty "pga" "${pga}"
    rt_assert_nonempty "dest_type" "${dtype}"
    rt_assert_nonempty "dest_base" "${dbase}"
    rt_assert_nonempty "admin_dir" "${admin}"
    rt_assert_nonempty "control_dir" "${ctldir}"
    rt_assert_nonempty "data_dg" "${data_dg}"
    rt_assert_nonempty "fra_dg" "${fra_dg}"

    # Derive filesystem paths if needed
    local datafs frafs
    if [[ "${dtype}" == "FS" ]]; then
        datafs="${data_dg}"
        frafs="${fra_dg}"
    else
        datafs="${dbase}/oradata/${unq}"
        frafs="${dbase}/fra/${unq}"
    fi

    # Track operation
    report_track_step "Sanitize PFILE for restore"
    report_track_meta "config_pfile_src" "${src}"
    report_track_meta "config_pfile_dst" "${dst}"
    report_track_meta "config_pfile_db_name" "${db}"
    report_track_meta "config_pfile_db_unique_name" "${unq}"
    report_track_meta "config_pfile_dest_type" "${dtype}"

    log "[SANITIZE] Source: ${src}"
    log "[SANITIZE] Destination: ${dst}"
    log "[SANITIZE] db_name=${db} -> db_unique_name=${unq}"
    log_debug "[SANITIZE] DEST_TYPE=${dtype}, DEST_BASE=${dbase}"
    log_debug "[SANITIZE] SGA=${sga}, PGA=${pga}"
    log_debug "[SANITIZE] cluster_database=${cluster_db}, instance_number=${instance_num}, thread=${thread}"
    if [[ "${drop_hidden}" == "1" ]]; then
        log_debug "[SANITIZE] Dropping hidden parameters (_*)"
    fi

    # Backup existing destination file if present
    runtime_backup_file "${dst}"

    awk -v DB="${db}" -v UNQ="${unq}" -v DT="${dtype}" -v DBASE="${dbase}" -v ADMIN="${admin}" \
        -v CTL="${ctldir}" -v DATAFS="${datafs}" -v FRAFS="${frafs}" -v DATADG="${data_dg}" \
        -v FRADG="${fra_dg}" -v SGA="${sga}" -v PGA="${pga}" -v DROPHID="${drop_hidden}" \
        -v CLUSTER_DB="${cluster_db}" -v INST_NUM="${instance_num}" -v THREAD_NUM="${thread}" \
        -v UNDO_TS="${undo_ts}" -v PROCESSES="${processes}" -v LOCAL_LISTENER="${local_listener}" \
        -v FRA_SIZE="${fra_size}" \
'BEGIN{IGNORECASE=1}
{
  if(/^[A-Za-z0-9_]+\.__/||/^\*\.__/)next
  if(/^[A-Za-z0-9_]+\.(instance_number|thread|undo_tablespace)[[:space:]]*=/)next
  if(/^[A-Za-z0-9_]+\./&&!/^\*\./)next
  if(/^\*\.(db_name|db_unique_name|cluster_database|instance_number|thread|undo_tablespace)[[:space:]]*=/)next
  if(/^\*\.(diagnostic_dest|audit_file_dest|control_files)[[:space:]]*=/)next
  if(/^\*\.(db_create_file_dest|db_recovery_file_dest|db_recovery_file_dest_size|db_create_online_log_dest_1)[[:space:]]*=/)next
  if(/^\*\.(local_listener|remote_listener|listener_networks|cluster_interconnects)[[:space:]]*=/)next
  if(/^\*\.(sga_target|sga_max_size|pga_aggregate_target|pga_aggregate_limit)[[:space:]]*=/)next
  if(/^\*\.(shared_pool_size|streams_pool_size|java_pool_size|large_pool_size|db_cache_size)[[:space:]]*=/)next
  if(/^\*\.(processes)[[:space:]]*=/)next
  if(/^family:/)next
  if(/^\*\.(SEC_CASE_SENSITIVE_LOGON|_cursor_obsolete_threshold)[[:space:]]*=/)next
  if(DROPHID=="1"&&/^\*\.(event|_fix_control|_.*)=/)next
  print
}
END{
  print "*.db_name=\047" DB "\047"
  print "*.db_unique_name=\047" UNQ "\047"
  print "*.cluster_database=" CLUSTER_DB
  print "*.instance_number=" INST_NUM
  print "*.thread=" THREAD_NUM
  print "*.undo_tablespace=\047" UNDO_TS "\047"
  print "*.diagnostic_dest=\047" DBASE "\047"
  print "*.audit_file_dest=\047" ADMIN "\047"
  print "*.control_files=\047" CTL "/control01.ctl\047,\047" CTL "/control02.ctl\047"
  if(DT=="ASM"){
    print "*.db_create_file_dest=\047" DATADG "\047"
    print "*.db_recovery_file_dest=\047" FRADG "\047"
    print "*.db_create_online_log_dest_1=\047" DATADG "\047"
    print "*.db_create_online_log_dest_2=\047" FRADG "\047"
  }else{
    print "*.db_create_file_dest=\047" DATAFS "\047"
    print "*.db_recovery_file_dest=\047" FRAFS "\047"
    print "*.db_create_online_log_dest_1=\047" DATAFS "\047"
    print "*.db_create_online_log_dest_2=\047" FRAFS "\047"
  }
  print "*.db_recovery_file_dest_size=" FRA_SIZE
  print "*.sga_target=" SGA
  print "*.sga_max_size=" SGA
  print "*.pga_aggregate_target=" PGA
  print "*.processes=" PROCESSES
  print "*.local_listener=\047" LOCAL_LISTENER "\047"
}' "${src}" > "${dst}"

    local src_lines dst_lines
    src_lines=$(wc -l < "${src}")
    dst_lines=$(wc -l < "${dst}")
    log "[OK] Sanitized PFILE: ${src_lines} -> ${dst_lines} lines"

    # Track result
    report_track_item "ok" "PFILE Sanitization" "Converted ${src_lines} -> ${dst_lines} lines"
    report_track_metric "config_pfile_src_lines" "${src_lines}" "set"
    report_track_metric "config_pfile_dst_lines" "${dst_lines}" "set"
    report_track_step_done 0 "PFILE sanitized: ${src_lines} -> ${dst_lines} lines"
}

# Alias for backward compatibility
oracle_sanitize_pfile() { oracle_config_pfile_sanitize "$@"; }

#===============================================================================
# SECTION 8: Configuration Utilities
#===============================================================================

# oracle_config_print_paths - Print resolved paths
# Usage: oracle_config_print_paths
oracle_config_print_paths() {
    echo
    echo "==================== Database Paths ===================="
    runtime_print_kv "ADMIN_DIR" "${ADMIN_DIR:-<not set>}"
    runtime_print_kv "DATA_DIR" "${DATA_DIR:-<not set>}"
    runtime_print_kv "FRA_DIR" "${FRA_DIR:-<not set>}"
    runtime_print_kv "CONTROL_DIR" "${CONTROL_DIR:-<not set>}"
    echo "========================================================"
}

# oracle_config_host_report_callback - Callback for runtime_write_host_report
# Usage: runtime_write_host_report "/tmp/host.txt" "oracle_config_host_report_callback"
oracle_config_host_report_callback() {
    echo "ORACLE_HOME=${ORACLE_HOME:-}"
    echo "ORACLE_SID=${ORACLE_SID:-}"
    echo "TARGET_SID=${TARGET_SID:-}"
    echo "ADMIN_DIR=${ADMIN_DIR:-}"
    echo "DATA_DIR=${DATA_DIR:-}"
    echo "FRA_DIR=${FRA_DIR:-}"
}

#===============================================================================
# SECTION 9: Oracle Wallet Management
#===============================================================================

# Default wallet base directory
WALLET_BASE="${WALLET_BASE:-${HOME}/.wallets}"

# oracle_config_wallet_create - Create Oracle Wallet for an environment
# Usage: oracle_config_wallet_create "env_name" "user" "password" "tns" "wallet_dir"
# Requires: orapki or mkstore (Oracle utilities)
# Notes:
#   - Creates auto-login wallet (cwallet.sso) for unattended operation
#   - Generates sqlnet.ora and tnsnames.ora in wallet directory
#   - Sets restrictive permissions (700 on dir, 600 on files)
oracle_config_wallet_create() {
    local env="$1" user="$2" password="$3" tns="$4" wallet_dir="${5:-${WALLET_BASE}/${1}}"

    rt_assert_nonempty "env" "${env}"
    rt_assert_nonempty "user" "${user}"
    rt_assert_nonempty "password" "${password}"
    rt_assert_nonempty "tns" "${tns}"

    log "Creating Oracle Wallet for environment: ${env}"
    log_debug "Wallet directory: ${wallet_dir}"

    # Check for Oracle utilities
    local wallet_tool=""
    if command -v orapki &>/dev/null; then
        wallet_tool="orapki"
    elif command -v mkstore &>/dev/null; then
        wallet_tool="mkstore"
    else
        log_error "Neither orapki nor mkstore found. Install Oracle Client."
        return 1
    fi

    # Create wallet directory
    runtime_ensure_dir "${wallet_dir}"
    chmod 700 "${wallet_dir}"

    # Generate a wallet password (not the DB password)
    local wallet_pwd
    wallet_pwd=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)

    if [[ "${wallet_tool}" == "orapki" ]]; then
        # Create wallet with orapki
        orapki wallet create -wallet "${wallet_dir}" -pwd "${wallet_pwd}" -auto_login 2>/dev/null || {
            log_error "Failed to create wallet with orapki"
            return 1
        }

        # Add credential using mkstore (orapki doesn't do credentials)
        if command -v mkstore &>/dev/null; then
            mkstore -wrl "${wallet_dir}" -createCredential "${tns}" "${user}" "${password}" <<< "${wallet_pwd}" 2>/dev/null || {
                log_error "Failed to add credentials with mkstore"
                return 1
            }
        else
            log_warning "mkstore not found - wallet created but no credentials added"
            log_warning "Manually run: mkstore -wrl ${wallet_dir} -createCredential ${tns} ${user} <password>"
        fi
    else
        # Create wallet with mkstore
        mkstore -wrl "${wallet_dir}" -create <<< "${wallet_pwd}
${wallet_pwd}" 2>/dev/null || {
            log_error "Failed to create wallet with mkstore"
            return 1
        }

        # Add credential
        mkstore -wrl "${wallet_dir}" -createCredential "${tns}" "${user}" "${password}" <<< "${wallet_pwd}" 2>/dev/null || {
            log_error "Failed to add credentials"
            return 1
        }

        # Create auto-login wallet
        orapki wallet create -wallet "${wallet_dir}" -pwd "${wallet_pwd}" -auto_login 2>/dev/null || {
            log_warning "Could not create auto-login wallet (orapki not available)"
        }
    fi

    # Generate sqlnet.ora
    cat > "${wallet_dir}/sqlnet.ora" <<EOF
# Oracle Wallet configuration for ${env}
# Generated: $(date -Iseconds)

WALLET_LOCATION = (SOURCE = (METHOD = FILE) (METHOD_DATA = (DIRECTORY = ${wallet_dir})))
SQLNET.WALLET_OVERRIDE = TRUE
SSL_CLIENT_AUTHENTICATION = FALSE
EOF

    # Generate tnsnames.ora entry
    cat > "${wallet_dir}/tnsnames.ora" <<EOF
# TNS entry for ${env} environment
# Generated: $(date -Iseconds)

${tns} =
  (DESCRIPTION =
    (ADDRESS = (PROTOCOL = TCP)(HOST = localhost)(PORT = 1521))
    (CONNECT_DATA = (SERVICE_NAME = ${tns}))
  )
EOF

    # Set restrictive permissions
    chmod 600 "${wallet_dir}"/*.sso "${wallet_dir}"/*.p12 2>/dev/null || true
    chmod 600 "${wallet_dir}/sqlnet.ora" "${wallet_dir}/tnsnames.ora"

    log_success "Wallet created: ${wallet_dir}"
    report_track_item "ok" "Wallet" "${env} → ${wallet_dir}"

    return 0
}

# oracle_config_wallet_create_from_keyring - Create wallet from keyring environment
# Usage: oracle_config_wallet_create_from_keyring "env_name"
# Requires: keyring.sh to be loaded and keyring to be open
oracle_config_wallet_create_from_keyring() {
    local env="$1"
    rt_assert_nonempty "env" "${env}"

    if ! type -t keyring_env_get &>/dev/null; then
        log_error "keyring.sh not loaded"
        return 1
    fi

    if ! keyring_is_open; then
        log_error "Keyring not open"
        return 1
    fi

    local user password tns
    user=$(keyring_env_get "${env}" "user") || { log_error "Failed to get user from keyring"; return 1; }
    password=$(keyring_env_get "${env}" "password") || { log_error "Failed to get password from keyring"; return 1; }
    tns=$(keyring_env_get "${env}" "tns") || { log_error "Failed to get tns from keyring"; return 1; }

    oracle_config_wallet_create "${env}" "${user}" "${password}" "${tns}"
}

# oracle_config_wallet_create_all - Create wallets for all keyring environments
# Usage: oracle_config_wallet_create_all
oracle_config_wallet_create_all() {
    if ! type -t keyring_env_list &>/dev/null; then
        log_error "keyring.sh not loaded"
        return 1
    fi

    if ! keyring_is_open; then
        log_error "Keyring not open"
        return 1
    fi

    local envs
    envs=$(keyring_env_list)

    while IFS= read -r env; do
        [[ -z "${env}" ]] && continue
        log "Creating wallet for: ${env}"
        oracle_config_wallet_create_from_keyring "${env}" || log_warning "Failed to create wallet for ${env}"
    done <<< "${envs}"

    log_success "All wallets created"
}

# oracle_config_wallet_delete - Remove wallet directory
# Usage: oracle_config_wallet_delete "wallet_dir"
oracle_config_wallet_delete() {
    local wallet_dir="$1"
    rt_assert_nonempty "wallet_dir" "${wallet_dir}"

    if [[ ! -d "${wallet_dir}" ]]; then
        log_debug "Wallet directory does not exist: ${wallet_dir}"
        return 0
    fi

    # Safety check - ensure it looks like a wallet directory
    if [[ ! -f "${wallet_dir}/sqlnet.ora" ]] && [[ ! -f "${wallet_dir}/cwallet.sso" ]]; then
        log_error "Directory does not appear to be a wallet: ${wallet_dir}"
        return 1
    fi

    rm -rf "${wallet_dir}"
    log_success "Wallet deleted: ${wallet_dir}"
    return 0
}

# oracle_config_wallet_list - List existing wallets
# Usage: oracle_config_wallet_list
oracle_config_wallet_list() {
    local wallet_base="${WALLET_BASE:-${HOME}/.wallets}"

    if [[ ! -d "${wallet_base}" ]]; then
        log "No wallets found (directory does not exist: ${wallet_base})"
        return 0
    fi

    echo "Wallets in ${wallet_base}:"
    echo

    local found=0
    for dir in "${wallet_base}"/*/; do
        [[ ! -d "${dir}" ]] && continue
        local name
        name=$(basename "${dir}")
        if [[ -f "${dir}/cwallet.sso" ]]; then
            echo "  ${name} (auto-login enabled)"
            found=1
        elif [[ -f "${dir}/ewallet.p12" ]]; then
            echo "  ${name} (password required)"
            found=1
        fi
    done

    if [[ ${found} -eq 0 ]]; then
        echo "  (no wallets found)"
    fi
}

#===============================================================================
# END: oracle_config.sh
#===============================================================================
