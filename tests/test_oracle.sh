#!/usr/bin/env bash
# shellcheck shell=bash
#===============================================================================
# DCX Oracle Plugin - Oracle Module Tests
#
# Validates oracle.sh functions using mocked Oracle environment.
# Does NOT require actual Oracle installation for most tests.
#
# Usage:
#   ./test_oracle.sh              # Run with mock environment
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

#===============================================================================
# SETUP: Mock Oracle Environment
#===============================================================================

echo "=== Setting up Mock Oracle Environment ==="

MOCK_ORACLE_HOME="/tmp/mock_oracle_$$"
mkdir -p "${MOCK_ORACLE_HOME}/bin"

# Create mock sqlplus
cat > "${MOCK_ORACLE_HOME}/bin/sqlplus" <<'MOCK'
#!/bin/bash
echo "SQL*Plus: Release 19.0.0.0.0 - Mock"
echo "Connected to:"
echo "Oracle Database 19c - Mock"
MOCK
chmod +x "${MOCK_ORACLE_HOME}/bin/sqlplus"

# Create mock rman
cat > "${MOCK_ORACLE_HOME}/bin/rman" <<'MOCK'
#!/bin/bash
echo "Recovery Manager: Release 19.0.0.0.0 - Mock"
echo "RMAN> "
MOCK
chmod +x "${MOCK_ORACLE_HOME}/bin/rman"

export ORACLE_HOME="${MOCK_ORACLE_HOME}"
export ORACLE_SID="MOCKDB"

# Now source oracle.sh
source "${PLUGIN_LIB}/oracle.sh"

echo "Mock ORACLE_HOME: ${ORACLE_HOME}"
echo "Mock ORACLE_SID: ${ORACLE_SID}"
echo

#===============================================================================
# TEST: Environment Validation
#===============================================================================

echo "=== Testing Environment Validation ==="

run_test "oracle_core_validate_home passes" oracle_core_validate_home

#===============================================================================
# TEST: Memory Validation
#===============================================================================

echo
echo "=== Testing Memory Validation ==="

run_test "oracle_config_validate_mem_value 4G" oracle_config_validate_mem_value "4G"
run_test "oracle_config_validate_mem_value 512M" oracle_config_validate_mem_value "512M"
run_test "oracle_config_validate_mem_value 1024K" oracle_config_validate_mem_value "1024K"
run_test "oracle_config_validate_mem_value lowercase 8g" oracle_config_validate_mem_value "8g"
run_test "oracle_config_validate_mem_value lowercase 256m" oracle_config_validate_mem_value "256m"

run_test_expect_fail "oracle_config_validate_mem_value rejects 4GB" oracle_config_validate_mem_value "4GB"
run_test "oracle_config_validate_mem_value accepts bytes as plain number" oracle_config_validate_mem_value "1024"
run_test_expect_fail "oracle_config_validate_mem_value rejects empty" oracle_config_validate_mem_value ""
run_test_expect_fail "oracle_config_validate_mem_value rejects text" oracle_config_validate_mem_value "large"

#===============================================================================
# TEST: PFILE Parsing
#===============================================================================

echo
echo "=== Testing PFILE Parsing ==="

MOCK_PFILE="/tmp/mock_pfile_$$.ora"

cat > "${MOCK_PFILE}" <<'EOF'
*.db_name='TESTDB'
*.db_unique_name='TESTDB_UNIQUE'
*.sga_target=8G
*.pga_aggregate_target=2G
*.processes=1500
*.control_files='/u01/oradata/TESTDB/control01.ctl','/u01/oradata/TESTDB/control02.ctl'
EOF

run_test "parse_db_name extracts TESTDB" bash -c '
    source "'"${PLUGIN_LIB}"'/oracle.sh"
    result=$(oracle_config_pfile_parse_db_name "'"${MOCK_PFILE}"'")
    [[ "${result}" == "TESTDB" ]]
'

run_test "parse_param extracts db_unique_name" bash -c '
    source "'"${PLUGIN_LIB}"'/oracle.sh"
    result=$(oracle_config_pfile_parse_param "'"${MOCK_PFILE}"'" "db_unique_name")
    [[ "${result}" == "TESTDB_UNIQUE" ]]
'

run_test "parse_param extracts sga_target" bash -c '
    source "'"${PLUGIN_LIB}"'/oracle.sh"
    result=$(oracle_config_pfile_parse_param "'"${MOCK_PFILE}"'" "sga_target")
    [[ "${result}" == "8G" ]]
'

rm -f "${MOCK_PFILE}"

#===============================================================================
# TEST: DBID Detection
#===============================================================================

echo
echo "=== Testing DBID Detection ==="

MOCK_AUTOBACKUP="/tmp/mock_autobackup_$$"
mkdir -p "${MOCK_AUTOBACKUP}"

# Create fake autobackup files
touch "${MOCK_AUTOBACKUP}/c-1234567890-20260113-00"
touch "${MOCK_AUTOBACKUP}/c-1234567890-20260113-01"

run_test "detect_dbid finds unique DBID" bash -c '
    source "'"${PLUGIN_LIB}"'/oracle.sh"
    result=$(oracle_rman_detect_dbid "'"${MOCK_AUTOBACKUP}"'")
    [[ "${result}" == "1234567890" ]]
'

# Add another DBID to create ambiguity
touch "${MOCK_AUTOBACKUP}/c-9876543210-20260113-00"

run_test "detect_dbid returns rc=2 for multiple DBIDs" bash -c '
    source "'"${PLUGIN_LIB}"'/oracle.sh"
    oracle_rman_detect_dbid "'"${MOCK_AUTOBACKUP}"'"
    [[ $? -eq 2 ]]
'

rm -rf "${MOCK_AUTOBACKUP}"

#===============================================================================
# TEST: Backup Discovery
#===============================================================================

echo
echo "=== Testing Backup Discovery ==="

MOCK_BACKUP_ROOT="/tmp/mock_backup_$$"
mkdir -p "${MOCK_BACKUP_ROOT}/autobackup"
touch "${MOCK_BACKUP_ROOT}/autobackup/c-1111111111-20260113-00"

run_test "backup_discover finds direct autobackup" bash -c '
    source "'"${PLUGIN_LIB}"'/oracle.sh"
    AUTO=""
    oracle_rman_backup_discover "'"${MOCK_BACKUP_ROOT}"'"
    [[ -n "${AUTO}" ]]
'

rm -rf "${MOCK_BACKUP_ROOT}"

# Test RMAN_LOCAL_FULL structure
MOCK_BACKUP_ROOT2="/tmp/mock_backup2_$$"
mkdir -p "${MOCK_BACKUP_ROOT2}/RMAN_LOCAL_FULL/PRODDB/autobackup"
touch "${MOCK_BACKUP_ROOT2}/RMAN_LOCAL_FULL/PRODDB/autobackup/c-2222222222-20260113-00"

run_test "backup_discover finds RMAN_LOCAL_FULL structure" bash -c '
    source "'"${PLUGIN_LIB}"'/oracle.sh"
    AUTO=""
    DBID=""
    oracle_rman_backup_discover "'"${MOCK_BACKUP_ROOT2}"'"
    [[ -n "${AUTO}" && "${DBID}" == "2222222222" ]]
'

rm -rf "${MOCK_BACKUP_ROOT2}"

#===============================================================================
# TEST: RMAN Channel Functions
#===============================================================================

echo
echo "=== Testing RMAN Channel Functions ==="

run_test "oracle_rman_auto_channels sets variable" bash -c '
    source "'"${PLUGIN_LIB}"'/oracle.sh"
    unset RMAN_CHANNELS
    oracle_rman_auto_channels
    [[ -n "${RMAN_CHANNELS}" && "${RMAN_CHANNELS}" =~ ^[0-9]+$ ]]
'

run_test "rman_channels_alloc generates commands" bash -c '
    source "'"${PLUGIN_LIB}"'/oracle.sh"
    RMAN_CHANNELS=2
    result=$(oracle_rman_channels_alloc)
    echo "${result}" | grep -q "allocate channel c1"
    echo "${result}" | grep -q "allocate channel c2"
'

run_test "rman_channels_release generates commands" bash -c '
    source "'"${PLUGIN_LIB}"'/oracle.sh"
    RMAN_CHANNELS=2
    result=$(oracle_rman_channels_release)
    echo "${result}" | grep -q "release channel c1"
    echo "${result}" | grep -q "release channel c2"
'

#===============================================================================
# TEST: Memory Calculation
#===============================================================================

echo
echo "=== Testing Memory Calculation ==="

run_test "oracle_config_calc_memory returns two values" bash -c '
    source "'"${PLUGIN_LIB}"'/oracle.sh"
    unset SGA_TARGET PGA_TARGET
    read -r sga pga < <(oracle_config_calc_memory)
    [[ -n "${sga}" && -n "${pga}" ]]
'

run_test "oracle_config_calc_memory uses overrides" bash -c '
    source "'"${PLUGIN_LIB}"'/oracle.sh"
    export SGA_TARGET="16G"
    export PGA_TARGET="8G"
    read -r sga pga < <(oracle_config_calc_memory)
    [[ "${sga}" == "16G" && "${pga}" == "8G" ]]
'

#===============================================================================
# CLEANUP
#===============================================================================

echo
echo "=== Cleaning up Mock Environment ==="
rm -rf "${MOCK_ORACLE_HOME}"
echo "Cleanup complete."

#===============================================================================
# SUMMARY
#===============================================================================

echo
echo "========================================"
echo "Test Summary: ${PASS_COUNT}/${TEST_COUNT} passed"
if [[ "${FAIL_COUNT}" -gt 0 ]]; then
    echo "FAILURES: ${FAIL_COUNT}"
    exit 1
else
    echo "All tests passed!"
    exit 0
fi
