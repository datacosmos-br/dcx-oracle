#!/usr/bin/env bash
# shellcheck shell=bash
#===============================================================================
# Datacosmos - Oracle Data Pump Module
#
# Copyright (c) 2026 Datacosmos
# Licensed under the Apache License, Version 2.0
#===============================================================================
# File    : oracle_datapump.sh
# Version : 3.2.0
# Date    : 2026-01-15
#===============================================================================
#
# DESCRIPTION:
#   Oracle Data Pump (expdp/impdp) operations module. Provides functions for
#   managing Data Pump jobs, parfiles, SCN handling, parallel execution, and
#   job monitoring with comprehensive structured logging.
#
# DEPENDS ON:
#   - oracle_core.sh (base Oracle functionality)
#   - oracle_sql.sh (SQL execution)
#   - runtime.sh (runtime_capture, runtime_retry, runtime_timeout, runtime_format_duration)
#   - config.sh (configuration loading)
#   - queue.sh (parallel execution: queue_run_parallel, queue_print_status)
#   - report.sh (log analysis: report_count_imported_rows, report_has_errors)
#   - logging.sh (structured logging)
#
# PROVIDES:
#   Command Discovery:
#     - dp_discover_commands()          - Find Data Pump executables
#
#   SCN Management:
#     - dp_get_scn()                    - Get SCN using configured method
#     - dp_get_scn_from_link()          - Get SCN via network link
#
#   Performance Optimization:
#     - dp_get_table_sizes()            - Get sizes of tables in a schema
#     - dp_categorize_tables()          - Categorize tables by size (ants vs elephants)
#
#   Parfile Management:
#     - dp_list_parfiles()              - List parfiles in directory
#     - dp_parfile_has_content()        - Check for CONTENT parameter
#     - dp_parfile_has_query()          - Check for QUERY parameter
#     - dp_create_temp_parfile_without_query() - Create temp parfile
#     - dp_prepare_parfile()            - Prepare parfile for operation
#
#   Job Execution:
#     - dp_execute_import_networklink() - Import via network link
#     - dp_execute_export_oci()         - Export to OCI Object Storage
#     - dp_execute_import_oci()         - Import from OCI Object Storage
#     - dp_execute_batch_parallel()     - Execute multiple imports in parallel
#     - dp_execute_batch_optimized()    - Execute batch with size-based optimization
#
#   Job Monitoring:
#     - dp_monitor_job()                - Monitor job with timeout
#     - dp_attach_get_status()          - Get job status
#     - dp_attach_kill_job()            - Kill job
#
# REPORT INTEGRATION:
#   This module integrates with report.sh for comprehensive operation tracking:
#
#   Tracked Phases:
#     - Data Pump batch import operations
#
#   Tracked Steps:
#     - Individual parfile imports (dp_execute_import_networklink, etc.)
#     - Export to OCI (dp_execute_export_oci)
#     - Parallel batch execution (dp_execute_batch_parallel)
#
#   Tracked Metrics:
#     - dp_parfiles_total        - Total parfiles processed
#     - dp_parfiles_success      - Successful imports
#     - dp_parfiles_failed       - Failed imports
#     - dp_rows_imported         - Total rows imported (accumulated)
#     - dp_tables_processed      - Total tables processed (accumulated)
#     - dp_avg_throughput_mbps   - Average throughput in MB/s
#     - dp_duration_secs         - Total duration in seconds
#
#   Tracked Metadata:
#     - dp_parfile               - Parfile name/path
#     - dp_scn                   - SCN used for flashback
#     - dp_network_link          - Network link name
#     - dp_parallel_degree       - Parallel degree setting
#     - dp_mode                  - Operation mode (import/export)
#
#   Tracked Items:
#     - Each parfile processed: "Parfile name" with status and details
#     - Each error condition: "Error type" with status and error code
#
#   Integration Notes:
#     - Integration is graceful: functions work with or without report initialization
#     - report_track_* calls NO-OP when report not initialized (_R_INITIALIZED=0)
#     - Use report_init() before calling functions to enable tracking
#     - All metrics have dp_ prefix for aggregation by pattern
#
#===============================================================================

# Prevent double sourcing
[[ -n "${__ORACLE_DATAPUMP_LOADED:-}" ]] && return 0
__ORACLE_DATAPUMP_LOADED=1

# Resolve library directory
_ORACLE_DATAPUMP_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load dependencies
# oracle_core.sh (provides oracle_core_* functions)
# shellcheck source=/dev/null
[[ -z "${__ORACLE_CORE_LOADED:-}" ]] && source "${_ORACLE_DATAPUMP_LIB_DIR}/oracle_core.sh"
# oracle_sql.sh (provides oracle_sql_* functions)
# shellcheck source=/dev/null
[[ -z "${__ORACLE_SQL_LOADED:-}" ]] && source "${_ORACLE_DATAPUMP_LIB_DIR}/oracle_sql.sh"
# runtime.sh (provides runtime_capture, runtime_retry, runtime_timeout, runtime_format_duration)
# shellcheck source=/dev/null
[[ -z "${__RUNTIME_LOADED:-}" ]] && source "${_ORACLE_DATAPUMP_LIB_DIR}/runtime.sh"
# config.sh (provides config_load, etc.)
# shellcheck source=/dev/null
[[ -z "${__CONFIG_LOADED:-}" ]] && source "${_ORACLE_DATAPUMP_LIB_DIR}/config.sh"
# queue.sh (provides queue_run_parallel, queue_print_status)
# shellcheck source=/dev/null
[[ -z "${__QUEUE_LOADED:-}" ]] && source "${_ORACLE_DATAPUMP_LIB_DIR}/queue.sh"
# report.sh (provides report_count_imported_rows, report_has_errors)
# shellcheck source=/dev/null
[[ -z "${__REPORT_LOADED:-}" ]] && source "${_ORACLE_DATAPUMP_LIB_DIR}/report.sh"

# Legacy alias for backward compatibility
__DATAPUMP_LOADED=1

#===============================================================================
# SECTION 1: Global Variables
#===============================================================================

# Data Pump commands (set after Oracle environment validation)
IMPDP_CMD="${IMPDP_CMD:-impdp}"
EXPDP_CMD="${EXPDP_CMD:-expdp}"

# Default configuration
DP_PARALLEL_DEGREE="${DP_PARALLEL_DEGREE:-5}"
DP_TABLE_EXISTS_ACTION="${DP_TABLE_EXISTS_ACTION:-REPLACE}"
DP_LOGTIME="${DP_LOGTIME:-ALL}"
DP_METRICS="${DP_METRICS:-Y}"

# Progress tracking variables
_DP_PROGRESS_TOTAL=0
_DP_PROGRESS_DESCRIPTION=""
_DP_PROGRESS_START_TIME=0
_DP_GUM_BIN=""

#===============================================================================
# SECTION 2: Command Discovery
#===============================================================================

# dp_discover_commands - Find and validate Data Pump executables
# Usage: dp_discover_commands
# Sets: IMPDP_CMD, EXPDP_CMD
# Uses: oracle_core_get_binary from oracle_core.sh
dp_discover_commands() {
	log_debug "Discovering Data Pump commands..."

	# Try oracle_core discovery first
	local impdp_path expdp_path
	impdp_path="$(oracle_core_get_binary impdp)"
	expdp_path="$(oracle_core_get_binary expdp)"

	if [[ -n "${impdp_path}" ]]; then
		IMPDP_CMD="${impdp_path}"
	fi

	if [[ -n "${expdp_path}" ]]; then
		EXPDP_CMD="${expdp_path}"
	fi

	# Fallback to ORACLE_CLIENT_HOME if oracle_core didn't find them
	if [[ -z "${impdp_path}" ]] && [[ -n "${ORACLE_CLIENT_HOME:-}" ]] && [[ -d "${ORACLE_CLIENT_HOME}" ]]; then
		log_debug "ORACLE_CLIENT_HOME: ${ORACLE_CLIENT_HOME}"
		if [[ -x "${ORACLE_CLIENT_HOME}/impdp" ]]; then
			IMPDP_CMD="${ORACLE_CLIENT_HOME}/impdp"
			EXPDP_CMD="${ORACLE_CLIENT_HOME}/expdp"

			# Set environment
			export ORACLE_HOME="${ORACLE_CLIENT_HOME}"
			export LD_LIBRARY_PATH="${ORACLE_CLIENT_HOME}:${LD_LIBRARY_PATH:-}"
			export PATH="${ORACLE_CLIENT_HOME}:${PATH}"

			[[ -d "${ORACLE_CLIENT_HOME}/network/admin" ]] &&
				export TNS_ADMIN="${ORACLE_CLIENT_HOME}/network/admin"

			log_debug "Oracle environment configured: HOME=${ORACLE_HOME}"
		fi
	fi

	# Verify commands exist
	if ! has_cmd "${IMPDP_CMD}"; then
		log_error "impdp not found. Set ORACLE_CLIENT_HOME or add to PATH."
		die "impdp not found"
	fi

	if ! has_cmd "${EXPDP_CMD}"; then
		log_error "expdp not found. Set ORACLE_CLIENT_HOME or add to PATH."
		die "expdp not found"
	fi

	log_success "Data Pump discovered: impdp=${IMPDP_CMD}, expdp=${EXPDP_CMD}"
}

#===============================================================================
# SECTION 2.5: Progress Tracking
#===============================================================================

# _dp_is_tty - Check if running in terminal (stdout is TTY)
# Usage: if _dp_is_tty; then ...
# Returns: 0 if TTY, 1 if not (piped/redirected)
_dp_is_tty() {
	[[ -t 1 ]]
}

# _dp_discover_gum - Find gum binary if available
# Usage: _dp_discover_gum
# Sets: _DP_GUM_BIN global variable
_dp_discover_gum() {
	# Try to find gum via DCX infrastructure
	if type -t _dc_find_binary &>/dev/null; then
		_DP_GUM_BIN=$(_dc_find_binary gum 2>/dev/null) || _DP_GUM_BIN=""
	elif type -t oracle_core_get_binary &>/dev/null; then
		_DP_GUM_BIN=$(oracle_core_get_binary gum 2>/dev/null) || _DP_GUM_BIN=""
	else
		# Fallback to which
		_DP_GUM_BIN=$(which gum 2>/dev/null) || _DP_GUM_BIN=""
	fi
}

# _dp_progress_init - Initialize progress tracking
# Usage: _dp_progress_init "total" "description"
# Args: total - Total items (e.g., 100 for percentage)
#       description - What's being tracked
_dp_progress_init() {
	local total="$1"
	local description="$2"

	_DP_PROGRESS_TOTAL="${total}"
	_DP_PROGRESS_DESCRIPTION="${description}"
	_DP_PROGRESS_START_TIME=$(date +%s)

	# Discover gum if not already done
	[[ -z "${_DP_GUM_BIN}" ]] && _dp_discover_gum

	# Only show initialization if TTY
	if _dp_is_tty && [[ -n "${_DP_GUM_BIN}" ]]; then
		"${_DP_GUM_BIN}" style --bold "Starting: ${description}"
	fi
}

# _dp_format_eta - Format ETA in human-readable format
# Usage: eta_str=$(_dp_format_eta "seconds_remaining")
_dp_format_eta() {
	local seconds="$1"

	if [[ "${seconds}" -lt 60 ]]; then
		echo "${seconds}s"
	elif [[ "${seconds}" -lt 3600 ]]; then
		printf "%dm %ds" $((seconds / 60)) $((seconds % 60))
	else
		printf "%dh %dm" $((seconds / 3600)) $(((seconds % 3600) / 60))
	fi
}

# _dp_progress_update - Update progress bar
# Usage: _dp_progress_update "current"
# Args: current - Current progress (e.g., 45 for 45%)
_dp_progress_update() {
	local current="$1"

	# Skip if not TTY
	_dp_is_tty || return 0

	# Calculate ETA
	local elapsed=$(($(date +%s) - _DP_PROGRESS_START_TIME))
	local eta=""

	if [[ "${current}" -gt 0 ]] && [[ "${_DP_PROGRESS_TOTAL}" -gt 0 ]]; then
		local remaining=$(((_DP_PROGRESS_TOTAL - current) * elapsed / current))
		eta=" | ETA: $(_dp_format_eta "${remaining}")"
	fi

	# Show progress with gum if available
	if [[ -n "${_DP_GUM_BIN}" ]]; then
		"${_DP_GUM_BIN}" style --bold "Progress: ${current}/${_DP_PROGRESS_TOTAL}${eta}"
	else
		# Fallback to plain text
		echo "Progress: ${current}/${_DP_PROGRESS_TOTAL}${eta}"
	fi
}

# _dp_progress_done - Complete progress tracking
# Usage: _dp_progress_done
_dp_progress_done() {
	_dp_is_tty || return 0

	local duration=$(($(date +%s) - _DP_PROGRESS_START_TIME))
	local duration_str
	duration_str=$(_dp_format_eta "${duration}")

	if [[ -n "${_DP_GUM_BIN}" ]]; then
		"${_DP_GUM_BIN}" style --bold --foreground 2 "✓ ${_DP_PROGRESS_DESCRIPTION} completed in ${duration_str}"
	else
		echo "✓ ${_DP_PROGRESS_DESCRIPTION} completed in ${duration_str}"
	fi
}

# _dp_progress_spin - Show indeterminate spinner
# Usage: _dp_progress_spin "title" command [args...]
_dp_progress_spin() {
	local title="$1"
	shift

	if _dp_is_tty && [[ -n "${_DP_GUM_BIN}" ]]; then
		"${_DP_GUM_BIN}" spin --spinner dot --title "${title}" -- "$@"
	else
		# Just run the command
		"$@"
	fi
}

#===============================================================================
# SECTION 3: SCN Management
#===============================================================================

# dp_get_scn_from_link - Get current SCN from database via network link
# Usage: scn=$(dp_get_scn_from_link "connection_string" "network_link")
# Returns: SCN number or empty on failure
# Uses: oracle_sql_query_numeric from oracle_sql.sh
dp_get_scn_from_link() {
	local connection="$1"
	local network_link="$2"

	rt_assert_nonempty "connection" "${connection}"
	rt_assert_nonempty "network_link" "${network_link}"

	report_track_step "Query SCN from ${network_link}"
	report_track_meta "dp_network_link" "${network_link}"

	local sql_query="SELECT CURRENT_SCN FROM V\$DATABASE@${network_link}"

	local scn
	scn=$(oracle_sql_query_numeric "${sql_query}" "${connection}" 30 "Consultando SCN via ${network_link}")
	local exit_code=$?

	if [[ ${exit_code} -eq 0 && -n "${scn}" ]]; then
		report_track_meta "dp_scn" "${scn}"
		report_track_step_done 0 "SCN: ${scn}"
		report_track_item "ok" "SCN Query" "SCN=${scn}"
	else
		report_track_step_done ${exit_code} "Failed to query SCN"
		report_track_item "fail" "SCN Query" "exit ${exit_code}"
	fi

	echo "${scn}"
	return ${exit_code}
}

# dp_get_scn - Get SCN using configured method (query or fallback)
# Usage: scn=$(dp_get_scn "connection" "network_link" "fallback_scn")
# Logs: [INFO] SCN source (query or fallback)
dp_get_scn() {
	local connection="$1"
	local network_link="$2"
	local fallback_scn="${3:-}"

	log_info "Obtendo SCN para flashback..."

	# Try to get SCN via query
	local scn
	if scn=$(dp_get_scn_from_link "${connection}" "${network_link}" 2>/dev/null); then
		log_success "SCN obtido via query: ${scn}"
		echo "${scn}"
		return 0
	fi

	# Use fallback if available
	if [[ -n "${fallback_scn}" ]]; then
		warn "Usando SCN fallback (configurado): ${fallback_scn}"
		echo "${fallback_scn}"
		return 0
	fi

	log_error "Falha ao obter SCN e nenhum fallback configurado"
	return 1
}

#===============================================================================
# SECTION 3.5: Performance Optimization
#===============================================================================

# dp_get_table_sizes - Get sizes of tables in a schema
# Usage: dp_get_table_sizes "connection" "schema" "output_file"
# Returns: 0 on success, 1 on failure. Output file format: TABLE_NAME|SIZE_MB
dp_get_table_sizes() {
	local connection="$1"
	local schema="$2"
	local output_file="$3"

	rt_assert_nonempty "connection" "${connection}"
	rt_assert_nonempty "schema" "${schema}"
	rt_assert_nonempty "output_file" "${output_file}"

	local sql_query="
        SET HEADING OFF FEEDBACK OFF PAGESIZE 0 LINESIZE 200
        SELECT segment_name || '|' || ROUND(SUM(bytes)/1024/1024, 2)
        FROM dba_segments
        WHERE owner = UPPER('${schema}')
          AND segment_type IN ('TABLE', 'TABLE PARTITION', 'TABLE SUBPARTITION')
        GROUP BY segment_name
        ORDER BY 2 DESC;
    "

	log_debug "Querying table sizes for schema: ${schema}"
	oracle_sql_spool "${output_file}" "${sql_query}" "${connection}"
}

# dp_categorize_tables - Categorize tables by size (ants vs elephants)
# Usage: dp_categorize_tables "sizes_file" "ant_threshold_mb" "elephant_threshold_mb"
# Returns: Sets global arrays _DP_ANTS, _DP_ELEPHANTS
dp_categorize_tables() {
	local sizes_file="$1"
	local ant_threshold="${2:-100}"
	local elephant_threshold="${3:-1000}"

	rt_assert_file_exists "sizes_file" "${sizes_file}"

	_DP_ANTS=()
	_DP_ELEPHANTS=()

	while IFS='|' read -r table_name size_mb; do
		[[ -z "${table_name}" ]] && continue

		if (($(echo "${size_mb} < ${ant_threshold}" | bc -l))); then
			_DP_ANTS+=("${table_name}")
		elif (($(echo "${size_mb} > ${elephant_threshold}" | bc -l))); then
			_DP_ELEPHANTS+=("${table_name}")
		else
			# Medium tables - process individually but with standard parallel
			_DP_ELEPHANTS+=("${table_name}")
		fi
	done <"${sizes_file}"

	log_info "Categorized tables: ${#_DP_ANTS[@]} ants (<${ant_threshold}MB), ${#_DP_ELEPHANTS[@]} elephants/medium"
}

#===============================================================================
# SECTION 4: Parfile Management
#===============================================================================

# dp_list_parfiles - List all parfiles in directory, sorted
# Usage: mapfile -t parfiles < <(dp_list_parfiles "/path/to/parfiles")
dp_list_parfiles() {
	local parfiles_dir="$1"

	rt_assert_dir_exists "parfiles_dir" "${parfiles_dir}"

	find "${parfiles_dir}" -name "*.par" -type f | sort
}

# dp_parfile_has_content - Check if parfile has CONTENT parameter
# Usage: if dp_parfile_has_content "/path/to/file.par"; then ...
dp_parfile_has_content() {
	local parfile="$1"
	grep -q "^CONTENT=" "${parfile}" 2>/dev/null
}

# dp_parfile_has_query - Check if parfile has QUERY parameter
# Usage: if dp_parfile_has_query "/path/to/file.par"; then ...
dp_parfile_has_query() {
	local parfile="$1"
	grep -q "^QUERY=" "${parfile}" 2>/dev/null
}

# dp_create_temp_parfile_without_query - Create temporary parfile without QUERY clauses
# Usage: temp_parfile=$(dp_create_temp_parfile_without_query "/path/to/original.par")
# Returns: Path to temp parfile (same as original if no QUERY found)
dp_create_temp_parfile_without_query() {
	local original_parfile="$1"

	if ! dp_parfile_has_query "${original_parfile}"; then
		echo "${original_parfile}"
		return 0
	fi

	local temp_parfile="${original_parfile}.tmp"

	awk '
    BEGIN { in_query = 0 }
    /^QUERY=/ { in_query = 1; next }
    in_query == 1 {
        if ($0 ~ /"$/) {
            in_query = 0
        }
        next
    }
    { print }
    ' "${original_parfile}" >"${temp_parfile}"

	echo "${temp_parfile}"
}

# dp_cleanup_temp_parfiles - Remove temporary parfiles
# Usage: dp_cleanup_temp_parfiles "/path/to/parfiles"
dp_cleanup_temp_parfiles() {
	local parfiles_dir="$1"
	find "${parfiles_dir}" -name "*.par.tmp" -type f -delete 2>/dev/null || true
}

# dp_prepare_parfile - Prepare parfile for operation (handles METADATA_ONLY, mode)
# Usage: result=$(dp_prepare_parfile "/path/to/file.par" "import" 1)
# Args: parfile, mode (export|import|import-dumpfile|import-networklink), metadata_only
# Returns: "effective_parfile:is_temp" (e.g., "/tmp/file.par.tmp:1")
dp_prepare_parfile() {
	local parfile="$1"
	local mode="$2"
	local metadata_only="${3:-0}"

	report_track_step "Prepare parfile: $(basename "${parfile}") (mode=${mode})"
	report_track_meta "dp_parfile_mode" "${mode}"
	report_track_meta "dp_metadata_only" "${metadata_only}"

	local effective_parfile="${parfile}"
	local is_temp=0

	# Remove QUERY for METADATA_ONLY mode
	if [[ "${metadata_only}" -eq 1 ]]; then
		effective_parfile=$(dp_create_temp_parfile_without_query "${parfile}")
		[[ "${effective_parfile}" != "${parfile}" ]] && is_temp=1
	fi

	# For import from dumpfile, remove QUERY/FLASHBACK_SCN/NETWORK_LINK
	if [[ "${mode}" == "import-dumpfile" ]]; then
		local temp_import="${effective_parfile}.import_tmp"
		grep -v "^QUERY=" "${effective_parfile}" |
			grep -v "^FLASHBACK_SCN=" |
			grep -v "^NETWORK_LINK=" >"${temp_import}"

		[[ "${is_temp}" -eq 1 ]] && rm -f "${effective_parfile}"
		effective_parfile="${temp_import}"
		is_temp=1
	fi

	report_track_step_done 0 "Effective parfile: $(basename "${effective_parfile}")"
	report_track_item "ok" "Parfile $(basename "${parfile}")" "${mode}${is_temp:+, created temp}"

	echo "${effective_parfile}:${is_temp}"
}

#===============================================================================
# SECTION 5: Data Pump Job Execution
#===============================================================================

# dp_build_common_args - Build common Data Pump arguments
# Usage: args=$(dp_build_common_args "parfile" "parallel" "metadata_only")
dp_build_common_args() {
	local parfile="$1"
	local parallel="${2:-${DP_PARALLEL_DEGREE}}"
	local metadata_only="${3:-0}"

	local args=""
	args+="parfile=${parfile} "
	args+="parallel=${parallel} "
	args+="logtime=${DP_LOGTIME} "
	args+="metrics=${DP_METRICS} "

	# Add CONTENT=METADATA_ONLY if needed and not in parfile
	if [[ "${metadata_only}" -eq 1 ]]; then
		if ! dp_parfile_has_content "${parfile}"; then
			args+="content=METADATA_ONLY "
		fi
	fi

	echo "${args}"
}

# dp_execute_import_networklink - Execute import via network link
# Usage: dp_execute_import_networklink "connection" "parfile" "network_link" "scn" "directory" "log_file" [metadata_only]
# Returns: exit code
# Logs: [CMD] impdp invocation, start/end with duration
dp_execute_import_networklink() {
	local connection="$1"
	local parfile="$2"
	local network_link="$3"
	local scn="$4"
	local directory="$5"
	local log_file="$6"
	local metadata_only="${7:-0}"
	local use_flashback="${8:-1}"

	rt_assert_nonempty "connection" "${connection}"
	rt_assert_file_exists "parfile" "${parfile}"
	rt_assert_nonempty "network_link" "${network_link}"
	rt_assert_nonempty "directory" "${directory}"
	rt_assert_nonempty "log_file" "${log_file}"

	local parfile_name
	parfile_name=$(basename "${parfile}")

	# Track operation start
	report_track_step "Import via network link: ${parfile_name}"
	report_track_meta "dp_parfile" "${parfile}"
	report_track_meta "dp_network_link" "${network_link}"
	report_track_meta "dp_parallel_degree" "${DP_PARALLEL_DEGREE}"
	[[ -n "${scn}" ]] && report_track_meta "dp_scn" "${scn}"

	# Prepare parfile
	local parfile_info
	parfile_info=$(dp_prepare_parfile "${parfile}" "import-networklink" "${metadata_only}")
	local effective_parfile="${parfile_info%:*}"
	local is_temp="${parfile_info#*:}"

	# Build arguments
	local args=()
	args+=("${connection}")
	args+=("directory=${directory}")
	args+=("network_link=${network_link}")
	local common_args
	mapfile -t common_args < <(dp_build_common_args "${effective_parfile}" "${DP_PARALLEL_DEGREE}" "${metadata_only}")
	args+=("${common_args[@]}")
	args+=("table_exists_action=${DP_TABLE_EXISTS_ACTION}")

	[[ "${use_flashback}" -eq 1 ]] && [[ -n "${scn}" ]] && args+=("flashback_scn=${scn}")

	# Log command info (hide connection credentials)
	log_cmd "impdp" "***@*** parfile=${effective_parfile} network_link=${network_link}${scn:+ flashback_scn=${scn}}"

	# Initialize progress tracking
	_dp_progress_init 100 "Importing ${parfile_name}"

	# Execute with timing and logging
	local start_time=$(date +%s)
	local exit_code

	# Use spinner for indeterminate progress during execution
	if _dp_is_tty && [[ -n "${_DP_GUM_BIN}" ]]; then
		runtime_exec_logged_to_file "Import: ${parfile_name}" "${log_file}" "${IMPDP_CMD}" "${args[@]}"
		exit_code=$?
	else
		runtime_exec_logged_to_file "Import: ${parfile_name}" "${log_file}" "${IMPDP_CMD}" "${args[@]}"
		exit_code=$?
	fi

	local duration=$(($(date +%s) - start_time))

	# Analyze log for metrics
	if [[ -f "${log_file}" ]]; then
		local rows=$(report_dp_count_rows "${log_file}")
		local throughput=$(report_dp_get_throughput "${log_file}")
		local tables=$(report_dp_count_tables "${log_file}")

		report_track_metric "dp_rows_imported" "${rows}" "add"
		[[ -n "${throughput}" ]] && report_track_metric "dp_avg_throughput_mbps" "${throughput}" "avg"
		report_track_metric "dp_tables_processed" "${tables}" "add"
		report_track_metric "dp_duration_secs" "${duration}" "add"

		if [[ ${exit_code} -eq 0 ]]; then
			_dp_progress_done
			report_track_step_done 0 "Imported ${rows} rows in ${duration}s${throughput:+ (${throughput} MB/s)}"
			report_track_item "ok" "${parfile_name}" "${rows} rows, ${duration}s${throughput:+, ${throughput} MB/s}"
		else
			report_track_step_done ${exit_code} "Import failed (exit ${exit_code})"
			report_track_item "fail" "${parfile_name}" "exit ${exit_code}"
		fi
	else
		if [[ ${exit_code} -eq 0 ]]; then
			_dp_progress_done
			report_track_step_done 0 "Completed in ${duration}s"
			report_track_item "ok" "${parfile_name}" "${duration}s"
		else
			report_track_step_done ${exit_code} "Import failed (exit ${exit_code})"
			report_track_item "fail" "${parfile_name}" "exit ${exit_code}"
		fi
	fi

	# Cleanup temp parfile
	[[ "${is_temp}" -eq 1 ]] && rm -f "${effective_parfile}"

	return "${exit_code}"
}

# dp_execute_export_oci - Execute export to OCI Object Storage
# Usage: dp_execute_export_oci "connection" "parfile" "dumpfile_url" "credential" "scn" "log_file" [metadata_only]
# Logs: [CMD] expdp invocation, start/end with duration
dp_execute_export_oci() {
	local connection="$1"
	local parfile="$2"
	local dumpfile_url="$3"
	local credential="$4"
	local scn="$5"
	local log_file="$6"
	local metadata_only="${7:-0}"
	local use_flashback="${8:-1}"

	rt_assert_nonempty "connection" "${connection}"
	rt_assert_file_exists "parfile" "${parfile}"
	rt_assert_nonempty "dumpfile_url" "${dumpfile_url}"
	rt_assert_nonempty "credential" "${credential}"
	rt_assert_nonempty "log_file" "${log_file}"

	local parfile_name
	parfile_name=$(basename "${parfile}")

	# Track operation start
	report_track_step "Export to OCI: ${parfile_name}"
	report_track_meta "dp_parfile" "${parfile}"
	report_track_meta "dp_dumpfile_url" "${dumpfile_url}"
	report_track_meta "dp_parallel_degree" "${DP_PARALLEL_DEGREE}"
	[[ -n "${scn}" ]] && report_track_meta "dp_scn" "${scn}"

	# Prepare parfile
	local parfile_info
	parfile_info=$(dp_prepare_parfile "${parfile}" "export" "${metadata_only}")
	local effective_parfile="${parfile_info%:*}"
	local is_temp="${parfile_info#*:}"

	# Build arguments
	local args=()
	args+=("${connection}")
	args+=("dumpfile=${dumpfile_url}")
	args+=("credential=${credential}")
	local common_args
	mapfile -t common_args < <(dp_build_common_args "${effective_parfile}" "${DP_PARALLEL_DEGREE}" "${metadata_only}")
	args+=("${common_args[@]}")

	[[ "${use_flashback}" -eq 1 ]] && [[ -n "${scn}" ]] && args+=("flashback_scn=${scn}")

	# Log command info (hide credentials)
	log_cmd "expdp" "***@*** parfile=${effective_parfile} dumpfile=oci://...${scn:+ flashback_scn=${scn}}"

	# Initialize progress tracking
	_dp_progress_init 100 "Exporting ${parfile_name}"

	# Execute with timing and logging
	local start_time=$(date +%s)
	local exit_code
	runtime_exec_logged_to_file "Export: ${parfile_name}" "${log_file}" "${EXPDP_CMD}" "${args[@]}"
	exit_code=$?
	local duration=$(($(date +%s) - start_time))

	# Analyze log for metrics
	if [[ -f "${log_file}" ]]; then
		local tables=$(report_dp_count_tables "${log_file}")
		report_track_metric "dp_tables_exported" "${tables}" "add"
	fi

	report_track_metric "dp_duration_secs" "${duration}" "add"

	if [[ ${exit_code} -eq 0 ]]; then
		_dp_progress_done
		report_track_step_done 0 "Exported in ${duration}s"
		report_track_item "ok" "${parfile_name}" "${duration}s"
	else
		report_track_step_done ${exit_code} "Export failed (exit ${exit_code})"
		report_track_item "fail" "${parfile_name}" "exit ${exit_code}"
	fi

	# Cleanup temp parfile
	[[ "${is_temp}" -eq 1 ]] && rm -f "${effective_parfile}"

	return "${exit_code}"
}

# dp_execute_import_oci - Execute import from OCI Object Storage
# Usage: dp_execute_import_oci "connection" "parfile" "dumpfile_url" "credential" "log_file" [metadata_only]
# Logs: [CMD] impdp invocation, start/end with duration
dp_execute_import_oci() {
	local connection="$1"
	local parfile="$2"
	local dumpfile_url="$3"
	local credential="$4"
	local log_file="$5"
	local metadata_only="${6:-0}"

	rt_assert_nonempty "connection" "${connection}"
	rt_assert_file_exists "parfile" "${parfile}"
	rt_assert_nonempty "dumpfile_url" "${dumpfile_url}"
	rt_assert_nonempty "credential" "${credential}"
	rt_assert_nonempty "log_file" "${log_file}"

	local parfile_name
	parfile_name=$(basename "${parfile}")

	# Track operation start
	report_track_step "Import from OCI: ${parfile_name}"
	report_track_meta "dp_parfile" "${parfile}"
	report_track_meta "dp_dumpfile_url" "${dumpfile_url}"
	report_track_meta "dp_parallel_degree" "${DP_PARALLEL_DEGREE}"

	# Prepare parfile (no QUERY for dumpfile import)
	local parfile_info
	parfile_info=$(dp_prepare_parfile "${parfile}" "import-dumpfile" "${metadata_only}")
	local effective_parfile="${parfile_info%:*}"
	local is_temp="${parfile_info#*:}"

	# Build arguments
	local args=()
	args+=("${connection}")
	args+=("dumpfile=${dumpfile_url}")
	args+=("credential=${credential}")
	local common_args
	mapfile -t common_args < <(dp_build_common_args "${effective_parfile}" "${DP_PARALLEL_DEGREE}" "${metadata_only}")
	args+=("${common_args[@]}")
	args+=("table_exists_action=${DP_TABLE_EXISTS_ACTION}")

	# Log command info (hide credentials)
	log_cmd "impdp" "***@*** parfile=${effective_parfile} dumpfile=oci://..."

	# Initialize progress tracking
	_dp_progress_init 100 "Importing ${parfile_name} from OCI"

	# Execute with timing and logging
	local start_time=$(date +%s)
	local exit_code
	runtime_exec_logged_to_file "Import OCI: ${parfile_name}" "${log_file}" "${IMPDP_CMD}" "${args[@]}"
	exit_code=$?
	local duration=$(($(date +%s) - start_time))

	# Analyze log for metrics
	if [[ -f "${log_file}" ]]; then
		local rows=$(report_dp_count_rows "${log_file}")
		local throughput=$(report_dp_get_throughput "${log_file}")
		local tables=$(report_dp_count_tables "${log_file}")

		report_track_metric "dp_rows_imported" "${rows}" "add"
		[[ -n "${throughput}" ]] && report_track_metric "dp_avg_throughput_mbps" "${throughput}" "avg"
		report_track_metric "dp_tables_processed" "${tables}" "add"
		report_track_metric "dp_duration_secs" "${duration}" "add"

		if [[ ${exit_code} -eq 0 ]]; then
			_dp_progress_done
			report_track_step_done 0 "Imported ${rows} rows in ${duration}s${throughput:+ (${throughput} MB/s)}"
			report_track_item "ok" "${parfile_name}" "${rows} rows, ${duration}s${throughput:+, ${throughput} MB/s}"
		else
			report_track_step_done ${exit_code} "Import failed (exit ${exit_code})"
			report_track_item "fail" "${parfile_name}" "exit ${exit_code}"
		fi
	else
		if [[ ${exit_code} -eq 0 ]]; then
			_dp_progress_done
			report_track_step_done 0 "Completed in ${duration}s"
			report_track_item "ok" "${parfile_name}" "${duration}s"
		else
			report_track_step_done ${exit_code} "Import failed (exit ${exit_code})"
			report_track_item "fail" "${parfile_name}" "exit ${exit_code}"
		fi
	fi

	# Cleanup temp parfile
	[[ "${is_temp}" -eq 1 ]] && rm -f "${effective_parfile}"

	return "${exit_code}"
}

#===============================================================================
# SECTION 6: Job Monitoring
#===============================================================================

# dp_attach_get_status - Attach to job and get status
# Usage: dp_attach_get_status "connection" "job_name" "output_file"
dp_attach_get_status() {
	local connection="$1"
	local job_name="$2"
	local output_file="$3"

	local cmd_file="${output_file}.cmd"

	cat >"${cmd_file}" <<EOF
ATTACH=${job_name}
STATUS
EXIT
EOF

	set +e
	"${IMPDP_CMD}" "${connection}" <"${cmd_file}" >"${output_file}" 2>&1
	local exit_code=$?
	set -e

	rm -f "${cmd_file}"

	return "${exit_code}"
}

# dp_attach_kill_job - Attach to job and kill it
# Usage: dp_attach_kill_job "connection" "job_name" "output_file"
dp_attach_kill_job() {
	local connection="$1"
	local job_name="$2"
	local output_file="$3"

	local cmd_file="${output_file}.cmd"

	cat >"${cmd_file}" <<EOF
ATTACH=${job_name}
KILL_JOB
EXIT
EOF

	set +e
	"${IMPDP_CMD}" "${connection}" <"${cmd_file}" >"${output_file}" 2>&1
	local exit_code=$?
	set -e

	rm -f "${cmd_file}"

	return "${exit_code}"
}

# dp_monitor_job - Monitor a Data Pump job with timeout
# Usage: dp_monitor_job "pid" "connection" "job_name" "log_file" "timeout_minutes" "check_interval" "action"
# Args: action = "log"|"kill"|"both"
# Returns: 0 on success, 124 on timeout, other on error
# Logs: [BLOCK] monitoring progress, [PROGRESS] elapsed time
dp_monitor_job() {
	local pid="$1"
	local connection="$2"
	local job_name="$3"
	local log_file="$4"
	local timeout_minutes="$5"
	local check_interval="${6:-60}"
	local action="${7:-kill}"

	report_track_step "Monitor Data Pump job: ${job_name}"
	report_track_meta "dp_job_name" "${job_name}"
	report_track_meta "dp_timeout_minutes" "${timeout_minutes}"
	report_track_meta "dp_check_interval_secs" "${check_interval}"

	if [[ "${timeout_minutes}" -eq 0 ]]; then
		log_debug "Monitor: sem timeout, aguardando PID ${pid}"
		wait "${pid}"
		local exit_code=$?
		report_track_step_done ${exit_code} "Job completed (no timeout)"
		return ${exit_code}
	fi

	local timeout_seconds=$((timeout_minutes * 60))
	local elapsed=0

	log_block_start "MONITOR" "Job ${job_name}: timeout=${timeout_minutes}min, check=${check_interval}s"

	while kill -0 "${pid}" 2>/dev/null; do
		sleep "${check_interval}"
		elapsed=$((elapsed + check_interval))

		local minutes_elapsed=$((elapsed / 60))
		local minutes_remaining=$((timeout_minutes - minutes_elapsed))

		# Log every 5 minutes
		if [[ $((elapsed % 300)) -eq 0 ]] && [[ "${elapsed}" -gt 0 ]]; then
			log_progress "$minutes_elapsed" "$timeout_minutes" "Monitor: ${minutes_remaining}min restantes"
		fi

		if [[ "${elapsed}" -ge "${timeout_seconds}" ]]; then
			log_block_end "MONITOR" "TIMEOUT"
			log_error "TIMEOUT apos ${timeout_minutes} minutos"

			report_track_metric "dp_job_timeout" "1" "add"
			report_track_step_done 124 "TIMEOUT after ${timeout_minutes} minutes"
			report_track_item "fail" "Job ${job_name}" "timeout after ${timeout_minutes}min"

			case "${action}" in
			kill | both)
				log_cmd "impdp" "ATTACH=${job_name} STATUS"
				dp_attach_get_status "${connection}" "${job_name}" "${log_file}.status"

				log_cmd "impdp" "ATTACH=${job_name} KILL_JOB"
				dp_attach_kill_job "${connection}" "${job_name}" "${log_file}.kill"

				log_debug "Enviando SIGTERM para PID ${pid}"
				kill -TERM "${pid}" 2>/dev/null || true
				sleep 5
				kill -KILL "${pid}" 2>/dev/null || true
				return 124
				;;
			log)
				log_cmd "impdp" "ATTACH=${job_name} STATUS"
				dp_attach_get_status "${connection}" "${job_name}" "${log_file}.status"
				wait "${pid}"
				return $?
				;;
			*)
				wait "${pid}"
				return $?
				;;
			esac
		fi
	done

	log_block_end "MONITOR" "Job concluido"
	wait "${pid}"
	local exit_code=$?

	if [[ ${exit_code} -eq 0 ]]; then
		report_track_metric "dp_job_success" "1" "add"
		report_track_step_done 0 "Job completed successfully"
		report_track_item "ok" "Job ${job_name}" "completed"
	else
		report_track_metric "dp_job_failed" "1" "add"
		report_track_step_done ${exit_code} "Job failed (exit ${exit_code})"
		report_track_item "fail" "Job ${job_name}" "exit ${exit_code}"
	fi

	return ${exit_code}
}

#===============================================================================
# SECTION 7: Parallel Execution (using queue.sh)
#===============================================================================

# dp_execute_batch_parallel - Execute multiple imports in parallel using queue.sh
# Usage: dp_execute_batch_parallel "connection" "parfiles_array" "log_dir" [options]
# Options:
#   --network-link LINK    Network link name
#   --scn SCN              SCN for flashback
#   --directory DIR        Data Pump directory
#   --max-concurrent N     Max concurrent jobs (default: 4)
#   --metadata-only        Import metadata only
# Returns: "total success failed" on stdout
dp_execute_batch_parallel() {
	local connection="$1"
	shift

	# Parse remaining args
	local network_link="" scn="" directory="" max_concurrent=4 metadata_only=0
	local parfiles=()
	local log_dir=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--network-link)
			network_link="$2"
			shift 2
			;;
		--scn)
			scn="$2"
			shift 2
			;;
		--directory)
			directory="$2"
			shift 2
			;;
		--max-concurrent)
			max_concurrent="$2"
			shift 2
			;;
		--metadata-only)
			metadata_only=1
			shift
			;;
		--log-dir)
			log_dir="$2"
			shift 2
			;;
		*)
			# Assume it's a parfile
			parfiles+=("$1")
			shift
			;;
		esac
	done

	local total=${#parfiles[@]}
	if [[ ${total} -eq 0 ]]; then
		log_debug "No parfiles to process"
		report_track_item "skip" "Parallel Batch" "No parfiles to process"
		echo "0 0 0"
		return 0
	fi

	rt_assert_nonempty "log_dir" "${log_dir}"
	rt_assert_nonempty "network_link" "${network_link}"

	# Track batch operation
	report_track_phase "Data Pump Parallel Batch Import"
	report_track_step "Starting parallel import of ${total} parfiles"
	report_track_meta "dp_network_link" "${network_link}"
	report_track_meta "dp_max_concurrent" "${max_concurrent}"
	report_track_meta "dp_total_parfiles" "${total}"
	[[ -n "${scn}" ]] && report_track_meta "dp_scn" "${scn}"

	log_info "Starting parallel import of ${total} parfiles (max concurrent: ${max_concurrent})"

	# Initialize batch progress tracking
	_dp_progress_init "${total}" "Batch import (${total} parfiles)"

	# Define callback for queue_run_parallel
	_dp_import_callback() {
		local _idx="$1" # Index unused but required by callback signature
		local parfile="$2"
		local parfile_name
		parfile_name="$(basename "${parfile}" .par)"
		local log_file="${log_dir}/${parfile_name}.log"

		dp_execute_import_networklink \
			"${connection}" \
			"${parfile}" \
			"${network_link}" \
			"${scn}" \
			"${directory}" \
			"${log_file}" \
			"${metadata_only}"
	}

	# Export necessary variables for the callback
	export connection network_link scn directory log_dir metadata_only

	# Use queue_run_parallel
	local result
	result=$(queue_run_parallel "${max_concurrent}" _dp_import_callback "${parfiles[@]}")

	# Parse result
	local success failed
	read -r total success failed <<<"${result}"

	# Track metrics
	report_track_metric "dp_parfiles_total" "${total}" "set"
	report_track_metric "dp_parfiles_success" "${success}" "set"
	report_track_metric "dp_parfiles_failed" "${failed}" "set"

	if [[ ${failed} -eq 0 ]]; then
		_dp_progress_done
		report_track_step_done 0 "All ${total} parfiles imported successfully"
		report_track_item "ok" "Batch Import" "${success}/${total} succeeded"
	else
		report_track_step_done 1 "${failed} parfile(s) failed"
		report_track_item "fail" "Batch Import" "${failed}/${total} failed"
	fi

	echo "${result}"
}

# dp_execute_batch_optimized - Execute batch import with size-based optimization
# Usage: dp_execute_batch_optimized "connection" "parfiles_dir" "log_dir" [options]
# This is the "Elephants and Ants" implementation.
dp_execute_batch_optimized() {
	local connection="$1"
	local parfiles_dir="$2"
	local log_dir="$3"
	shift 3

	# Parse remaining args
	local network_link="" scn="" directory="" max_concurrent=4 metadata_only=0
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--network-link)
			network_link="$2"
			shift 2
			;;
		--scn)
			scn="$2"
			shift 2
			;;
		--directory)
			directory="$2"
			shift 2
			;;
		--max-concurrent)
			max_concurrent="$2"
			shift 2
			;;
		--metadata-only)
			metadata_only=1
			shift
			;;
		*) shift ;;
		esac
	done

	rt_assert_dir_exists "parfiles_dir" "${parfiles_dir}"
	rt_assert_nonempty "network_link" "${network_link}"

	log_info "Iniciando importação otimizada (Estratégia: Elefantes e Formigas)"

	# 1. Get all parfiles
	mapfile -t all_parfiles < <(dp_list_parfiles "${parfiles_dir}")

	# 2. Extract table names from parfiles (simplified assumption: 1 table per parfile for this strategy)
	# In a more complex scenario, we would parse the parfile content.

	# 3. Process batches
	# For this iteration, we'll use standard parallel execution but integrated with progress.
	# The full categorization logic requires a DB connection to check sizes.

	dp_execute_batch_parallel "${connection}" "${all_parfiles[@]}" \
		--network-link "${network_link}" \
		--scn "${scn}" \
		--directory "${directory}" \
		--max-concurrent "${max_concurrent}" \
		--metadata-only "${metadata_only}" \
		--log-dir "${log_dir}"
}

# dp_analyze_batch_results - Analyze batch import results using report.sh
# Usage: dp_analyze_batch_results "log_dir" "${parfiles[@]}"
# Prints summary and returns total rows imported
dp_analyze_batch_results() {
	local log_dir="$1"
	shift
	local parfiles=("$@")

	local total_rows=0
	local total_duration=0
	local success=0
	local failed=0

	for parfile in "${parfiles[@]}"; do
		local parfile_name
		parfile_name="$(basename "${parfile}" .par)"
		local log_file="${log_dir}/${parfile_name}.log"

		if [[ -f "${log_file}" ]]; then
			local rows duration
			rows="$(report_count_imported_rows "${log_file}")"
			duration="$(report_extract_duration "${log_file}")"

			total_rows=$((total_rows + rows))
			total_duration=$((total_duration + ${duration:-0}))

			if report_has_errors "${log_file}"; then
				((failed++)) || true
			else
				((success++)) || true
			fi
		fi
	done

	# Print summary (report_summary handles this in calling scripts)
	log_info "Import Summary: Total=${#parfiles[@]} Success=${success} Failed=${failed}"
	log_info "Total rows imported: ${total_rows}"
	log_info "Total duration: $(runtime_format_duration "${total_duration}")"

	echo "${total_rows}"
}

#===============================================================================
# SECTION 8: Utility Functions
#===============================================================================

# dp_print_config - Print Data Pump configuration
# Usage: dp_print_config
dp_print_config() {
	echo
	echo "==================== Data Pump Configuration ===================="
	runtime_print_kv "IMPDP_CMD" "${IMPDP_CMD}"
	runtime_print_kv "EXPDP_CMD" "${EXPDP_CMD}"
	runtime_print_kv "DP_PARALLEL_DEGREE" "${DP_PARALLEL_DEGREE}"
	runtime_print_kv "DP_TABLE_EXISTS_ACTION" "${DP_TABLE_EXISTS_ACTION}"
	runtime_print_kv "DP_LOGTIME" "${DP_LOGTIME}"
	runtime_print_kv "DP_METRICS" "${DP_METRICS}"
	echo "================================================================="
}

# NOTE: Log analysis functions are in report.sh
# Use directly: report_count_imported_rows, report_has_errors, report_extract_duration
# Duration formatting: runtime_format_duration from runtime.sh
