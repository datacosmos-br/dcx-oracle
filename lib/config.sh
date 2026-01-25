#!/usr/bin/env bash
# shellcheck shell=bash
#===============================================================================
# Datacosmos - Configuration Loading Library
# Copyright (c) 2026 Datacosmos - Apache License 2.0
#===============================================================================
# File: config.sh | Version: 2.0.0 | Date: 2026-01-15
#===============================================================================
#
# DESCRIPTION:
#   Advanced configuration management with hierarchical loading, validation,
#   profiles, and integration with logging. Supports:
#   - Hierarchical config: defaults -> global -> local -> env
#   - Schema validation (types, ranges, required fields)
#   - Profile-based configuration (dev, prod, test)
#   - Automatic logging of loaded configurations
#   - Centralized defaults management
#   - Secure credential loading with fallback chain:
#     wallet -> keyring -> env vars -> config file -> prompt
#
# PROVIDES:
#   Credential Management:
#     - config_load_credentials()    - Load credentials with fallback chain
#     - config_require_secret()      - Get secret value (keyring or prompt)
#
#===============================================================================

[[ -n "${__CONFIG_LOADED:-}" ]] && return 0
__CONFIG_LOADED=1

_CONFIG_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load runtime.sh if not already loaded (for die, warn, etc.)
# Note: This module can be loaded directly OR via core.sh
# shellcheck source=/dev/null
[[ -z "${__RUNTIME_LOADED:-}" ]] && source "${_CONFIG_LIB_DIR}/runtime.sh" || true

# Load logging.sh if not already loaded (for log, log_debug, etc.)
# shellcheck source=/dev/null
[[ -z "${__LOGGING_LOADED:-}" ]] && source "${_CONFIG_LIB_DIR}/logging.sh" || true

#===============================================================================
# Configuration State
#===============================================================================

# Track loaded config files
declare -ga CONFIG_LOADED_FILES=()

# Track config sources (for debugging)
declare -gA CONFIG_SOURCES

# Schema registry: var_name -> "type|required|default|allowed_values"
declare -gA CONFIG_SCHEMA

# Profile detection
CONFIG_PROFILE="${CONFIG_PROFILE:-${ENV:-prod}}"

#===============================================================================
# SECTION 1: Basic Configuration Loading (Backward Compatible)
#===============================================================================

# config_load - Load key=value configuration file
# Usage: config_load "/etc/myapp/config.conf"
config_load() {
    local config_file="$1"
    local respect_env="${2:-0}"  # If 1, don't override existing env vars
    [[ -f "${config_file}" ]] || die "Config not found: ${config_file}"

    local line key val
    while IFS= read -r line || [[ -n "${line}" ]]; do
        [[ "${line}" =~ ^[[:space:]]*# ]] && continue
        [[ "${line}" =~ ^[[:space:]]*$ ]] && continue
        if [[ "${line}" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"
            val="${BASH_REMATCH[2]}"
            # Remove quotes if present
            val="${val#\"}"; val="${val%\"}"
            val="${val#\'}"; val="${val%\'}"
            # Evaluate expressions like $(cd ... && pwd) if they exist
            if [[ "${val}" =~ ^\$\( ]]; then
                val=$(eval "echo ${val}")
            fi
            # Respect environment variables if requested
            if [[ ${respect_env} -eq 1 ]] && [[ -n "${!key:-}" ]]; then
                log_debug "Skipping ${key} (already set in environment)"
                continue
            fi
            export "${key}=${val}"
            CONFIG_SOURCES[$key]="$config_file"
        fi
    done < "${config_file}"
    
    CONFIG_LOADED_FILES+=("${config_file}")
    log_debug "Config loaded: ${config_file}"
}

# config_load_with_defaults - Load config with defaults validation
# Usage: config_load_with_defaults "/path/config.conf" "VAR1=default1" "VAR2=default2"
config_load_with_defaults() {
    local config_file="$1"; shift

    # Set defaults first
    local kv key val
    for kv in "$@"; do
        key="${kv%%=*}"
        val="${kv#*=}"
        [[ -z "${!key:-}" ]] && export "${key}=${val}" || true
    done

    # Load config (overrides defaults)
    [[ -f "${config_file}" ]] && config_load "${config_file}" || true
}

# runtime_require_vars - Validate required variables are set
# Usage: runtime_require_vars "DB_USER" "DB_PASSWORD" "DB_HOST"
runtime_require_vars() {
    local var
    for var in "$@"; do
        [[ -n "${!var:-}" ]] || die "Required variable not set: ${var}"
    done
}

# runtime_set_default - Set variable if not already set
# Usage: runtime_set_default "VAR" "default_value"
runtime_set_default() {
    local var="$1" default="$2"
    [[ -z "${!var:-}" ]] && export "${var}=${default}" || true
}

#===============================================================================
# SECTION 2: Hierarchical Configuration Loading
#===============================================================================

# config_load_hierarchical - Load configuration hierarchically
# Usage: config_load_hierarchical "app_name" ["/etc/app.conf"] ["./config/app.conf"]
# Order: defaults -> global -> local -> env vars (env vars have final precedence)
config_load_hierarchical() {
    local app_name="$1"
    local global_config="${2:-/etc/${app_name}.conf}"
    local local_config="${3:-./config/${app_name}.conf}"
    
    log_debug "Loading hierarchical config for: ${app_name}"
    
    # Snapshot environment variables BEFORE loading (to preserve them)
    declare -A env_before
    local var_name
    while IFS='=' read -r var_name _ || [[ -n "${var_name}" ]]; do
        [[ -z "${var_name}" ]] && continue
        # Only capture exported variables
        if declare -p "${var_name}" 2>/dev/null | grep -q "^declare -x"; then
            env_before[$var_name]="${!var_name:-}"
        fi
    done < <(compgen -e | sort)
    
    # 1. Load defaults (if config_defaults.sh exists)
    local defaults_file="${_CONFIG_LIB_DIR}/config_defaults.sh"
    if [[ -f "${defaults_file}" ]] && [[ -z "${__CONFIG_DEFAULTS_LOADED:-}" ]]; then
        # shellcheck source=/dev/null
        source "${defaults_file}"
        log_debug "Defaults loaded from: ${defaults_file}"
    fi
    
    # 2. Load global config (if exists)
    if [[ -f "${global_config}" ]]; then
        config_load "${global_config}" 0
        log_debug "Global config loaded: ${global_config}"
    fi

    # 3. Load local config (if exists, overrides global)
    if [[ -f "${local_config}" ]]; then
        config_load "${local_config}" 0
        log_debug "Local config loaded: ${local_config}"
    fi
    
    # 4. Restore environment variables that were set BEFORE loading
    # This gives env vars final precedence
    for var_name in "${!env_before[@]}"; do
        if [[ -n "${env_before[$var_name]}" ]]; then
            export "${var_name}=${env_before[$var_name]}"
            log_debug "Restored env var: ${var_name}"
        fi
    done
    
    log_debug "Environment variables have final precedence"
}

#===============================================================================
# SECTION 3: Profile-Based Configuration
#===============================================================================

# config_load_profile - Load configuration for specific profile
# Usage: config_load_profile "dev" "/path/to/config"
config_load_profile() {
    local profile="$1"
    local config_base="${2:-./config}"
    
    local profile_file="${config_base}/profiles/${profile}.conf"
    
    if [[ -f "${profile_file}" ]]; then
        config_load "${profile_file}"
        log "Profile loaded: ${profile} from ${profile_file}"
        CONFIG_PROFILE="${profile}"
        export CONFIG_PROFILE
    else
        warn "Profile file not found: ${profile_file}"
        return 1
    fi
}

# config_detect_profile - Detect profile from environment or config
# Usage: PROFILE=$(config_detect_profile)
config_detect_profile() {
    # Check explicit CONFIG_PROFILE
    [[ -n "${CONFIG_PROFILE:-}" ]] && { echo "${CONFIG_PROFILE}"; return 0; }
    
    # Check ENV variable
    [[ -n "${ENV:-}" ]] && { echo "${ENV}"; return 0; }
    
    # Check common environment indicators
    [[ -n "${USER:-}" ]] && [[ "${USER}" == *dev* ]] && { echo "dev"; return 0; }
    [[ -n "${HOSTNAME:-}" ]] && [[ "${HOSTNAME}" == *test* ]] && { echo "test"; return 0; }
    
    # Default to prod
    echo "prod"
}

# config_load_with_profile - Load config with automatic profile detection
# Usage: config_load_with_profile "app_name" "/path/to/config"
config_load_with_profile() {
    local app_name="$1"
    local config_base="${2:-./config}"
    
    # Detect profile
    local profile
    profile=$(config_detect_profile)
    
    # Load base config
    config_load_hierarchical "${app_name}" "${config_base}/${app_name}.conf"
    
    # Load profile-specific config
    config_load_profile "${profile}" "${config_base}" || true
}

#===============================================================================
# SECTION 4: Schema Validation
#===============================================================================

# config_register_schema - Register schema for a configuration variable
# Usage: config_register_schema "VAR_NAME" "type" "required" "default" "allowed_values"
# Types: string, int, uint, bool, enum, path, url
config_register_schema() {
    local _schema_var="$1"
    local _schema_type="$2"
    local _schema_required="${3:-0}"
    local _schema_default="${4:-}"
    local _schema_allowed="${5:-}"
    local _schema_value="${_schema_type}|${_schema_required}|${_schema_default}|${_schema_allowed}"
    
    # Avoid subscript evaluation issues with set -u by using underscore-prefixed locals
    CONFIG_SCHEMA["$_schema_var"]="$_schema_value"
}

# config_validate_schema - Validate configuration against registered schema
# Usage: config_validate_schema
config_validate_schema() {
    local errors=0
    local var
    
    for var in "${!CONFIG_SCHEMA[@]}"; do
        local schema="${CONFIG_SCHEMA[$var]}"
        local type="${schema%%|*}"
        schema="${schema#*|}"
        local required="${schema%%|*}"
        schema="${schema#*|}"
        local default="${schema%%|*}"
        local allowed="${schema#*|}"
        
        local value="${!var:-}"
        
        # Check required
        if [[ "${required}" == "1" ]] && [[ -z "${value}" ]]; then
            warn "Required config missing: ${var}"
            errors=$((errors + 1))
            continue
        fi
        
        # Set default if empty
        if [[ -z "${value}" ]] && [[ -n "${default}" ]]; then
            export "${var}=${default}"
            value="${default}"
            log_debug "Set default for ${var}: ${default}"
        fi
        
        # Skip validation if empty (and not required)
        [[ -z "${value}" ]] && continue
        
        # Validate type
        case "${type}" in
            int)
                [[ "${value}" =~ ^-?[0-9]+$ ]] || {
                    warn "Invalid int for ${var}: ${value}"
                    errors=$((errors + 1))
                }
                ;;
            uint)
                [[ "${value}" =~ ^[0-9]+$ ]] || {
                    warn "Invalid uint for ${var}: ${value}"
                    errors=$((errors + 1))
                }
                ;;
            bool)
                [[ "${value}" == "0" || "${value}" == "1" || "${value}" == "true" || "${value}" == "false" ]] || {
                    warn "Invalid bool for ${var}: ${value} (use 0|1|true|false)"
                    errors=$((errors + 1))
                }
                ;;
            enum)
                if [[ -n "${allowed}" ]]; then
                    local found=0
                    local av
                    for av in ${allowed}; do
                        [[ "${value}" == "${av}" ]] && { found=1; break; }
                    done
                    [[ ${found} -eq 1 ]] || {
                        warn "Invalid enum for ${var}: ${value} (allowed: ${allowed})"
                        errors=$((errors + 1))
                    }
                fi
                ;;
            path)
                [[ "${value}" == /* ]] || {
                    warn "Invalid path for ${var}: ${value} (must be absolute)"
                    errors=$((errors + 1))
                }
                ;;
            url)
                [[ "${value}" =~ ^https?:// ]] || {
                    warn "Invalid URL for ${var}: ${value}"
                    errors=$((errors + 1))
                }
                ;;
            string)
                # String is always valid
                ;;
            *)
                warn "Unknown schema type: ${type} for ${var}"
                errors=$((errors + 1))
                ;;
        esac
    done
    
    return ${errors}
}

#===============================================================================
# SECTION 5: Configuration Display & Logging
#===============================================================================

# config_print - Print configuration variables
# Usage: config_print "DB_USER" "DB_HOST" "DB_PORT"
config_print() {
    echo
    echo "==================== Configuration ===================="
    local var
    for var in "$@"; do
        local val="${!var:-<not set>}"
        # Mask passwords
        [[ "${var}" == *PASSWORD* || "${var}" == *SECRET* ]] && val="********"
        runtime_print_kv "${var}" "${val}"
    done
    echo "======================================================="
}

# config_log_loaded - Log all loaded configuration files
# Usage: config_log_loaded
config_log_loaded() {
    if [[ ${#CONFIG_LOADED_FILES[@]} -gt 0 ]]; then
        log "Configuration files loaded:"
        local file
        for file in "${CONFIG_LOADED_FILES[@]}"; do
            log "  - ${file}"
        done
    else
        log_debug "No configuration files loaded"
    fi
}

# config_print_sources - Print source of each configuration variable
# Usage: config_print_sources "VAR1" "VAR2"
config_print_sources() {
    echo
    echo "==================== Config Sources ===================="
    local var
    for var in "$@"; do
        local source="${CONFIG_SOURCES[$var]:-<environment>}"
        runtime_print_kv "${var}" "${source}"
    done
    echo "======================================================="
}

# config_print_schema - Print registered schema
# Usage: config_print_schema
config_print_schema() {
    echo
    echo "==================== Config Schema ===================="
    local var
    for var in "${!CONFIG_SCHEMA[@]}"; do
        local schema="${CONFIG_SCHEMA[$var]}"
        local type="${schema%%|*}"
        schema="${schema#*|}"
        local required="${schema%%|*}"
        schema="${schema#*|}"
        local default="${schema%%|*}"
        local allowed="${schema#*|}"
        
        local req_str="optional"
        [[ "${required}" == "1" ]] && req_str="required"
        
        echo "  ${var}:"
        echo "    Type: ${type}"
        echo "    Required: ${req_str}"
        [[ -n "${default}" ]] && echo "    Default: ${default}"
        [[ -n "${allowed}" ]] && echo "    Allowed: ${allowed}"
    done
    echo "======================================================="
}

#===============================================================================
# SECTION 6: Environment Detection (Backward Compatible)
#===============================================================================

# runtime_detect_script_dir - Get directory of calling script
runtime_detect_script_dir() {
    cd "$(dirname "${BASH_SOURCE[1]}")" && pwd
}

# runtime_detect_project_root - Find project root (looks for marker files)
runtime_detect_project_root() {
    local dir="$PWD"
    local markers=(".git" "CLAUDE.md" "migration.conf")

    while [[ "${dir}" != "/" ]]; do
        for marker in "${markers[@]}"; do
            [[ -e "${dir}/${marker}" ]] && { echo "${dir}"; return 0; }
        done
        dir="$(dirname "${dir}")"
    done

    echo "$PWD"
}

#===============================================================================
# SECTION 7: Legacy Functions (Backward Compatible)
#===============================================================================

# runtime_export_vars - Export variables to environment
runtime_export_vars() {
    local kv key val
    for kv in "$@"; do
        key="${kv%%=*}"
        val="${kv#*=}"
        export "${key}=${val}"
    done
}

#===============================================================================
# SECTION 8: Credential Management
#===============================================================================
# This section provides credential loading with automatic fallback chain:
#   1. Oracle Wallet (if wallet dir exists with cwallet.sso)
#   2. Keyring (if keyring.sh loaded and keyring opened)
#   3. Environment variables (DB_ADMIN_USER, DB_ADMIN_PASSWORD, etc.)
#   4. Configuration file (migration.conf - NOT recommended for secrets)
#   5. Interactive prompt (IGNORES AUTO_YES for security)
#
# The goal is to NEVER have passwords stored in plain text config files.
#===============================================================================

# config_load_credentials - Load credentials using fallback chain
# Usage: config_load_credentials "env_name"
# Chain: wallet -> keyring -> env vars -> config file -> prompt
# Returns: 0 on success (credentials loaded), 1 on failure
config_load_credentials() {
    local env="${1:-DEFAULT}"
    local source="unknown"

    log "Loading credentials for environment: ${env}"

    # 1. Check for Oracle Wallet
    local wallet_dir="${WALLET_BASE:-$HOME/.wallets}/${env}"
    if type -t oracle_sql_wallet_exists &>/dev/null && oracle_sql_wallet_exists "${wallet_dir}"; then
        if type -t oracle_sql_set_wallet_connection &>/dev/null; then
            local tns="${DB_TNS_ALIAS:-${env}}"
            oracle_sql_set_wallet_connection "${tns}" "${wallet_dir}"
            source="wallet"
            log_success "Credentials loaded from wallet: ${wallet_dir}"
            report_track_item "ok" "Credentials" "wallet (${env})"
            return 0
        fi
    fi

    # 2. Try keyring
    if type -t keyring_is_open &>/dev/null; then
        # Try to open keyring if not already open
        if ! keyring_is_open; then
            if type -t keyring_open &>/dev/null; then
                log_debug "Attempting to open keyring..."
                keyring_open 2>/dev/null || true
            fi
        fi

        if keyring_is_open; then
            if type -t keyring_env_export &>/dev/null; then
                if keyring_env_export "${env}" 2>/dev/null; then
                    source="keyring"
                    log_success "Credentials loaded from keyring: ${env}"
                    report_track_item "ok" "Credentials" "keyring (${env})"
                    return 0
                fi
            fi
        fi
    fi

    # 3. Check environment variables
    if [[ -n "${DB_ADMIN_PASSWORD:-}" ]]; then
        source="environment"
        log_success "Credentials found in environment variables"
        report_track_item "ok" "Credentials" "environment"
        return 0
    fi

    # 4. Check if loaded from config file
    if [[ -n "${CONFIG_SOURCES[DB_ADMIN_PASSWORD]:-}" ]]; then
        source="config_file"
        log_warning "Credentials loaded from config file (NOT recommended for production)"
        report_track_item "warn" "Credentials" "config file (insecure)"
        return 0
    fi

    # 5. Fallback: interactive prompt (ALWAYS prompts, even with AUTO_YES=1)
    log_warning "No credentials found - prompting for password"
    log_warning "Consider using 'keyring.sh env add ${env}' to store credentials securely"

    if type -t keyring_prompt_secret &>/dev/null; then
        keyring_prompt_secret "DB_ADMIN_PASSWORD" "Password for ${env}"
    else
        # Fallback if keyring.sh not loaded
        echo -n "Password for ${env}: " >&2
        read -rs DB_ADMIN_PASSWORD
        echo >&2
        export DB_ADMIN_PASSWORD
    fi

    if [[ -z "${DB_ADMIN_PASSWORD:-}" ]]; then
        log_error "No password provided"
        return 1
    fi

    source="prompt"
    report_track_item "warn" "Credentials" "interactive prompt"
    return 0
}

# config_require_secret - Get a secret value (from keyring or prompt)
# Usage: config_require_secret "VAR_NAME" "prompt message"
# This function IGNORES AUTO_YES for security
config_require_secret() {
    local var_name="$1"
    local prompt_msg="${2:-Enter ${var_name}}"

    # If already set in environment, use it
    if [[ -n "${!var_name:-}" ]]; then
        log_debug "Secret ${var_name} already in environment"
        return 0
    fi

    # Try keyring first
    if type -t keyring_require_secret &>/dev/null && keyring_is_open 2>/dev/null; then
        keyring_require_secret "${var_name}" "${prompt_msg}"
        return $?
    fi

    # Fallback to secure prompt
    local value
    echo -n "${prompt_msg}: " >&2
    read -rs value
    echo >&2

    if [[ -z "${value}" ]]; then
        log_error "No value provided for ${var_name}"
        return 1
    fi

    export "${var_name}=${value}"
    return 0
}

#===============================================================================
# END: config.sh
#===============================================================================
