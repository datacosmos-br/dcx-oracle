#!/usr/bin/env bash
# shellcheck shell=bash
#===============================================================================
# Datacosmos - OCI Object Storage Library
#
# Copyright (c) 2026 Datacosmos
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#===============================================================================
# File    : oracle_oci.sh
# Version : 2.0.0
# Date    : 2026-01-15
# Author  : Datacosmos | Marlon Costa <marlon.costa@datacosmos.com.br>
#===============================================================================
#
# DESCRIPTION:
#   OCI Object Storage utilities for Data Pump dumpfile operations.
#   Provides URL construction, path management, and ready-file coordination.
#
# DEPENDS ON:
#   - oracle_core.sh (base Oracle functionality, oracle_core_exec)
#   - runtime.sh (logging, validators, runtime_exec_logged)
#   - queue.sh (parallel execution)
#
# PROVIDES:
#   Configuration:
#     - oracle_oci_validate_config()      - Validate required OCI configuration
#     - oracle_oci_print_config()         - Print OCI configuration summary
#
#   Path Management:
#     - oracle_oci_generate_path()        - Generate unique migration path
#     - oracle_oci_build_url()            - Build full OCI dumpfile URL
#     - oracle_oci_build_object_path()    - Build object path
#
#   Ready-File Coordination:
#     - oracle_oci_mark_ready()           - Mark export as complete
#     - oracle_oci_wait_ready()           - Wait for export to complete
#     - oracle_oci_get_status()           - Get export status
#
#   OCI CLI Operations (optional):
#     - oracle_oci_cli_available()        - Check if OCI CLI is available
#     - oracle_oci_list_objects()         - List objects in bucket path
#     - oracle_oci_delete_objects()       - Delete objects in bucket path
#
#===============================================================================

# Prevent double sourcing
[[ -n "${__OCI_LOADED:-}" ]] && return 0
__OCI_LOADED=1

# Also set with oracle prefix for consistency
__ORACLE_OCI_LOADED=1

# Resolve library directory
_ORACLE_OCI_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load dependencies
# oracle_core.sh (provides oracle_core_exec*)
# shellcheck source=/dev/null
[[ -z "${__ORACLE_CORE_LOADED:-}" ]] && source "${_ORACLE_OCI_LIB_DIR}/oracle_core.sh" || true
# runtime.sh (provides runtime_exec_logged, validators)
# shellcheck source=/dev/null
[[ -z "${__RUNTIME_LOADED:-}" ]] && source "${_ORACLE_OCI_LIB_DIR}/runtime.sh" || true
# queue.sh (provides queue_mark_ready, queue_wait_ready)
# shellcheck source=/dev/null
[[ -z "${__QUEUE_LOADED:-}" ]] && source "${_ORACLE_OCI_LIB_DIR}/queue.sh" || true

#===============================================================================
# SECTION 1: Configuration Defaults
#===============================================================================

OCI_BASE_URL="${OCI_BASE_URL:-https://objectstorage.sa-saopaulo-1.oraclecloud.com}"
OCI_NAMESPACE="${OCI_NAMESPACE:-}"
OCI_BUCKET_NAME="${OCI_BUCKET_NAME:-}"
OCI_BASE_PATH="${OCI_BASE_PATH:-}"
OCI_EXPORT_CREDENTIAL="${OCI_EXPORT_CREDENTIAL:-}"
OCI_IMPORT_CREDENTIAL="${OCI_IMPORT_CREDENTIAL:-}"

#===============================================================================
# SECTION 2: Configuration Validation
#===============================================================================

# oracle_oci_validate_config - Validate required OCI configuration
# Usage: oracle_oci_validate_config
oracle_oci_validate_config() {
    rt_assert_nonempty "OCI_NAMESPACE" "${OCI_NAMESPACE}"
    rt_assert_nonempty "OCI_BUCKET_NAME" "${OCI_BUCKET_NAME}"
    rt_assert_nonempty "OCI_EXPORT_CREDENTIAL" "${OCI_EXPORT_CREDENTIAL}"
    rt_assert_nonempty "OCI_IMPORT_CREDENTIAL" "${OCI_IMPORT_CREDENTIAL}"

    log "OCI config validated: namespace=${OCI_NAMESPACE}, bucket=${OCI_BUCKET_NAME}"
}

#===============================================================================
# SECTION 3: Path Management
#===============================================================================

# oracle_oci_generate_path - Generate unique migration path with timestamp
# Usage: path=$(oracle_oci_generate_path)
# Returns: Path like "migrate_20260113_143052" or "base/migrate_20260113_143052"
oracle_oci_generate_path() {
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)

    if [[ -n "${OCI_BASE_PATH}" ]]; then
        echo "${OCI_BASE_PATH}/migrate_${timestamp}"
    else
        echo "migrate_${timestamp}"
    fi
}

# oracle_oci_build_url - Build full OCI dumpfile URL
# Usage: url=$(oracle_oci_build_url "migrate_20260113" "parfile_name")
# Returns: Full URL with %L placeholder for Data Pump parallel files
oracle_oci_build_url() {
    local oci_path="$1"
    local parfile_name="$2"

    rt_assert_nonempty "oci_path" "${oci_path}"
    rt_assert_nonempty "parfile_name" "${parfile_name}"

    # URL-encode the path (Data Pump uses %L for parallel file numbering)
    echo "${OCI_BASE_URL}/n/${OCI_NAMESPACE}/b/${OCI_BUCKET_NAME}/o/${oci_path}/${parfile_name}%L.dmp"
}

# oracle_oci_build_object_path - Build object path (without URL prefix)
# Usage: path=$(oracle_oci_build_object_path "migrate_20260113" "file.dmp")
oracle_oci_build_object_path() {
    local oci_path="$1"
    local filename="$2"
    echo "${oci_path}/${filename}"
}

#===============================================================================
# SECTION 4: Ready-File Coordination (delegates to queue.sh)
#===============================================================================

# oracle_oci_mark_ready - Mark export as complete (for import coordination)
# Usage: oracle_oci_mark_ready "log_dir" "parfile_name" "exit_code"
oracle_oci_mark_ready() {
    local log_dir="$1"
    local parfile_name="$2"
    local exit_code="${3:-0}"
    
    rt_assert_nonempty "log_dir" "${log_dir}"
    rt_assert_nonempty "parfile_name" "${parfile_name}"
    
    queue_mark_ready "${log_dir}/exports" "${parfile_name}" "${exit_code}"
}

# oracle_oci_wait_ready - Wait for export to complete
# Usage: oracle_oci_wait_ready "log_dir" "parfile_name" [check_interval]
oracle_oci_wait_ready() {
    local log_dir="$1"
    local parfile_name="$2"
    local check_interval="${3:-10}"
    
    rt_assert_nonempty "log_dir" "${log_dir}"
    rt_assert_nonempty "parfile_name" "${parfile_name}"
    
    local status
    status=$(queue_wait_ready "${log_dir}/exports" "${parfile_name}" "${check_interval}")
    [[ "${status}" == "SUCCESS" ]] && return 0
    return 1
}

# oracle_oci_get_status - Get export status from ready file
# Usage: status=$(oracle_oci_get_status "log_dir" "parfile_name")
oracle_oci_get_status() {
    local log_dir="$1"
    local parfile_name="$2"
    
    if queue_is_ready "${log_dir}/exports" "${parfile_name}"; then
        grep "^status=" "${log_dir}/exports/${parfile_name}.READY" 2>/dev/null | cut -d= -f2
    else
        echo "PENDING"
    fi
}

#===============================================================================
# SECTION 5: OCI CLI Integration (Optional)
#===============================================================================

# oracle_oci_cli_available - Check if OCI CLI is available
# Usage: if oracle_oci_cli_available; then ...
oracle_oci_cli_available() {
    has_cmd oci
}

# oracle_oci_list_objects - List objects in bucket path (requires OCI CLI)
# Usage: oracle_oci_list_objects "migrate_20260113"
# Uses: runtime_exec_logged for consistent logging
oracle_oci_list_objects() {
    local prefix="$1"

    if ! oracle_oci_cli_available; then
        warn "OCI CLI not available"
        return 1
    fi

    rt_assert_nonempty "prefix" "${prefix}"

    runtime_exec_logged "List OCI objects: ${prefix}" \
        oci os object list \
        --namespace "${OCI_NAMESPACE}" \
        --bucket-name "${OCI_BUCKET_NAME}" \
        --prefix "${prefix}" \
        --query 'data[].name' \
        --output table
}

# oracle_oci_delete_objects - Delete objects in bucket path (requires OCI CLI)
# Usage: oracle_oci_delete_objects "migrate_20260113"
# Uses: runtime_exec_logged for consistent logging
oracle_oci_delete_objects() {
    local prefix="$1"

    if ! oracle_oci_cli_available; then
        warn "OCI CLI not available for cleanup"
        return 1
    fi

    rt_assert_nonempty "prefix" "${prefix}"

    log "Deleting objects with prefix: ${prefix}"

    runtime_exec_logged "Delete OCI objects: ${prefix}" \
        oci os object bulk-delete \
        --namespace "${OCI_NAMESPACE}" \
        --bucket-name "${OCI_BUCKET_NAME}" \
        --prefix "${prefix}" \
        --force
}

#===============================================================================
# SECTION 6: Utility Functions
#===============================================================================

# oracle_oci_print_config - Print OCI configuration summary
# Usage: oracle_oci_print_config
oracle_oci_print_config() {
    echo
    echo "==================== OCI Configuration ===================="
    runtime_print_kv "OCI_BASE_URL" "${OCI_BASE_URL}"
    runtime_print_kv "OCI_NAMESPACE" "${OCI_NAMESPACE}"
    runtime_print_kv "OCI_BUCKET_NAME" "${OCI_BUCKET_NAME}"
    runtime_print_kv "OCI_BASE_PATH" "${OCI_BASE_PATH:-<root>}"
    runtime_print_kv "OCI_EXPORT_CREDENTIAL" "${OCI_EXPORT_CREDENTIAL}"
    runtime_print_kv "OCI_IMPORT_CREDENTIAL" "${OCI_IMPORT_CREDENTIAL}"
    echo "=========================================================="
}

