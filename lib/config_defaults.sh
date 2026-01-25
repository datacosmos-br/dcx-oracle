#!/usr/bin/env bash
# shellcheck shell=bash
#===============================================================================
# Datacosmos - Configuration Defaults
# Copyright (c) 2026 Datacosmos - Apache License 2.0
#===============================================================================
# File: config_defaults.sh | Version: 1.0.0 | Date: 2026-01-15
#===============================================================================
#
# DESCRIPTION:
#   Centralized default values for all configuration variables.
#   This file is automatically loaded by config_load_hierarchical().
#   Use config_register_schema() to register validation schemas.
#
#===============================================================================

# Prevent double sourcing
[[ -n "${__CONFIG_DEFAULTS_LOADED:-}" ]] && return 0
__CONFIG_DEFAULTS_LOADED=1

# Note: config_register_schema must be available (loaded by config.sh before this)
# This file is sourced BY config.sh, so config.sh is already loaded

#===============================================================================
# LOGGING DEFAULTS
#===============================================================================

export LOG_LEVEL="${LOG_LEVEL:-2}"  # 0=quiet, 1=normal, 2=verbose, 3=debug
export LOG_SHOW_TIMESTAMP="${LOG_SHOW_TIMESTAMP:-1}"
export LOG_SHOW_CMD="${LOG_SHOW_CMD:-1}"
export LOG_SHOW_SQL="${LOG_SHOW_SQL:-1}"
export LOG_SHOW_BLOCK="${LOG_SHOW_BLOCK:-1}"
export LOG_SHOW_CONTEXT="${LOG_SHOW_CONTEXT:-0}"  # Show function/module/line
export LOG_STRUCTURED="${LOG_STRUCTURED:-0}"  # JSON output

#===============================================================================
# CONFIGURATION DEFAULTS
#===============================================================================

export CONFIG_PROFILE="${CONFIG_PROFILE:-prod}"

#===============================================================================
# ORACLE DEFAULTS
#===============================================================================

export ORACLE_HOME="${ORACLE_HOME:-}"
export ORACLE_SID="${ORACLE_SID:-}"
export ORACLE_BASE="${ORACLE_BASE:-}"
export ORACLE_UNQNAME="${ORACLE_UNQNAME:-}"
export ORACLE_CLIENT_HOME="${ORACLE_CLIENT_HOME:-}"

#===============================================================================
# DATABASE CONNECTION DEFAULTS
#===============================================================================

export DB_ADMIN_USER="${DB_ADMIN_USER:-admin}"
export DB_ADMIN_PASSWORD="${DB_ADMIN_PASSWORD:-}"
export DB_CONNECTION_STRING="${DB_CONNECTION_STRING:-}"
export SOURCE_DB_USER="${SOURCE_DB_USER:-admin}"
export SOURCE_DB_PASSWORD="${SOURCE_DB_PASSWORD:-}"
export SOURCE_DB_TNS="${SOURCE_DB_TNS:-}"
export NETWORK_LINK="${NETWORK_LINK:-}"
export DIRECTORY="${DIRECTORY:-data_pump_dir}"

#===============================================================================
# DATA PUMP DEFAULTS
#===============================================================================

export MAX_CONCURRENT_PROCESSES="${MAX_CONCURRENT_PROCESSES:-4}"
export PARALLEL_DEGREE="${PARALLEL_DEGREE:-5}"
export USE_DUMPFILES="${USE_DUMPFILES:-0}"
export SCN_QUERY="${SCN_QUERY:-}"
export FLASHBACK_SCN="${FLASHBACK_SCN:-0}"
export ENABLE_RETRY="${ENABLE_RETRY:-1}"
export MAX_RETRY_ATTEMPTS="${MAX_RETRY_ATTEMPTS:-3}"
export RETRY_DELAY="${RETRY_DELAY:-60}"

#===============================================================================
# OCI DEFAULTS
#===============================================================================

export OCI_NAMESPACE="${OCI_NAMESPACE:-}"
export OCI_BUCKET_NAME="${OCI_BUCKET_NAME:-}"
export OCI_BASE_URL="${OCI_BASE_URL:-https://objectstorage.sa-saopaulo-1.oraclecloud.com}"
export OCI_BASE_PATH="${OCI_BASE_PATH:-}"
export OCI_EXPORT_CREDENTIAL="${OCI_EXPORT_CREDENTIAL:-}"
export OCI_IMPORT_CREDENTIAL="${OCI_IMPORT_CREDENTIAL:-}"

#===============================================================================
# SQL EXECUTION DEFAULTS
#===============================================================================

export SQL_CONTINUE_ON_ERROR="${SQL_CONTINUE_ON_ERROR:-0}"
export SQL_DEFAULT_TIMEOUT="${SQL_DEFAULT_TIMEOUT:-0}"
export SQL_SCRIPT_TIMEOUT="${SQL_SCRIPT_TIMEOUT:-1200}"

#===============================================================================
# SESSION & LOGGING DEFAULTS
#===============================================================================

export LOGDIR="${LOGDIR:-}"
export MAIN_LOG="${MAIN_LOG:-}"
export SESSION_ID="${SESSION_ID:-}"
export SESSION_DIR="${SESSION_DIR:-}"
export SESSION_LOG="${SESSION_LOG:-}"

#===============================================================================
# VALIDATION DEFAULTS
#===============================================================================

export VALIDATE_CONNECTIVITY="${VALIDATE_CONNECTIVITY:-1}"
export VALIDATE_NETWORK_LINK="${VALIDATE_NETWORK_LINK:-1}"
export VALIDATE_PARFILES="${VALIDATE_PARFILES:-1}"
export VALIDATE_DISK_SPACE="${VALIDATE_DISK_SPACE:-1}"
export MIN_FREE_SPACE_GB="${MIN_FREE_SPACE_GB:-10}"

#===============================================================================
# REGISTER SCHEMAS FOR VALIDATION
#===============================================================================

# Logging schemas
config_register_schema "LOG_LEVEL" "uint" "0" "2" "0 1 2 3"
config_register_schema "LOG_SHOW_TIMESTAMP" "bool" "0" "1" ""
config_register_schema "LOG_SHOW_CMD" "bool" "0" "1" ""
config_register_schema "LOG_SHOW_SQL" "bool" "0" "1" ""
config_register_schema "LOG_SHOW_BLOCK" "bool" "0" "1" ""
config_register_schema "LOG_SHOW_CONTEXT" "bool" "0" "0" ""
config_register_schema "LOG_STRUCTURED" "bool" "0" "0" ""

# Database schemas
config_register_schema "DB_ADMIN_USER" "string" "1" "" ""
config_register_schema "DB_ADMIN_PASSWORD" "string" "1" "" ""
config_register_schema "DB_CONNECTION_STRING" "string" "1" "" ""

# Data Pump schemas
config_register_schema "MAX_CONCURRENT_PROCESSES" "uint" "0" "4" ""
config_register_schema "PARALLEL_DEGREE" "uint" "0" "5" ""
config_register_schema "USE_DUMPFILES" "bool" "0" "0" ""
config_register_schema "ENABLE_RETRY" "bool" "0" "1" ""
config_register_schema "MAX_RETRY_ATTEMPTS" "uint" "0" "3" ""
config_register_schema "RETRY_DELAY" "uint" "0" "60" ""

# OCI schemas (required if USE_DUMPFILES=1)
config_register_schema "OCI_NAMESPACE" "string" "0" "" ""
config_register_schema "OCI_BUCKET_NAME" "string" "0" "" ""
config_register_schema "OCI_EXPORT_CREDENTIAL" "string" "0" "" ""
config_register_schema "OCI_IMPORT_CREDENTIAL" "string" "0" "" ""

# Validation schemas
config_register_schema "VALIDATE_CONNECTIVITY" "bool" "0" "1" ""
config_register_schema "VALIDATE_NETWORK_LINK" "bool" "0" "1" ""
config_register_schema "VALIDATE_PARFILES" "bool" "0" "1" ""
config_register_schema "VALIDATE_DISK_SPACE" "bool" "0" "1" ""
config_register_schema "MIN_FREE_SPACE_GB" "uint" "0" "10" ""
