#!/usr/bin/env bash
# shellcheck shell=bash
#===============================================================================
# DCX-Oracle Configuration Precedence Enforcement
# ================================================
# Implements the strict configuration precedence chain required by
# PLUGIN_CONTRACT.md:
#   1. Environment Variables (ORACLE_*, DB_*, SOURCE_*, NETWORK_*, OCI_*, TNS_*)
#   2. DCX Runtime Context (DC_* variables)
#   3. Plugin Configuration File (local.conf)
#   4. Global Configuration File (~/.dcx/config or /etc/dcx/config)
#   5. Default Configuration (defaults.conf)
#
# This module ensures reliable, deterministic config resolution with
# fail-fast behavior and no silent fallbacks.
#===============================================================================

[[ -n "${__CONFIG_PRECEDENCE_LOADED:-}" ]] && return 0
__CONFIG_PRECEDENCE_LOADED=1

# List of allowed config variable prefixes
# These correspond to Oracle/database/network configuration
declare -ga CONFIG_ALLOWED_PREFIXES=(
	"ORACLE"  # Oracle database settings: ORACLE_SID, ORACLE_HOME, etc.
	"DB"      # Database connection: DB_HOST, DB_PORT, DB_SERVICE, etc.
	"SOURCE"  # Source database: SOURCE_DB_HOST, SOURCE_DB_UNIQUE_NAME, etc.
	"TARGET"  # Target database: TARGET_DB_HOST, TARGET_DB_UNIQUE_NAME, etc.
	"NETWORK" # Network settings: NETWORK_LINK, NETWORK_PROTOCOL, etc.
	"OCI"     # OCI settings: OCI_REGION, OCI_COMPARTMENT, OCI_BUCKET, etc.
	"TNS"     # TNS config: TNS_ADMIN, TNS_NAMES_LOCATION, etc.
	"EXPORT"  # Export settings: EXPORT_DIR, EXPORT_FORMAT, etc.
	"IMPORT"  # Import settings: IMPORT_DIR, IMPORT_LOGDIR, etc.
	"LOG"     # Logging: LOG_LEVEL, LOG_DIR, LOG_FILE, etc.
	"DC"      # DCX context: DC_WORKSPACE_HOME, DC_PLUGIN_CONFIG, etc.
)

# Track configuration sources (for debugging and auditing)
declare -gA CONFIG_SOURCE_MAP   # variable -> source (env|dcx|plugin|global|defaults)
declare -ga CONFIG_LOADED_ORDER # list of config files loaded in order

#===============================================================================
# FUNCTION: config_validate_prefix
# PURPOSE: Verify a variable name uses allowed prefix
# ARGS: $1 = variable name
# RETURNS: 0 if valid, 1 if invalid
#===============================================================================
config_validate_prefix() {
	local varname="$1"
	[[ -z "$varname" ]] && die "config_validate_prefix: varname required"

	local prefix="${varname%%_*}" # Extract prefix before first underscore

	for allowed in "${CONFIG_ALLOWED_PREFIXES[@]}"; do
		if [[ "$prefix" == "$allowed" ]]; then
			return 0 # Valid prefix
		fi
	done

	# Invalid prefix
	die "CONFIG POLICY VIOLATION: Variable '$varname' uses disallowed prefix '$prefix'" \
		"Allowed prefixes: ${CONFIG_ALLOWED_PREFIXES[*]}"
}

#===============================================================================
# FUNCTION: config_resolve
# PURPOSE: Get config value respecting strict precedence chain
# USAGE: config_resolve ORACLE_PASSWORD [default_on_missing]
# ARGS:
#   $1 = variable name (MUST use allowed prefix)
#   $2 = default value (optional) - if set, use instead of failing on missing
# RETURNS: 0=success/1=not_found
# STDOUT: The resolved value
#
# PRECEDENCE (stops at first match):
#   1. Environment variable (highest priority)
#   2. DCX runtime context (DC_* variables)
#   3. Plugin config file (local.conf)
#   4. Global config file (~/.dcx/config or /etc/dcx/config)
#   5. Defaults (lowest priority)
#   6. Provided default parameter
#===============================================================================
config_resolve() {
	local varname="$1"
	local default_value="${2:-__MISSING__}"

	[[ -z "$varname" ]] && die "config_resolve: varname required"

	# Validate the prefix
	config_validate_prefix "$varname"

	# STEP 1: Check environment variables (highest priority)
	# These override everything
	if [[ -n "${!varname:-}" ]]; then
		CONFIG_SOURCE_MAP["$varname"]="env"
		echo "${!varname}"
		return 0
	fi

	# STEP 2: Check DCX runtime context
	# DCX_* variables take precedence over config files
	local dcx_var="DCX_${varname}"
	if [[ -n "${!dcx_var:-}" ]]; then
		CONFIG_SOURCE_MAP["$varname"]="dcx_context"
		echo "${!dcx_var}"
		return 0
	fi

	# STEP 3: Check plugin configuration file
	# Location: ${PLUGIN_DIR}/config/local.conf
	if [[ -v _PLUGIN_CONFIG_CACHE["$varname"] ]]; then
		CONFIG_SOURCE_MAP["$varname"]="plugin_config"
		echo "${_PLUGIN_CONFIG_CACHE[$varname]}"
		return 0
	fi

	# STEP 4: Check global configuration file
	# Location: ~/.dcx/config or /etc/dcx/config
	if [[ -v _GLOBAL_CONFIG_CACHE["$varname"] ]]; then
		CONFIG_SOURCE_MAP["$varname"]="global_config"
		echo "${_GLOBAL_CONFIG_CACHE[$varname]}"
		return 0
	fi

	# STEP 5: Check defaults configuration file
	# Location: ${PLUGIN_DIR}/config/defaults.conf
	if [[ -v _DEFAULTS_CONFIG_CACHE["$varname"] ]]; then
		CONFIG_SOURCE_MAP["$varname"]="defaults"
		echo "${_DEFAULTS_CONFIG_CACHE[$varname]}"
		return 0
	fi

	# STEP 6: Use provided default if given
	if [[ "$default_value" != "__MISSING__" ]]; then
		CONFIG_SOURCE_MAP["$varname"]="provided_default"
		echo "$default_value"
		return 0
	fi

	# NOT FOUND - Fail with clear error (no fallback, no prompting)
	cat >&2 <<EOF
CONFIG ERROR: Required configuration value not found: $varname

Checked (in precedence order):
  1. Environment variable: \$$varname
  2. DCX context: \$DCX_$varname
  3. Plugin config: ${PLUGIN_DIR}/config/local.conf
  4. Global config: ~/.dcx/config or /etc/dcx/config
  5. Defaults: ${PLUGIN_DIR}/config/defaults.conf

SOLUTION:
  - Export as environment variable: export $varname="value"
  - Or add to ~/.dcx/config: $varname=value
  - Or add to plugin config: ${PLUGIN_DIR}/config/local.conf

POLICY NOTE:
  The plugin does NOT prompt for missing values or fall back to
  hardcoded defaults. Configuration MUST be explicit.
EOF
	return 1 # NOT FOUND
}

#===============================================================================
# FUNCTION: config_get_or_die
# PURPOSE: Wrapper around config_resolve that dies on missing value
# USAGE: ORACLE_PASSWORD=$(config_get_or_die ORACLE_PASSWORD)
#===============================================================================
config_get_or_die() {
	local varname="$1"
	local result

	result=$(config_resolve "$varname") || {
		die "CONFIG POLICY: Required config not found: $varname"
	}

	echo "$result"
}

#===============================================================================
# FUNCTION: config_load_file_into_cache
# PURPOSE: Load key=value config file into cache
# ARGS:
#   $1 = file path
#   $2 = cache array name (_PLUGIN_CONFIG_CACHE, _GLOBAL_CONFIG_CACHE, etc.)
# RETURNS: Number of variables loaded
#===============================================================================
config_load_file_into_cache() {
	local config_file="$1"
	local cache_var="$2"

	[[ -f "$config_file" ]] || return 0 # Silent return if file doesn't exist

	[[ -n "$cache_var" ]] || die "config_load_file_into_cache: cache_var required"

	declare -gA "$cache_var" # Declare associative array

	local line key val count=0
	while IFS= read -r line || [[ -n "$line" ]]; do
		# Skip comments and empty lines
		[[ "$line" =~ ^[[:space:]]*# ]] && continue
		[[ "$line" =~ ^[[:space:]]*$ ]] && continue

		# Parse key=value
		if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
			key="${BASH_REMATCH[1]}"
			val="${BASH_REMATCH[2]}"

			# Remove surrounding quotes if present
			val="${val#\"}"
			val="${val%\"}"
			val="${val#\'}"
			val="${val%\'}"

			# Store in cache
			eval "${cache_var}[$key]='$val'"
			((count++))
		fi
	done <"$config_file"

	CONFIG_LOADED_ORDER+=("$config_file")
	return $count
}

#===============================================================================
# FUNCTION: config_load_precedence_chain
# PURPOSE: Initialize all configuration caches from precedence chain
# MUST be called once at startup before accessing config
#===============================================================================
config_load_precedence_chain() {
	log_debug "Loading configuration from precedence chain..."

	declare -gA _DEFAULTS_CONFIG_CACHE
	declare -gA _GLOBAL_CONFIG_CACHE
	declare -gA _PLUGIN_CONFIG_CACHE

	# Load in order: defaults -> global -> plugin
	# (env vars loaded at access time)

	local defaults_file="${PLUGIN_DIR:-}/config/defaults.conf"
	if [[ -f "$defaults_file" ]]; then
		config_load_file_into_cache "$defaults_file" "_DEFAULTS_CONFIG_CACHE"
		log_debug "Loaded defaults: $defaults_file"
	fi

	local global_config="${HOME}/.dcx/config"
	if [[ ! -f "$global_config" ]]; then
		global_config="/etc/dcx/config"
	fi

	if [[ -f "$global_config" ]]; then
		config_load_file_into_cache "$global_config" "_GLOBAL_CONFIG_CACHE"
		log_debug "Loaded global config: $global_config"
	fi

	local plugin_config="${PLUGIN_DIR:-}/config/local.conf"
	if [[ -f "$plugin_config" ]]; then
		config_load_file_into_cache "$plugin_config" "_PLUGIN_CONFIG_CACHE"
		log_debug "Loaded plugin config: $plugin_config"
	fi

	log_info "Configuration precedence chain initialized"
}

#===============================================================================
# FUNCTION: config_debug_sources
# PURPOSE: Print where each configuration variable came from
# Useful for debugging configuration issues
#===============================================================================
config_debug_sources() {
	log_info "Configuration Sources (for debugging):"
	local var source
	for var in "${!CONFIG_SOURCE_MAP[@]}"; do
		source="${CONFIG_SOURCE_MAP[$var]}"
		log_info "  $var -> $source"
	done | sort
}

# Export functions for use in other modules
export -f config_validate_prefix
export -f config_resolve
export -f config_get_or_die
export -f config_load_file_into_cache
export -f config_load_precedence_chain
export -f config_debug_sources
