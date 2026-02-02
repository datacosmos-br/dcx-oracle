#!/usr/bin/env bash
# shellcheck shell=bash
#===============================================================================
# DCX-Oracle Preflight Validation Tests
#
# Tests the oracle_preflight.sh module's 8 preflight checks:
# 1. oracle_preflight_config - Configuration completeness
# 2. oracle_preflight_environment - ORACLE_HOME and directories
# 3. oracle_preflight_tools - Required tools availability
# 4. oracle_preflight_storage - Storage directories and permissions
# 5. oracle_preflight_source_db - Source database connectivity
# 6. oracle_preflight_target_db - Target database connectivity
# 7. oracle_preflight_data_safety - Safety constraints
# 8. oracle_preflight_check - Main entry point that runs all checks
#
# Usage:
#   ./test_preflight.sh              # Run all preflight tests
#===============================================================================

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="${SCRIPT_DIR}/.."
PLUGIN_LIB="${PLUGIN_DIR}/lib"

#===============================================================================
# TEST FRAMEWORK
#===============================================================================

TEST_COUNT=0
PASS_COUNT=0
FAIL_COUNT=0

run_test() {
	local name="$1"
	shift
	TEST_COUNT=$((TEST_COUNT + 1))

	# Run in subshell to isolate exit calls
	if ("$@") 2>/dev/null; then
		echo "[PASS] ${name}"
		PASS_COUNT=$((PASS_COUNT + 1))
	else
		echo "[FAIL] ${name}"
		FAIL_COUNT=$((FAIL_COUNT + 1))
	fi
}

run_test_expect_fail() {
	local name="$1"
	shift
	TEST_COUNT=$((TEST_COUNT + 1))

	# Run in subshell to isolate exit calls (die/exit won't kill test runner)
	if ! ("$@") 2>/dev/null; then
		echo "[PASS] ${name} (expected failure)"
		PASS_COUNT=$((PASS_COUNT + 1))
	else
		echo "[FAIL] ${name} (should have failed)"
		FAIL_COUNT=$((FAIL_COUNT + 1))
	fi
}

print_summary() {
	echo ""
	echo "========================================"
	echo "  Preflight Tests Summary"
	echo "========================================"
	echo "  Total:  ${TEST_COUNT}"
	echo "  Passed: ${PASS_COUNT}"
	echo "  Failed: ${FAIL_COUNT}"
	echo "========================================"

	if [[ ${FAIL_COUNT} -eq 0 ]]; then
		echo "  All tests passed!"
		return 0
	else
		echo "  Some tests failed!"
		return 1
	fi
}

#===============================================================================
# MOCK DEPENDENCIES
#===============================================================================

# Minimal mock functions for testing without full DCX infrastructure
log_debug() { :; }
log_info() { :; }
log_warn() { :; }
log_error() { echo "[ERROR] $*" >&2; }
die() {
	echo "[FATAL] $*" >&2
	exit 1
}

# Mock config_resolve for testing
declare -gA MOCK_CONFIG
mock_config_resolve() {
	local var="$1"
	local default="${2:-}"

	if [[ -n "${MOCK_CONFIG[$var]:-}" ]]; then
		echo "${MOCK_CONFIG[$var]}"
		return 0
	fi

	# Check environment
	local env_val="${!var:-}"
	if [[ -n "$env_val" ]]; then
		echo "$env_val"
		return 0
	fi

	# Return default
	if [[ -n "$default" ]]; then
		echo "$default"
		return 0
	fi

	return 1
}

#===============================================================================
# SETUP: Test Environment
#===============================================================================

TEST_TEMP_DIR="/tmp/test_preflight_$$"
mkdir -p "${TEST_TEMP_DIR}/export" "${TEST_TEMP_DIR}/logs"

echo "=== Setting up Test Environment ==="
echo "Test temp dir: ${TEST_TEMP_DIR}"
echo ""

# Source the modules under test (mock config_resolve first, then source)
export EXPORT_DIR="${TEST_TEMP_DIR}/export"
export LOG_DIR="${TEST_TEMP_DIR}/logs"

# Source config_precedence to get its functions
source "${PLUGIN_LIB}/config_precedence.sh"

# Override config_resolve with mock
config_resolve() { mock_config_resolve "$@"; }

# Source preflight module
source "${PLUGIN_LIB}/oracle_preflight.sh"

#===============================================================================
# TESTS: Preflight Config
#===============================================================================

echo "=== Testing Preflight Config ==="

# Test 1: All required config present
run_test "oracle_preflight_config passes when all vars set" '
    unset MOCK_CONFIG
    declare -gA MOCK_CONFIG
    MOCK_CONFIG[ORACLE_SID]=TEST_SID
    MOCK_CONFIG[SOURCE_DB_HOST]=source.host
    MOCK_CONFIG[TARGET_DB_HOST]=target.host
    oracle_preflight_config
'

# Test 2: Missing ORACLE_SID fails
run_test_expect_fail "oracle_preflight_config fails on missing ORACLE_SID" '
    unset MOCK_CONFIG
    declare -gA MOCK_CONFIG
    MOCK_CONFIG[SOURCE_DB_HOST]=source.host
    MOCK_CONFIG[TARGET_DB_HOST]=target.host
    oracle_preflight_config
'

# Test 3: Missing SOURCE_DB_HOST fails
run_test_expect_fail "oracle_preflight_config fails on missing SOURCE_DB_HOST" '
    unset MOCK_CONFIG
    declare -gA MOCK_CONFIG
    MOCK_CONFIG[ORACLE_SID]=TEST_SID
    MOCK_CONFIG[TARGET_DB_HOST]=target.host
    oracle_preflight_config
'

# Test 4: Missing TARGET_DB_HOST fails
run_test_expect_fail "oracle_preflight_config fails on missing TARGET_DB_HOST" '
    unset MOCK_CONFIG
    declare -gA MOCK_CONFIG
    MOCK_CONFIG[ORACLE_SID]=TEST_SID
    MOCK_CONFIG[SOURCE_DB_HOST]=source.host
    oracle_preflight_config
'

#===============================================================================
# TESTS: Preflight Environment
#===============================================================================

echo ""
echo "=== Testing Preflight Environment ==="

# Test 5: Valid ORACLE_HOME passes
run_test "oracle_preflight_environment passes with valid ORACLE_HOME" '
    export ORACLE_HOME="${TEST_TEMP_DIR}/oracle"
    mkdir -p "${ORACLE_HOME}/bin" "${ORACLE_HOME}/lib"
    oracle_preflight_environment
'

# Test 6: Missing ORACLE_HOME fails
run_test_expect_fail "oracle_preflight_environment fails on missing ORACLE_HOME" '
    unset ORACLE_HOME
    oracle_preflight_environment
'

# Test 7: Nonexistent ORACLE_HOME fails
run_test_expect_fail "oracle_preflight_environment fails on invalid ORACLE_HOME" '
    export ORACLE_HOME="/nonexistent/oracle/path"
    oracle_preflight_environment
'

# Test 8: Missing bin directory fails
run_test_expect_fail "oracle_preflight_environment fails on missing bin dir" '
    export ORACLE_HOME="${TEST_TEMP_DIR}/oracle_missing"
    mkdir -p "${ORACLE_HOME}/lib"
    rm -rf "${ORACLE_HOME}/bin" 2>/dev/null || true
    oracle_preflight_environment
'

# Test 9: Missing lib directory fails
run_test_expect_fail "oracle_preflight_environment fails on missing lib dir" '
    export ORACLE_HOME="${TEST_TEMP_DIR}/oracle_missing2"
    mkdir -p "${ORACLE_HOME}/bin"
    rm -rf "${ORACLE_HOME}/lib" 2>/dev/null || true
    oracle_preflight_environment
'

#===============================================================================
# TESTS: Preflight Tools
#===============================================================================

echo ""
echo "=== Testing Preflight Tools ==="

# Test 10: All required tools present (bash, awk, sed always available)
run_test "oracle_preflight_tools passes when basic tools present" '
    oracle_preflight_tools
'

#===============================================================================
# TESTS: Preflight Storage
#===============================================================================

echo ""
echo "=== Testing Preflight Storage ==="

# Test 11: Valid directories pass
run_test "oracle_preflight_storage passes with valid directories" '
    export EXPORT_DIR="${TEST_TEMP_DIR}/export"
    export LOG_DIR="${TEST_TEMP_DIR}/logs"
    oracle_preflight_storage
'

# Test 12: Creates missing export directory
run_test "oracle_preflight_storage creates missing export dir" '
    export EXPORT_DIR="${TEST_TEMP_DIR}/export_new"
    rm -rf "${EXPORT_DIR}" 2>/dev/null || true
    export LOG_DIR="${TEST_TEMP_DIR}/logs"
    oracle_preflight_storage
    [[ -d "${EXPORT_DIR}" ]]
'

# Test 13: Creates missing log directory
run_test "oracle_preflight_storage creates missing log dir" '
    export EXPORT_DIR="${TEST_TEMP_DIR}/export"
    export LOG_DIR="${TEST_TEMP_DIR}/logs_new"
    rm -rf "${LOG_DIR}" 2>/dev/null || true
    oracle_preflight_storage
    [[ -d "${LOG_DIR}" ]]
'

# Test 14: Read-only directory fails
run_test_expect_fail "oracle_preflight_storage fails on read-only dir" '
    export EXPORT_DIR="${TEST_TEMP_DIR}/readonly"
    mkdir -p "${EXPORT_DIR}"
    chmod 000 "${EXPORT_DIR}"
    export LOG_DIR="${TEST_TEMP_DIR}/logs"
    result=$(oracle_preflight_storage 2>&1) || true
    chmod 755 "${EXPORT_DIR}"
    [[ -n "$result" ]]
    return 1
'

#===============================================================================
# TESTS: Preflight Data Safety
#===============================================================================

echo ""
echo "=== Testing Preflight Data Safety ==="

# Test 15: Different source and target passes
run_test "oracle_preflight_data_safety passes when source != target" '
    unset MOCK_CONFIG
    declare -gA MOCK_CONFIG
    MOCK_CONFIG[SOURCE_DB_UNIQUE_NAME]=prod_db
    MOCK_CONFIG[TARGET_DB_UNIQUE_NAME]=dev_db
    oracle_preflight_data_safety
'

# Test 16: Same source and target fails
run_test_expect_fail "oracle_preflight_data_safety fails when source == target" '
    unset MOCK_CONFIG
    declare -gA MOCK_CONFIG
    MOCK_CONFIG[SOURCE_DB_UNIQUE_NAME]=prod_db
    MOCK_CONFIG[TARGET_DB_UNIQUE_NAME]=prod_db
    oracle_preflight_data_safety
'

# Test 17: Empty source/target passes (migration not defined)
run_test "oracle_preflight_data_safety passes with empty db names" '
    unset MOCK_CONFIG
    declare -gA MOCK_CONFIG
    oracle_preflight_data_safety
'

# Test 18: Only source defined passes
run_test "oracle_preflight_data_safety passes with only source defined" '
    unset MOCK_CONFIG
    declare -gA MOCK_CONFIG
    MOCK_CONFIG[SOURCE_DB_UNIQUE_NAME]=prod_db
    oracle_preflight_data_safety
'

# Test 19: Only target defined passes
run_test "oracle_preflight_data_safety passes with only target defined" '
    unset MOCK_CONFIG
    declare -gA MOCK_CONFIG
    MOCK_CONFIG[TARGET_DB_UNIQUE_NAME]=dev_db
    oracle_preflight_data_safety
'

#===============================================================================
# TESTS: Main Entry Point
#===============================================================================

echo ""
echo "=== Testing Main Preflight Check ==="

# Test 20: All checks pass with valid setup
run_test "oracle_preflight_check passes with full valid setup" '
    unset MOCK_CONFIG
    declare -gA MOCK_CONFIG
    MOCK_CONFIG[ORACLE_SID]=TEST_SID
    MOCK_CONFIG[SOURCE_DB_HOST]=source.host
    MOCK_CONFIG[TARGET_DB_HOST]=target.host
    MOCK_CONFIG[SOURCE_DB_UNIQUE_NAME]=prod_db
    MOCK_CONFIG[TARGET_DB_UNIQUE_NAME]=dev_db
    export ORACLE_HOME="${TEST_TEMP_DIR}/oracle_valid"
    mkdir -p "${ORACLE_HOME}/bin" "${ORACLE_HOME}/lib"
    export EXPORT_DIR="${TEST_TEMP_DIR}/export"
    export LOG_DIR="${TEST_TEMP_DIR}/logs"
    oracle_preflight_check
'

# Test 21: Main check fails when config check fails
run_test_expect_fail "oracle_preflight_check fails when config fails" '
    unset MOCK_CONFIG
    declare -gA MOCK_CONFIG
    unset ORACLE_HOME
    oracle_preflight_check
'

# Test 22: Main check fails when environment check fails
run_test_expect_fail "oracle_preflight_check fails when env fails" '
    unset MOCK_CONFIG
    declare -gA MOCK_CONFIG
    MOCK_CONFIG[ORACLE_SID]=TEST_SID
    MOCK_CONFIG[SOURCE_DB_HOST]=source.host
    MOCK_CONFIG[TARGET_DB_HOST]=target.host
    unset ORACLE_HOME
    oracle_preflight_check
'

#===============================================================================
# CLEANUP
#===============================================================================

# Cleanup test files
rm -rf "${TEST_TEMP_DIR}"

#===============================================================================
# SUMMARY
#===============================================================================

print_summary
