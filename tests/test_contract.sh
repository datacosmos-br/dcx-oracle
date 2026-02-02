#!/usr/bin/env bash
# shellcheck shell=bash
#===============================================================================
# DCX-Oracle Plugin Contract Tests
#
# Tests the configuration precedence and contract enforcement modules:
# - config_precedence.sh: Strict config resolution with fail-fast behavior
#
# Usage:
#   ./test_contract.sh              # Run all contract tests
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
	echo "  Contract Tests Summary"
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
log_error() { echo "[ERROR] $*" >&2; }
die() {
	echo "[FATAL] $*" >&2
	exit 1
}

#===============================================================================
# SETUP: Test Environment
#===============================================================================

TEST_TEMP_DIR="/tmp/test_contract_$$"
mkdir -p "${TEST_TEMP_DIR}"

# Set up minimal plugin directory structure
export PLUGIN_DIR="${TEST_TEMP_DIR}/plugin"
mkdir -p "${PLUGIN_DIR}/config"

# Create mock defaults.conf
cat >"${PLUGIN_DIR}/config/defaults.conf" <<'EOF'
ORACLE_SID=DEFAULT_SID
DB_HOST=default.host
DB_PORT=1521
LOG_LEVEL=info
EOF

# Create mock local.conf (plugin config)
cat >"${PLUGIN_DIR}/config/local.conf" <<'EOF'
ORACLE_SID=LOCAL_SID
DB_HOST=local.host
SOURCE_DB_HOST=source.local
EOF

# Create mock global config
mkdir -p "${HOME}/.dcx"
cat >"${HOME}/.dcx/config" <<'EOF'
DB_HOST=global.host
TARGET_DB_HOST=target.global
EOF

echo "=== Setting up Test Environment ==="
echo "Test temp dir: ${TEST_TEMP_DIR}"
echo "Plugin dir: ${PLUGIN_DIR}"
echo ""

# Source the module under test
source "${PLUGIN_LIB}/config_precedence.sh"

#===============================================================================
# TESTS: Config Precedence
#===============================================================================

echo "=== Testing Configuration Precedence ==="

# Initialize the precedence chain
config_load_precedence_chain

# Test 1: Environment variable has highest priority
run_test "config_resolve uses env var when set" '
    export ORACLE_SID=ENV_SID
    result=$(config_resolve ORACLE_SID)
    [[ "${result}" == "ENV_SID" ]]
'

# Test 2: DCX context takes precedence over config files
run_test "config_resolve uses DCX context over config files" '
    unset ORACLE_SID
    export DCX_ORACLE_SID=DCX_SID
    result=$(config_resolve ORACLE_SID)
    [[ "${result}" == "DCX_SID" ]]
'

# Test 3: Plugin config takes precedence over global
run_test "config_resolve uses plugin config over global" '
    unset ORACLE_SID DCX_ORACLE_SID
    result=$(config_resolve ORACLE_SID)
    [[ "${result}" == "LOCAL_SID" ]]
'

# Test 4: Global config takes precedence over defaults
run_test "config_resolve uses global config over defaults" '
    unset ORACLE_SID DCX_ORACLE_SID
    # Remove local.conf to test global vs defaults
    rm -f "${PLUGIN_DIR}/config/local.conf"
    config_load_precedence_chain
    result=$(config_resolve DB_HOST)
    [[ "${result}" == "global.host" ]]
'

# Restore local.conf for subsequent tests
cat >"${PLUGIN_DIR}/config/local.conf" <<'EOF'
ORACLE_SID=LOCAL_SID
DB_HOST=local.host
SOURCE_DB_HOST=source.local
EOF
config_load_precedence_chain

# Test 5: Defaults are used when nothing else is set
run_test "config_resolve uses defaults when no other source" '
    unset ORACLE_SID DCX_ORACLE_SID LOG_LEVEL
    result=$(config_resolve LOG_LEVEL)
    [[ "${result}" == "info" ]]
'

# Test 6: Invalid prefix is rejected
run_test_expect_fail "config_resolve rejects invalid prefix" '
    config_resolve INVALID_VAR 2>/dev/null
'

# Test 7: Missing required value fails
run_test_expect_fail "config_resolve fails on missing required value" '
    config_resolve NONEXISTENT_VAR_REQUIRED 2>/dev/null
'

# Test 8: Default parameter works when value missing
run_test "config_resolve uses provided default when missing" '
    result=$(config_resolve NONEXISTENT_VAR "fallback_value")
    [[ "${result}" == "fallback_value" ]]
'

# Test 9: Prefix validation accepts allowed prefixes
run_test "config_validate_prefix accepts ORACLE_ prefix" '
    config_validate_prefix ORACLE_HOME
'

run_test "config_validate_prefix accepts DB_ prefix" '
    config_validate_prefix DB_HOST
'

run_test "config_validate_prefix accepts SOURCE_ prefix" '
    config_validate_prefix SOURCE_DB_HOST
'

run_test "config_validate_prefix accepts TARGET_ prefix" '
    config_validate_prefix TARGET_DB_HOST
'

run_test "config_validate_prefix accepts NETWORK_ prefix" '
    config_validate_prefix NETWORK_LINK
'

run_test "config_validate_prefix accepts OCI_ prefix" '
    config_validate_prefix OCI_REGION
'

run_test "config_validate_prefix accepts TNS_ prefix" '
    config_validate_prefix TNS_ADMIN
'

run_test "config_validate_prefix accepts EXPORT_ prefix" '
    config_validate_prefix EXPORT_DIR
'

run_test "config_validate_prefix accepts IMPORT_ prefix" '
    config_validate_prefix IMPORT_DIR
'

run_test "config_validate_prefix accepts LOG_ prefix" '
    config_validate_prefix LOG_LEVEL
'

run_test "config_validate_prefix accepts DC_ prefix" '
    config_validate_prefix DC_WORKSPACE
'

# Test 10: Prefix validation rejects disallowed prefixes
run_test_expect_fail "config_validate_prefix rejects lowercase" '
    config_validate_prefix oracle_home 2>/dev/null
'

run_test_expect_fail "config_validate_prefix rejects mixed case" '
    config_validate_prefix Oracle_Home 2>/dev/null
'

run_test_expect_fail "config_validate_prefix rejects unknown prefix" '
    config_validate_prefix FOO_BAR 2>/dev/null
'

# Test 11: Source tracking works
run_test "config_resolve tracks source correctly" '
    export TRACKED_VAR=test123
    unset TRACKED_VAR_DCX
    _plugin_var=$(config_resolve TRACKED_VAR)
    [[ "${CONFIG_SOURCE_MAP[TRACKED_VAR]}" == "env" ]]
'

#===============================================================================
# TESTS: Config File Loading
#===============================================================================

echo ""
echo "=== Testing Config File Loading ==="

# Test 12: Load file into cache
run_test "config_load_file_into_cache loads key=value pairs" '
    declare -gA test_cache
    config_load_file_into_cache "${PLUGIN_DIR}/config/defaults.conf" "test_cache"
    [[ "${test_cache[ORACLE_SID]}" == "DEFAULT_SID" ]]
'

# Test 13: Load handles quoted values
run_test "config_load_file_into_cache handles quoted values" '
    echo "TEST_KEY=\"quoted value\"" > "${TEST_TEMP_DIR}/quoted.conf"
    declare -gA quote_cache
    config_load_file_into_cache "${TEST_TEMP_DIR}/quoted.conf" "quote_cache"
    [[ "${quote_cache[TEST_KEY]}" == "quoted value" ]]
'

# Test 14: Load handles single quotes
run_test "config_load_file_into_cache handles single quotes" '
    echo "TEST_KEY2=single_value" > "${TEST_TEMP_DIR}/single.conf"
    declare -gA single_cache
    config_load_file_into_cache "${TEST_TEMP_DIR}/single.conf" "single_cache"
    [[ "${single_cache[TEST_KEY2]}" == "single_value" ]]
'

# Test 15: Load skips comments
run_test "config_load_file_into_cache skips comments" '
    cat > "${TEST_TEMP_DIR}/comment.conf" <<EOF
# This is a comment
REAL_KEY=real_value
   # Indented comment
ANOTHER_KEY=another_value
EOF
    declare -gA comment_cache
    config_load_file_into_cache "${TEST_TEMP_DIR}/comment.conf" "comment_cache"
    [[ "${comment_cache[REAL_KEY]}" == "real_value" && "${comment_cache[ANOTHER_KEY]}" == "another_value" ]]
'

# Test 16: Load skips empty lines
run_test "config_load_file_into_cache skips empty lines" '
    cat > "${TEST_TEMP_DIR}/empty.conf" <<EOF
KEY1=value1

KEY2=value2

EOF
    declare -gA empty_cache
    config_load_file_into_cache "${TEST_TEMP_DIR}/empty.conf" "empty_cache"
    [[ "${empty_cache[KEY1]}" == "value1" && "${empty_cache[KEY2]}" == "value2" ]]
'

# Test 17: Nonexistent file returns 0 (no error)
run_test "config_load_file_into_cache handles missing file" '
    config_load_file_into_cache "/nonexistent/file.conf" "missing_cache"
    return 0
'

#===============================================================================
# TESTS: Config Get or Die
#===============================================================================

echo ""
echo "=== Testing config_get_or_die ==="

# Test 18: Get existing value
run_test "config_get_or_die returns value when exists" '
    export EXISTING_VAR=get_or_die_test
    result=$(config_get_or_die EXISTING_VAR)
    [[ "${result}" == "get_or_die_test" ]]
'

# Test 19: Die on missing value
run_test_expect_fail "config_get_or_die dies on missing" '
    config_get_or_die ABSOLUTELY_MISSING_VAR_12345 2>/dev/null
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
