#!/usr/bin/env bash
#===============================================================================
# Test: Oracle Wallet Module
#===============================================================================

# Load test helpers
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../tests/test_helpers.sh"

# Mock dependencies
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/oracle_core.sh"
# Mock log functions
log_debug() { echo "[DEBUG] $*"; }
log_error() { echo "[ERROR] $*"; }

# Source module under test
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/oracle_wallet.sh"

describe "Oracle Wallet Management"

test_validation() {
	TEST_DIR=$(mktemp -d)

	# Test 1: Invalid dir
	run_test "fails on missing dir" "
        ! wallet_check_valid '${TEST_DIR}/missing'
    "

	# Test 2: Missing cwallet.sso
	mkdir -p "${TEST_DIR}/empty"
	run_test "fails on missing cwallet.sso" "
        ! wallet_check_valid '${TEST_DIR}/empty'
    "

	# Test 3: Valid wallet
	mkdir -p "${TEST_DIR}/valid"
	touch "${TEST_DIR}/valid/cwallet.sso"
	run_test "validates correct wallet" "
        wallet_check_valid '${TEST_DIR}/valid'
    "

	rm -rf "${TEST_DIR}"
}
run_test "validates wallet structure" test_validation

test_env_config() {
	TEST_DIR=$(mktemp -d)
	mkdir -p "${TEST_DIR}/valid"
	touch "${TEST_DIR}/valid/cwallet.sso"

	# Run config
	wallet_configure_env "${TEST_DIR}/valid"

	# Check exports
	assert_eq "${TEST_DIR}/valid" "${ORACLE_WALLET_LOCATION}" "Sets ORACLE_WALLET_LOCATION"
	assert_eq "${TEST_DIR}/valid" "${TNS_ADMIN}" "Sets TNS_ADMIN"

	rm -rf "${TEST_DIR}"
}
run_test "configures environment variables" test_env_config

test_summary
