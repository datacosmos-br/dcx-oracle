#!/usr/bin/env bash
# shellcheck shell=bash
#===============================================================================
# Datacosmos - Parallel Queue Management Library
# Copyright (c) 2026 Datacosmos - Apache License 2.0
#===============================================================================
# File: queue.sh | Version: 1.0.0 | Date: 2026-01-13
#===============================================================================
#
# DESCRIPTION:
#   Parallel job queue management for bash scripts. Provides functions for
#   managing concurrent processes, tracking PIDs, and coordinating workflows.
#
#===============================================================================

[[ -n "${__QUEUE_LOADED:-}" ]] && return 0
__QUEUE_LOADED=1

_QUEUE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load runtime.sh if not already loaded (for die, warn, log, etc.)
# Note: This module can be loaded directly OR via core.sh
# shellcheck source=/dev/null
[[ -z "${__RUNTIME_LOADED:-}" ]] && source "${_QUEUE_LIB_DIR}/runtime.sh" || true

#===============================================================================
# Global Queue State
#===============================================================================

declare -gA QUEUE_PID_TO_TYPE      # PID -> job type
declare -gA QUEUE_PID_TO_INDEX     # PID -> job index
declare -gA QUEUE_PID_TO_NAME      # PID -> job name

QUEUE_MAX_CONCURRENT="${QUEUE_MAX_CONCURRENT:-4}"
QUEUE_ACTIVE_COUNT=0

#===============================================================================
# Queue Management
#===============================================================================

# queue_init - Initialize queue state
# Usage: queue_init [max_concurrent]
queue_init() {
    QUEUE_MAX_CONCURRENT="${1:-4}"
    QUEUE_ACTIVE_COUNT=0
    QUEUE_PID_TO_TYPE=()
    QUEUE_PID_TO_INDEX=()
    QUEUE_PID_TO_NAME=()
}

# queue_can_start - Check if queue has capacity
# Usage: if queue_can_start; then ...
queue_can_start() {
    [[ ${QUEUE_ACTIVE_COUNT} -lt ${QUEUE_MAX_CONCURRENT} ]]
}

# queue_register_job - Register a background job
# Usage: queue_register_job "$!" "export" "0" "parfile_name"
queue_register_job() {
    local pid="$1"
    local job_type="$2"
    local index="$3"
    local name="${4:-job_${index}}"

    QUEUE_PID_TO_TYPE[${pid}]="${job_type}"
    QUEUE_PID_TO_INDEX[${pid}]="${index}"
    QUEUE_PID_TO_NAME[${pid}]="${name}"
    (( QUEUE_ACTIVE_COUNT++ )) || true
}

# queue_unregister_job - Remove job from tracking
# Usage: queue_unregister_job "$pid"
queue_unregister_job() {
    local pid="$1"
    unset "QUEUE_PID_TO_TYPE[${pid}]"
    unset "QUEUE_PID_TO_INDEX[${pid}]"
    unset "QUEUE_PID_TO_NAME[${pid}]"
    ((QUEUE_ACTIVE_COUNT--)) || true
}

# queue_wait_any - Wait for any job to complete
# Usage: completed_pid=$(queue_wait_any)
# Returns: PID of completed job
queue_wait_any() {
    wait -n 2>/dev/null || true

    local pid
    for pid in "${!QUEUE_PID_TO_TYPE[@]}"; do
        if ! kill -0 "${pid}" 2>/dev/null; then
            echo "${pid}"
            return 0
        fi
    done
    echo ""
}

# queue_wait_all - Wait for all jobs to complete
# Usage: queue_wait_all
queue_wait_all() {
    while [[ ${QUEUE_ACTIVE_COUNT} -gt 0 ]]; do
        local completed_pid
        completed_pid=$(queue_wait_any)
        [[ -n "${completed_pid}" ]] && queue_unregister_job "${completed_pid}"
    done
}

# queue_get_job_info - Get info about a job
# Usage: read -r type index name < <(queue_get_job_info "$pid")
queue_get_job_info() {
    local pid="$1"
    echo "${QUEUE_PID_TO_TYPE[${pid}]:-} ${QUEUE_PID_TO_INDEX[${pid}]:-} ${QUEUE_PID_TO_NAME[${pid}]:-}"
}

# queue_active_pids - Get list of active PIDs
# Usage: for pid in $(queue_active_pids); do ...
queue_active_pids() {
    echo "${!QUEUE_PID_TO_TYPE[@]}"
}

#===============================================================================
# Parallel Execution Patterns
#===============================================================================

# queue_run_parallel - Run commands in parallel with max concurrency
# Usage: queue_run_parallel 4 command_callback "${items[@]}"
# callback receives: index item
queue_run_parallel() {
    local max_concurrent="$1"
    local callback="$2"
    shift 2
    local items=("$@")

    local total=${#items[@]}
    local started=0
    local completed=0
    local success=0
    local failed=0

    queue_init "${max_concurrent}"

    # Start initial batch
    while [[ ${started} -lt ${total} ]] && queue_can_start; do
        local idx=${started}
        local item="${items[${idx}]}"

        "${callback}" "${idx}" "${item}" &
        queue_register_job "$!" "job" "${idx}" "${item}"
        (( started++ )) || true
    done

    # Process completions and start new jobs
    while [[ ${completed} -lt ${total} ]]; do
        local completed_pid
        completed_pid=$(queue_wait_any)

        [[ -z "${completed_pid}" ]] && continue

        # Get exit code
        wait "${completed_pid}" 2>/dev/null
        local exit_code=$?

        # Get job info (unused but kept for future logging enhancement)
        # shellcheck disable=SC2034
        local _job_info
        _job_info=$(queue_get_job_info "${completed_pid}")
        queue_unregister_job "${completed_pid}"

        (( completed++ )) || true
        [[ ${exit_code} -eq 0 ]] && (( success++ )) || (( failed++ )) || true

        # Start next job if available
        if [[ ${started} -lt ${total} ]] && queue_can_start; then
            local idx=${started}
            local item="${items[${idx}]}"

            "${callback}" "${idx}" "${item}" &
            queue_register_job "$!" "job" "${idx}" "${item}"
            (( started++ )) || true
        fi
    done

    # Return summary
    echo "${total} ${success} ${failed}"
}

#===============================================================================
# Progress Tracking
#===============================================================================

# queue_print_status - Print current queue status
# Usage: queue_print_status "Export" 5 10
queue_print_status() {
    local phase="$1"
    local completed="$2"
    local total="$3"

    local pct=0
    [[ ${total} -gt 0 ]] && pct=$((completed * 100 / total))

    log "[${phase}] Progress: ${completed}/${total} (${pct}%) | Active: ${QUEUE_ACTIVE_COUNT}"
}

# NOTE: queue_summary has been moved to report.sh as report_summary()
# Use: report_summary "Phase Name" after importing report.sh

#===============================================================================
# Ready-File Coordination (for multi-phase workflows)
#===============================================================================

# queue_mark_ready - Create ready marker file
# Usage: queue_mark_ready "/path/to/markers" "job_name" "0"
queue_mark_ready() {
    local marker_dir="$1"
    local job_name="$2"
    local exit_code="${3:-0}"

    mkdir -p "${marker_dir}"
    {
        echo "timestamp=$(date '+%Y-%m-%d %H:%M:%S')"
        echo "exit_code=${exit_code}"
        [[ ${exit_code} -eq 0 ]] && echo "status=SUCCESS" || echo "status=FAILED"
    } > "${marker_dir}/${job_name}.READY"
}

# queue_wait_ready - Wait for ready marker
# Usage: queue_wait_ready "/path/to/markers" "job_name" [interval]
queue_wait_ready() {
    local marker_dir="$1"
    local job_name="$2"
    local interval="${3:-5}"

    local ready_file="${marker_dir}/${job_name}.READY"
    while [[ ! -f "${ready_file}" ]]; do
        sleep "${interval}"
    done

    # Return status
    grep "^status=" "${ready_file}" 2>/dev/null | cut -d= -f2
}

# queue_is_ready - Check if job is ready (non-blocking)
# Usage: if queue_is_ready "/path/to/markers" "job_name"; then ...
queue_is_ready() {
    local marker_dir="$1"
    local job_name="$2"
    [[ -f "${marker_dir}/${job_name}.READY" ]]
}
