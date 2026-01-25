#!/usr/bin/env bash
# shellcheck shell=bash
#===============================================================================
# Datacosmos - Keyring Management Module
#
# Copyright (c) 2026 Datacosmos
# Licensed under the Apache License, Version 2.0
#===============================================================================
# File    : keyring.sh
# Version : 1.0.0
# Date    : 2026-01-16
#===============================================================================
#
# DESCRIPTION:
#   Secure credential management using encrypted keyring files.
#   - Stores database credentials encrypted with AES-256-CBC
#   - Single master password to unlock all credentials
#   - Environment-based organization (1 database = 1 environment)
#   - Secure prompts that work even with AUTO_YES=1
#
# DEPENDS ON:
#   - runtime.sh (file operations, assertions)
#   - logging.sh (log functions)
#
# PROVIDES:
#   Keyring Management:
#     - keyring_init()              - Create new keyring file
#     - keyring_open()              - Open keyring with master password
#     - keyring_close()             - Close keyring (clear from memory)
#     - keyring_is_open()           - Check if keyring is open
#     - keyring_save()              - Save keyring to file
#
#   Environment Management:
#     - keyring_env_add()           - Add environment (interactive)
#     - keyring_env_get()           - Get field from environment
#     - keyring_env_set()           - Set field in environment
#     - keyring_env_list()          - List all environments
#     - keyring_env_remove()        - Remove environment
#     - keyring_env_export()        - Export environment to shell vars
#
#   Secure Prompts:
#     - keyring_prompt_secret()     - Secure password prompt (read -s)
#     - keyring_prompt_value()      - Regular prompt with default
#     - keyring_require_secret()    - Get from keyring or prompt
#
# REPORT INTEGRATION:
#   - Tracked Steps: keyring_open, keyring_env_export
#   - Tracked Items: environment loaded, credentials source
#   - Tracked Metrics: keyring_envs_loaded
#   - Integration is graceful (NO-OP without report_init)
#
#===============================================================================

# Prevent double sourcing
[[ -n "${__KEYRING_LOADED:-}" ]] && return 0
__KEYRING_LOADED=1

# Resolve library directory
_KEYRING_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load dependencies
# shellcheck source=/dev/null
[[ -z "${__RUNTIME_LOADED:-}" ]] && source "${_KEYRING_LIB_DIR}/runtime.sh"
# shellcheck source=/dev/null
[[ -z "${__LOGGING_LOADED:-}" ]] && source "${_KEYRING_LIB_DIR}/logging.sh"

#===============================================================================
# SECTION 0: Configuration and State
#===============================================================================

# Default keyring file location
KEYRING_FILE="${KEYRING_FILE:-${HOME}/.oracle_keyring.enc}"
KEYRING_VERSION="1.0"

# Internal state (cleared on close)
_KEYRING_DATA=""
_KEYRING_MASTER_KEY=""
_KEYRING_OPEN=0

#===============================================================================
# SECTION 1: Encryption Helpers
#===============================================================================

# _keyring_derive_key - Derive encryption key from master password
# Usage: _keyring_derive_key "password" "salt"
# Returns: Base64 encoded key via stdout
_keyring_derive_key() {
    local password="$1" salt="$2"
    # Use PBKDF2-like derivation via openssl
    echo -n "${password}${salt}" | openssl dgst -sha256 -binary | base64
}

# _keyring_encrypt - Encrypt data with AES-256-CBC
# Usage: echo "data" | _keyring_encrypt "key"
# Returns: Base64 encoded encrypted data via stdout
_keyring_encrypt() {
    local key="$1"
    openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -salt -base64 -pass "pass:${key}"
}

# _keyring_decrypt - Decrypt data with AES-256-CBC
# Usage: echo "encrypted_base64" | _keyring_decrypt "key"
# Returns: Decrypted data via stdout
_keyring_decrypt() {
    local key="$1"
    openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -d -base64 -pass "pass:${key}" 2>/dev/null
}

# _keyring_encrypt_value - Encrypt a single value
# Usage: _keyring_encrypt_value "value"
# Returns: Base64 encoded encrypted value
_keyring_encrypt_value() {
    local value="$1"
    echo -n "${value}" | _keyring_encrypt "${_KEYRING_MASTER_KEY}"
}

# _keyring_decrypt_value - Decrypt a single value
# Usage: _keyring_decrypt_value "encrypted_base64"
# Returns: Decrypted value
_keyring_decrypt_value() {
    local encrypted="$1"
    echo "${encrypted}" | _keyring_decrypt "${_KEYRING_MASTER_KEY}"
}

#===============================================================================
# SECTION 2: Keyring Management
#===============================================================================

# keyring_init - Create new keyring file
# Usage: keyring_init [keyring_file]
# Returns: 0 on success, 1 on failure
keyring_init() {
    local file="${1:-${KEYRING_FILE}}"

    if [[ -f "${file}" ]]; then
        log_error "Keyring already exists: ${file}"
        log_error "Use keyring_open to open existing keyring"
        return 1
    fi

    log "Creating new keyring: ${file}"

    # Prompt for master password (twice for confirmation)
    local password password2
    keyring_prompt_secret "password" "Enter master password"
    keyring_prompt_secret "password2" "Confirm master password"

    if [[ "${password}" != "${password2}" ]]; then
        log_error "Passwords do not match"
        return 1
    fi

    if [[ ${#password} -lt 8 ]]; then
        log_error "Password must be at least 8 characters"
        return 1
    fi

    # Generate salt and derive key
    local salt
    salt=$(openssl rand -hex 16)
    _KEYRING_MASTER_KEY=$(_keyring_derive_key "${password}" "${salt}")

    # Create initial keyring structure
    local created
    created=$(date -Iseconds)
    _KEYRING_DATA=$(cat <<EOF
{
  "version": "${KEYRING_VERSION}",
  "created": "${created}",
  "salt": "${salt}",
  "environments": {}
}
EOF
)

    # Save to file
    KEYRING_FILE="${file}"
    if keyring_save; then
        _KEYRING_OPEN=1
        log_success "Keyring created: ${file}"
        report_track_item "ok" "Keyring" "created"
        return 0
    else
        log_error "Failed to save keyring"
        return 1
    fi
}

# keyring_open - Open existing keyring with master password
# Usage: keyring_open [keyring_file]
# Returns: 0 on success, 1 on failure
keyring_open() {
    local file="${1:-${KEYRING_FILE}}"

    if [[ ${_KEYRING_OPEN} -eq 1 ]]; then
        log_debug "Keyring already open"
        return 0
    fi

    if [[ ! -f "${file}" ]]; then
        log_debug "Keyring file not found: ${file}"
        return 1
    fi

    report_track_step "Opening keyring"

    # Prompt for master password
    local password
    keyring_prompt_secret "password" "Enter keyring master password"

    # Read encrypted file and extract salt
    local encrypted_data salt
    encrypted_data=$(cat "${file}")

    # Try to decrypt
    # First, we need to get the salt from the decrypted data
    # The file format is: encrypted JSON containing the salt
    local decrypted
    decrypted=$(echo "${encrypted_data}" | _keyring_decrypt "${password}" 2>/dev/null)

    if [[ -z "${decrypted}" ]]; then
        # Try with derived key (in case salt was used)
        # For first version, try direct password
        log_error "Invalid master password or corrupted keyring"
        return 1
    fi

    # Validate JSON structure
    if ! echo "${decrypted}" | jq -e '.version' >/dev/null 2>&1; then
        log_error "Invalid keyring format"
        return 1
    fi

    # Extract salt and re-derive key for value decryption
    salt=$(echo "${decrypted}" | jq -r '.salt // empty')
    if [[ -n "${salt}" ]]; then
        _KEYRING_MASTER_KEY=$(_keyring_derive_key "${password}" "${salt}")
    else
        _KEYRING_MASTER_KEY="${password}"
    fi

    _KEYRING_DATA="${decrypted}"
    KEYRING_FILE="${file}"
    _KEYRING_OPEN=1

    local env_count
    env_count=$(echo "${_KEYRING_DATA}" | jq '.environments | length')
    log_success "Keyring opened: ${env_count} environment(s)"
    report_track_item "ok" "Keyring" "opened (${env_count} envs)"

    return 0
}

# keyring_close - Close keyring and clear from memory
# Usage: keyring_close
keyring_close() {
    _KEYRING_DATA=""
    _KEYRING_MASTER_KEY=""
    _KEYRING_OPEN=0
    log_debug "Keyring closed"
}

# keyring_is_open - Check if keyring is open
# Usage: keyring_is_open && echo "open"
# Returns: 0 if open, 1 if closed
keyring_is_open() {
    [[ ${_KEYRING_OPEN} -eq 1 ]]
}

# keyring_save - Save keyring to file
# Usage: keyring_save
# Returns: 0 on success, 1 on failure
keyring_save() {
    if [[ ${_KEYRING_OPEN} -ne 1 ]]; then
        log_error "Keyring not open"
        return 1
    fi

    # Encrypt and save
    local encrypted
    encrypted=$(echo "${_KEYRING_DATA}" | _keyring_encrypt "${_KEYRING_MASTER_KEY}")

    if echo "${encrypted}" > "${KEYRING_FILE}"; then
        chmod 600 "${KEYRING_FILE}"
        log_debug "Keyring saved: ${KEYRING_FILE}"
        return 0
    else
        log_error "Failed to write keyring file"
        return 1
    fi
}

#===============================================================================
# SECTION 3: Environment Management
#===============================================================================

# keyring_env_add - Add new environment (interactive)
# Usage: keyring_env_add "env_name"
# Returns: 0 on success
keyring_env_add() {
    local env_name="$1"
    rt_assert_nonempty "env_name" "${env_name}"

    if ! keyring_is_open; then
        log_error "Keyring not open"
        return 1
    fi

    # Check if exists
    local exists
    exists=$(echo "${_KEYRING_DATA}" | jq -r ".environments.\"${env_name}\" // empty")
    if [[ -n "${exists}" ]]; then
        log_warning "Environment '${env_name}' already exists. Updating..."
    fi

    log "Adding environment: ${env_name}"

    # Prompt for values
    local user password tns dbid
    keyring_prompt_value "user" "Database user" "admin"
    keyring_prompt_secret "password" "Database password"
    keyring_prompt_value "tns" "TNS alias / connection string" ""
    keyring_prompt_value "dbid" "Database ID (optional)" ""

    # Encrypt password
    local encrypted_password
    encrypted_password=$(_keyring_encrypt_value "${password}")

    # Update keyring data
    _KEYRING_DATA=$(echo "${_KEYRING_DATA}" | jq \
        --arg env "${env_name}" \
        --arg user "${user}" \
        --arg pass "${encrypted_password}" \
        --arg tns "${tns}" \
        --arg dbid "${dbid}" \
        '.environments[$env] = {
            "user": $user,
            "password": $pass,
            "tns": $tns,
            "dbid": $dbid
        }')

    if keyring_save; then
        log_success "Environment '${env_name}' added"
        report_track_item "ok" "Environment" "${env_name} added"
        return 0
    fi
    return 1
}

# keyring_env_get - Get field from environment
# Usage: keyring_env_get "env_name" "field"
# Returns: Field value via stdout (password is decrypted)
keyring_env_get() {
    local env_name="$1" field="$2"
    rt_assert_nonempty "env_name" "${env_name}"
    rt_assert_nonempty "field" "${field}"

    if ! keyring_is_open; then
        return 1
    fi

    local value
    value=$(echo "${_KEYRING_DATA}" | jq -r ".environments.\"${env_name}\".\"${field}\" // empty")

    if [[ -z "${value}" ]]; then
        return 1
    fi

    # Decrypt password field
    if [[ "${field}" == "password" ]]; then
        _keyring_decrypt_value "${value}"
    else
        echo "${value}"
    fi
}

# keyring_env_set - Set field in environment
# Usage: keyring_env_set "env_name" "field" "value"
# Returns: 0 on success
keyring_env_set() {
    local env_name="$1" field="$2" value="$3"
    rt_assert_nonempty "env_name" "${env_name}"
    rt_assert_nonempty "field" "${field}"

    if ! keyring_is_open; then
        log_error "Keyring not open"
        return 1
    fi

    # Encrypt password field
    if [[ "${field}" == "password" ]]; then
        value=$(_keyring_encrypt_value "${value}")
    fi

    _KEYRING_DATA=$(echo "${_KEYRING_DATA}" | jq \
        --arg env "${env_name}" \
        --arg field "${field}" \
        --arg value "${value}" \
        '.environments[$env][$field] = $value')

    keyring_save
}

# keyring_env_list - List all environments
# Usage: keyring_env_list
# Returns: List of environment names via stdout
keyring_env_list() {
    if ! keyring_is_open; then
        log_error "Keyring not open"
        return 1
    fi

    echo "${_KEYRING_DATA}" | jq -r '.environments | keys[]'
}

# keyring_env_remove - Remove environment
# Usage: keyring_env_remove "env_name"
# Returns: 0 on success
keyring_env_remove() {
    local env_name="$1"
    rt_assert_nonempty "env_name" "${env_name}"

    if ! keyring_is_open; then
        log_error "Keyring not open"
        return 1
    fi

    _KEYRING_DATA=$(echo "${_KEYRING_DATA}" | jq \
        --arg env "${env_name}" \
        'del(.environments[$env])')

    if keyring_save; then
        log_success "Environment '${env_name}' removed"
        return 0
    fi
    return 1
}

# keyring_env_export - Export environment to shell variables
# Usage: keyring_env_export "env_name"
#        eval $(keyring_env_export "env_name")
# Returns: Shell export statements via stdout
keyring_env_export() {
    local env_name="$1"
    rt_assert_nonempty "env_name" "${env_name}"

    if ! keyring_is_open; then
        # Try to open
        if ! keyring_open; then
            return 1
        fi
    fi

    local user password tns dbid
    user=$(keyring_env_get "${env_name}" "user") || return 1
    password=$(keyring_env_get "${env_name}" "password") || return 1
    tns=$(keyring_env_get "${env_name}" "tns") || return 1
    dbid=$(keyring_env_get "${env_name}" "dbid")

    # Export to current shell if not in subshell mode
    if [[ -t 1 ]]; then
        # Interactive - export directly
        export DB_ADMIN_USER="${user}"
        export DB_ADMIN_PASSWORD="${password}"
        export DB_CONNECTION_STRING="${tns}"
        [[ -n "${dbid}" ]] && export DBID="${dbid}"
        log_debug "Credentials exported for ${env_name}"
        report_track_item "ok" "Credentials" "${env_name} exported"
        report_track_metric "keyring_envs_loaded" "1" "add"
    else
        # Piped - output export statements for eval
        echo "export DB_ADMIN_USER='${user}'"
        echo "export DB_ADMIN_PASSWORD='${password}'"
        echo "export DB_CONNECTION_STRING='${tns}'"
        [[ -n "${dbid}" ]] && echo "export DBID='${dbid}'"
    fi

    return 0
}

#===============================================================================
# SECTION 4: Secure Prompts
#===============================================================================

# keyring_prompt_secret - Prompt for secret (does not echo, ignores AUTO_YES)
# Usage: keyring_prompt_secret "varname" "prompt"
# Returns: Sets variable with name $varname
keyring_prompt_secret() {
    local varname="$1" prompt="$2"

    # ALWAYS prompt for secrets, even with AUTO_YES
    echo -n "${prompt}: " >&2
    read -rs "${varname?}"
    echo >&2  # Newline after silent input

    # Export to caller's scope
    printf -v "${varname}" '%s' "${!varname}"
}

# keyring_prompt_value - Prompt for value with default
# Usage: keyring_prompt_value "varname" "prompt" ["default"]
# Returns: Sets variable with name $varname
keyring_prompt_value() {
    local varname="$1" prompt="$2" default="${3:-}"

    if [[ -n "${default}" ]]; then
        echo -n "${prompt} [${default}]: " >&2
    else
        echo -n "${prompt}: " >&2
    fi

    local value
    read -r value

    if [[ -z "${value}" ]] && [[ -n "${default}" ]]; then
        value="${default}"
    fi

    printf -v "${varname}" '%s' "${value}"
}

# keyring_require_secret - Get secret from keyring or prompt
# Usage: keyring_require_secret "varname" "env_name" "field" "prompt"
# Returns: Sets variable, from keyring if open, otherwise prompts
keyring_require_secret() {
    local varname="$1" env_name="$2" field="$3" prompt="$4"

    # Try keyring first
    if keyring_is_open; then
        local value
        value=$(keyring_env_get "${env_name}" "${field}")
        if [[ -n "${value}" ]]; then
            printf -v "${varname}" '%s' "${value}"
            log_debug "Secret '${field}' loaded from keyring"
            return 0
        fi
    fi

    # Fallback to prompt
    keyring_prompt_secret "${varname}" "${prompt}"
}

#===============================================================================
# SECTION 5: Report Integration (Graceful NO-OP)
#===============================================================================

# Wrapper functions that gracefully handle missing report.sh
report_track_step() {
    type -t report_step &>/dev/null && report_step "$@" || true
}

report_track_item() {
    type -t report_item &>/dev/null && report_item "$@" || true
}

report_track_metric() {
    type -t report_metric &>/dev/null && report_metric "$@" || true
}

#===============================================================================
# END: keyring.sh
#===============================================================================
