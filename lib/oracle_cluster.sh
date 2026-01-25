#!/usr/bin/env bash
# shellcheck shell=bash
#===============================================================================
# Datacosmos - Oracle Cluster Module
#
# Copyright (c) 2026 Datacosmos
# Licensed under the Apache License, Version 2.0
#===============================================================================
# File    : oracle_cluster.sh
# Version : 1.1.0
# Date    : 2026-01-15
#===============================================================================
#
# DESCRIPTION:
#   Oracle RAC and Clusterware detection and management. Provides functions
#   to detect clusterware, determine if database is RAC, and execute
#   cluster-aware operations using srvctl.
#
# DEPENDS ON:
#   - oracle_core.sh (base Oracle functionality)
#   - runtime.sh (runtime_capture, runtime_retry, has_cmd)
#   - logging.sh (logging functions)
#
# PROVIDES:
#   Detection:
#     - oracle_cluster_detect()        - Detect if Clusterware is available
#     - oracle_cluster_is_rac()        - Check if database is RAC
#     - oracle_cluster_is_available()  - Check if cluster commands are available
#
#   Information:
#     - oracle_cluster_get_nodes()     - Get cluster nodes
#     - oracle_cluster_get_db_info()   - Get database cluster info
#     - oracle_cluster_get_instance_info() - Get instance info
#
#   Operations:
#     - oracle_cluster_start_instance()   - Start instance via srvctl
#     - oracle_cluster_stop_instance()    - Stop instance via srvctl
#     - oracle_cluster_start_database()   - Start database via srvctl
#     - oracle_cluster_stop_database()    - Stop database via srvctl
#
# REPORT INTEGRATION:
#   This module integrates with report.sh for cluster operation tracking:
#   - Tracked Steps: Clusterware detection, RAC detection, instance/database operations
#   - Tracked Metrics: cluster_detected (1/0), cluster_rac (1/0), cluster_node_count
#   - Tracked Metadata: cluster_type, cluster_nodes, cluster_db_type, cluster_version
#   - Tracked Items: Detection results, instance/database operations
#   - Integration is graceful (NO-OP without report_init)
#   - All metrics have cluster_ prefix for pattern-based aggregation
#
#===============================================================================

# Prevent double sourcing
[[ -n "${__ORACLE_CLUSTER_LOADED:-}" ]] && return 0
__ORACLE_CLUSTER_LOADED=1

# Resolve library directory
_ORACLE_CLUSTER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load oracle_core.sh (provides oracle_core_* functions and _ORACLE_SRVCTL_PATH)
# shellcheck source=/dev/null
[[ -z "${__ORACLE_CORE_LOADED:-}" ]] && source "${_ORACLE_CLUSTER_LIB_DIR}/oracle_core.sh"

# Load runtime.sh (provides runtime_capture, runtime_retry, has_cmd)
# shellcheck source=/dev/null
[[ -z "${__RUNTIME_LOADED:-}" ]] && source "${_ORACLE_CLUSTER_LIB_DIR}/runtime.sh"

#===============================================================================
# INTERNAL STATE
#===============================================================================

# Cache for cluster detection
declare -g _ORACLE_CLUSTER_DETECTED=""
declare -g _ORACLE_CLUSTER_IS_RAC=""

#===============================================================================
# SECTION 1: Clusterware Detection
#===============================================================================

# oracle_cluster_detect - Detect if Oracle Clusterware is available
# Usage: if oracle_cluster_detect; then echo "Clusterware available"; fi
# Returns: 0 if clusterware detected, 1 otherwise
# Sets: _ORACLE_CLUSTER_DETECTED to "1" or "0"
oracle_cluster_detect() {
    # Return cached result if available
    if [[ -n "${_ORACLE_CLUSTER_DETECTED}" ]]; then
        [[ "${_ORACLE_CLUSTER_DETECTED}" == "1" ]]
        return $?
    fi

    # Track operation (only on fresh detection, not cached)
    report_track_step "Detect Oracle Clusterware"

    log_debug "[CLUSTER] Detecting Oracle Clusterware..."

    # Check if srvctl is available
    local srvctl_path
    srvctl_path="$(oracle_core_get_binary srvctl)"

    if [[ -n "${srvctl_path}" ]] && [[ -x "${srvctl_path}" ]]; then
        # Try to run srvctl config to verify it works
        local output rc
        set +e
        output="$("${srvctl_path}" config 2>&1)"
        rc=$?
        set -e

        if [[ ${rc} -eq 0 ]] || [[ "${output}" != *"not running"* ]]; then
            _ORACLE_CLUSTER_DETECTED="1"
            log_debug "[CLUSTER] Clusterware detected: srvctl available at ${srvctl_path}"
            report_track_item "ok" "Clusterware Detection" "srvctl available"
            report_track_step_done 0 "Clusterware detected"
            report_track_metric "cluster_detected" "1" "set"
            return 0
        fi
    fi

    # Check if crsctl is available and cluster is running
    local crsctl_path
    crsctl_path="$(oracle_core_get_binary crsctl)"

    if [[ -n "${crsctl_path}" ]] && [[ -x "${crsctl_path}" ]]; then
        local output
        if output="$("${crsctl_path}" check crs 2>&1)" && [[ "${output}" == *"online"* ]]; then
            _ORACLE_CLUSTER_DETECTED="1"
            log_debug "[CLUSTER] Clusterware detected: CRS is online"
            report_track_item "ok" "Clusterware Detection" "CRS online"
            report_track_step_done 0 "Clusterware detected"
            report_track_metric "cluster_detected" "1" "set"
            return 0
        fi
    fi

    _ORACLE_CLUSTER_DETECTED="0"
    log_debug "[CLUSTER] Clusterware not detected or not running"
    report_track_item "fail" "Clusterware Detection" "not detected"
    report_track_step_done 1 "Clusterware not detected"
    report_track_metric "cluster_detected" "0" "set"
    return 1
}

# oracle_cluster_is_available - Check if cluster commands are available
# Usage: if oracle_cluster_is_available; then ...
oracle_cluster_is_available() {
    oracle_cluster_detect
}

# oracle_cluster_get_srvctl - Get path to srvctl binary
# Usage: SRVCTL=$(oracle_cluster_get_srvctl)
oracle_cluster_get_srvctl() {
    oracle_core_get_binary srvctl
}

# oracle_cluster_get_crsctl - Get path to crsctl binary
# Usage: CRSCTL=$(oracle_cluster_get_crsctl)
oracle_cluster_get_crsctl() {
    oracle_core_get_binary crsctl
}

#===============================================================================
# SECTION 2: RAC Detection
#===============================================================================

# oracle_cluster_is_rac - Check if database is RAC
# Usage: if oracle_cluster_is_rac; then echo "This is a RAC database"; fi
# Returns: 0 if RAC, 1 if single instance
oracle_cluster_is_rac() {
    # Return cached result if available
    if [[ -n "${_ORACLE_CLUSTER_IS_RAC}" ]]; then
        [[ "${_ORACLE_CLUSTER_IS_RAC}" == "1" ]]
        return $?
    fi

    # Track operation (only on fresh detection, not cached)
    report_track_step "Detect RAC configuration"

    log_debug "[RAC] Checking if database is RAC..."

    # First check if clusterware is available
    if ! oracle_cluster_detect; then
        _ORACLE_CLUSTER_IS_RAC="0"
        log_debug "[RAC] No clusterware, assuming single instance"
        report_track_item "ok" "RAC Detection" "single instance (no clusterware)"
        report_track_step_done 0 "Single instance database"
        report_track_metric "cluster_rac" "0" "set"
        return 1
    fi

    # Check ORACLE_UNQNAME if set
    local db_unique_name="${ORACLE_UNQNAME:-}"

    if [[ -n "${db_unique_name}" ]]; then
        # Try srvctl config database to check if RAC
        local srvctl_path output
        srvctl_path="$(oracle_cluster_get_srvctl)"

        if [[ -n "${srvctl_path}" ]]; then
            if runtime_capture output "${srvctl_path}" config database -d "${db_unique_name}" 2>/dev/null; then
                if [[ "${output}" == *"Instance"* ]] && [[ "${output}" == *","* ]]; then
                    _ORACLE_CLUSTER_IS_RAC="1"
                    log_debug "[RAC] Database ${db_unique_name} is RAC (multiple instances)"
                    report_track_item "ok" "RAC Detection" "Multiple instances via srvctl"
                    report_track_step_done 0 "RAC database detected"
                    report_track_metric "cluster_rac" "1" "set"
                    return 0
                fi
            fi
        fi
    fi

    # Try to query v$instance if oracle_sql is available
    if declare -f oracle_sql_sysdba_query >/dev/null 2>&1; then
        if ! oracle_core_skip_oracle_cmds; then
            local cluster_db
            cluster_db="$(oracle_sql_sysdba_query "SELECT VALUE FROM V\$PARAMETER WHERE NAME='cluster_database';" 2>/dev/null | tr -d '[:space:]')"

            if [[ "${cluster_db}" == "TRUE" ]]; then
                _ORACLE_CLUSTER_IS_RAC="1"
                log_debug "[RAC] Database is RAC (cluster_database=TRUE)"
                report_track_item "ok" "RAC Detection" "cluster_database=TRUE"
                report_track_step_done 0 "RAC database detected"
                report_track_metric "cluster_rac" "1" "set"
                return 0
            fi
        fi
    fi

    _ORACLE_CLUSTER_IS_RAC="0"
    log_debug "[RAC] Database is single instance"
    report_track_item "ok" "RAC Detection" "Single instance database"
    report_track_step_done 0 "Single instance database"
    report_track_metric "cluster_rac" "0" "set"
    return 1
}

# oracle_cluster_clear_cache - Clear detection cache
# Usage: oracle_cluster_clear_cache
oracle_cluster_clear_cache() {
    _ORACLE_CLUSTER_DETECTED=""
    _ORACLE_CLUSTER_IS_RAC=""
    log_debug "[CLUSTER] Cache cleared"
}

#===============================================================================
# SECTION 3: Cluster Information
#===============================================================================

# oracle_cluster_get_nodes - Get list of cluster nodes
# Usage: nodes=($(oracle_cluster_get_nodes))
oracle_cluster_get_nodes() {
    if ! oracle_cluster_detect; then
        echo ""
        return 1
    fi

    local olsnodes_path output
    olsnodes_path="$(oracle_core_find_binary olsnodes)"
    
    if [[ -n "${olsnodes_path}" ]]; then
        if runtime_capture output "${olsnodes_path}" 2>/dev/null; then
            echo "${output}"
            return 0
        fi
    fi

    # Fallback: try crsctl
    local crsctl_path
    crsctl_path="$(oracle_cluster_get_crsctl)"
    
    if [[ -n "${crsctl_path}" ]]; then
        if runtime_capture output "${crsctl_path}" stat res -t 2>/dev/null; then
            echo "${output}" | awk '/^ora\.[^.]+\.vip$/ {gsub(/^ora\./,""); gsub(/\.vip$/,""); print}'
            return 0
        fi
    fi

    return 1
}

# oracle_cluster_get_db_info - Get database cluster information
# Usage: oracle_cluster_get_db_info "DBNAME"
# Returns: Database configuration from srvctl
oracle_cluster_get_db_info() {
    local db_name="${1:-${ORACLE_UNQNAME:-}}"
    
    if [[ -z "${db_name}" ]]; then
        warn "Database name required for cluster info"
        return 1
    fi

    if ! oracle_cluster_detect; then
        warn "Clusterware not available"
        return 1
    fi

    local srvctl_path output
    srvctl_path="$(oracle_cluster_get_srvctl)"
    
    if [[ -z "${srvctl_path}" ]]; then
        return 1
    fi

    log_debug "[CLUSTER] Getting database info for: ${db_name}"
    
    if runtime_capture output "${srvctl_path}" config database -d "${db_name}" 2>/dev/null; then
        echo "${output}"
        return 0
    fi
    
    return 1
}

# oracle_cluster_get_instance_info - Get instance cluster information
# Usage: oracle_cluster_get_instance_info "DBNAME" "INSTANCE1"
oracle_cluster_get_instance_info() {
    local db_name="${1:-${ORACLE_UNQNAME:-}}"
    local instance="${2:-${ORACLE_SID:-}}"
    
    if [[ -z "${db_name}" ]] || [[ -z "${instance}" ]]; then
        warn "Database name and instance required"
        return 1
    fi

    if ! oracle_cluster_detect; then
        return 1
    fi

    local srvctl_path output
    srvctl_path="$(oracle_cluster_get_srvctl)"
    
    if [[ -z "${srvctl_path}" ]]; then
        return 1
    fi

    log_debug "[CLUSTER] Getting instance info: ${db_name}/${instance}"
    
    if runtime_capture output "${srvctl_path}" status instance -d "${db_name}" -i "${instance}" 2>/dev/null; then
        echo "${output}"
        return 0
    fi
    
    return 1
}

# oracle_cluster_list_instances - List all instances for a database
# Usage: instances=($(oracle_cluster_list_instances "DBNAME"))
oracle_cluster_list_instances() {
    local db_name="${1:-${ORACLE_UNQNAME:-}}"
    
    if [[ -z "${db_name}" ]]; then
        return 1
    fi

    if ! oracle_cluster_detect; then
        # For single instance, return ORACLE_SID
        [[ -n "${ORACLE_SID:-}" ]] && echo "${ORACLE_SID}"
        return 0
    fi

    local srvctl_path output
    srvctl_path="$(oracle_cluster_get_srvctl)"
    
    if [[ -n "${srvctl_path}" ]]; then
        if runtime_capture output "${srvctl_path}" config database -d "${db_name}" 2>/dev/null; then
            # Extract instance names from "Database instances:" line
            echo "${output}" | awk '/^Database instances:/ {gsub(/^Database instances: /,""); gsub(/,/,"\n"); print}'
            return 0
        fi
    fi
    
    # Fallback to ORACLE_SID
    [[ -n "${ORACLE_SID:-}" ]] && echo "${ORACLE_SID}"
}

#===============================================================================
# SECTION 4: Cluster Operations - Instance Level
#===============================================================================

# oracle_cluster_start_instance - Start instance via srvctl
# Usage: oracle_cluster_start_instance "DBNAME" "INSTANCE" [options]
# Options: -o mount|nomount|open (default: open)
oracle_cluster_start_instance() {
    local db_name="$1"
    local instance="$2"
    shift 2
    local start_option="open"
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -o|--option) start_option="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    rt_assert_nonempty "db_name" "${db_name}"
    rt_assert_nonempty "instance" "${instance}"

    if ! oracle_cluster_detect; then
        warn "Clusterware not available, cannot use srvctl"
        return 1
    fi

    local srvctl_path
    srvctl_path="$(oracle_cluster_get_srvctl)"
    
    if [[ -z "${srvctl_path}" ]]; then
        die "srvctl not found"
    fi

    oracle_core_exec "Start instance ${instance} (${start_option})" \
        "${srvctl_path}" start instance -d "${db_name}" -i "${instance}" -o "${start_option}"
}

# oracle_cluster_stop_instance - Stop instance via srvctl
# Usage: oracle_cluster_stop_instance "DBNAME" "INSTANCE" [options]
# Options: -o immediate|abort|transactional (default: immediate)
oracle_cluster_stop_instance() {
    local db_name="$1"
    local instance="$2"
    shift 2
    local stop_option="immediate"
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -o|--option) stop_option="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    rt_assert_nonempty "db_name" "${db_name}"
    rt_assert_nonempty "instance" "${instance}"

    if ! oracle_cluster_detect; then
        warn "Clusterware not available, cannot use srvctl"
        return 1
    fi

    local srvctl_path
    srvctl_path="$(oracle_cluster_get_srvctl)"
    
    if [[ -z "${srvctl_path}" ]]; then
        die "srvctl not found"
    fi

    oracle_core_exec "Stop instance ${instance} (${stop_option})" \
        "${srvctl_path}" stop instance -d "${db_name}" -i "${instance}" -o "${stop_option}"
}

#===============================================================================
# SECTION 5: Cluster Operations - Database Level
#===============================================================================

# oracle_cluster_start_database - Start entire database via srvctl
# Usage: oracle_cluster_start_database "DBNAME" [options]
# Options: -o mount|nomount|open (default: open)
oracle_cluster_start_database() {
    local db_name="$1"
    shift
    local start_option="open"
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -o|--option) start_option="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    rt_assert_nonempty "db_name" "${db_name}"

    if ! oracle_cluster_detect; then
        warn "Clusterware not available, cannot use srvctl"
        return 1
    fi

    local srvctl_path
    srvctl_path="$(oracle_cluster_get_srvctl)"
    
    if [[ -z "${srvctl_path}" ]]; then
        die "srvctl not found"
    fi

    oracle_core_exec "Start database ${db_name} (${start_option})" \
        "${srvctl_path}" start database -d "${db_name}" -o "${start_option}"
}

# oracle_cluster_stop_database - Stop entire database via srvctl
# Usage: oracle_cluster_stop_database "DBNAME" [options]
# Options: -o immediate|abort|transactional (default: immediate)
oracle_cluster_stop_database() {
    local db_name="$1"
    shift
    local stop_option="immediate"
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -o|--option) stop_option="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    rt_assert_nonempty "db_name" "${db_name}"

    if ! oracle_cluster_detect; then
        warn "Clusterware not available, cannot use srvctl"
        return 1
    fi

    local srvctl_path
    srvctl_path="$(oracle_cluster_get_srvctl)"
    
    if [[ -z "${srvctl_path}" ]]; then
        die "srvctl not found"
    fi

    oracle_core_exec "Stop database ${db_name} (${stop_option})" \
        "${srvctl_path}" stop database -d "${db_name}" -o "${stop_option}"
}

#===============================================================================
# SECTION 6: Cluster Utilities
#===============================================================================

# oracle_cluster_status - Get cluster resource status
# Usage: oracle_cluster_status
oracle_cluster_status() {
    if ! oracle_cluster_detect; then
        echo "Clusterware not available"
        return 1
    fi

    local crsctl_path
    crsctl_path="$(oracle_cluster_get_crsctl)"
    
    if [[ -n "${crsctl_path}" ]]; then
        "${crsctl_path}" stat res -t 2>/dev/null
        return $?
    fi

    return 1
}

# oracle_cluster_print_info - Print cluster information
# Usage: oracle_cluster_print_info
oracle_cluster_print_info() {
    echo
    echo "==================== Cluster Information ===================="
    
    if oracle_cluster_detect; then
        runtime_print_kv "Clusterware" "Available"
        runtime_print_kv "srvctl" "$(oracle_cluster_get_srvctl || echo '<not found>')"
        runtime_print_kv "crsctl" "$(oracle_cluster_get_crsctl || echo '<not found>')"
        
        if oracle_cluster_is_rac; then
            runtime_print_kv "RAC Database" "Yes"
        else
            runtime_print_kv "RAC Database" "No"
        fi
        
        local nodes
        nodes="$(oracle_cluster_get_nodes 2>/dev/null | tr '\n' ' ')"
        runtime_print_kv "Cluster Nodes" "${nodes:-<unknown>}"
    else
        runtime_print_kv "Clusterware" "Not Available"
        runtime_print_kv "Environment" "Single Instance"
    fi
    
    echo "============================================================="
}

#===============================================================================
# SECTION 7: Backward Compatibility Aliases
#===============================================================================
