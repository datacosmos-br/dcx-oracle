#!/usr/bin/env bash
# shellcheck shell=bash
#===============================================================================
# Datacosmos - Oracle Wallet Module
#===============================================================================
# File    : oracle_wallet.sh
# Version : 1.0.0
# Date    : 2026-02-02
#===============================================================================
#
# DESCRIPTION:
#   Oracle Wallet management module. Provides functions to configure environment
#   for wallet-based authentication.
#   Note: Since 'mkstore' is not available in all environments, this module
#   focuses on CONSUMING existing wallets.
#
# DEPENDS ON:
#   - oracle_core.sh (logging)
#   - runtime.sh (assertions)
#
# PROVIDES:
#   - wallet_set_location(path)     - Set global wallet path
#   - wallet_check_valid(path)      - Check for cwallet.sso
#   - wallet_configure_env(path)    - Export TNS_ADMIN and WALLET_LOCATION
#
#===============================================================================

# Prevent double sourcing
[[ -n "${__ORACLE_WALLET_LOADED:-}" ]] && return 0
__ORACLE_WALLET_LOADED=1

# Resolve library directory
_ORACLE_WALLET_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load dependencies
[[ -z "${__ORACLE_CORE_LOADED:-}" ]] && source "${_ORACLE_WALLET_LIB_DIR}/oracle_core.sh"
[[ -z "${__RUNTIME_LOADED:-}" ]] && source "${_ORACLE_WALLET_LIB_DIR}/runtime.sh"

#===============================================================================
# SECTION 1: Wallet Configuration
#===============================================================================

# wallet_check_valid - Check if wallet directory contains auto-login wallet
# Usage: if wallet_check_valid "/path/to/wallet"; then ...
# Returns: 0 if valid (has cwallet.sso), 1 otherwise
wallet_check_valid() {
	local wallet_dir="$1"

	if [[ ! -d "${wallet_dir}" ]]; then
		log_debug "Wallet check failed: directory not found (${wallet_dir})"
		return 1
	fi

	if [[ ! -f "${wallet_dir}/cwallet.sso" ]]; then
		log_debug "Wallet check failed: cwallet.sso not found in ${wallet_dir}"
		return 1
	fi

	return 0
}

# wallet_configure_env - Configure environment variables for wallet usage
# Usage: wallet_configure_env "/path/to/wallet"
# Exports: TNS_ADMIN, ORACLE_WALLET_LOCATION, WALLET_LOCATION
wallet_configure_env() {
	local wallet_dir="$1"

	if ! wallet_check_valid "${wallet_dir}"; then
		log_error "Invalid wallet directory: ${wallet_dir}"
		return 1
	fi

	export ORACLE_WALLET_LOCATION="${wallet_dir}"
	export WALLET_LOCATION="${wallet_dir}"

	# Often TNS_ADMIN must point to the directory containing sqlnet.ora
	# which usually lives with the wallet
	export TNS_ADMIN="${wallet_dir}"

	log_debug "Configured Oracle Wallet environment: ${wallet_dir}"
	return 0
}

# wallet_set_location - Set global wallet location preference
# Usage: wallet_set_location "/path/to/wallet"
wallet_set_location() {
	local wallet_dir="$1"
	# Just a wrapper for now, might store in config later
	wallet_configure_env "${wallet_dir}"
}
