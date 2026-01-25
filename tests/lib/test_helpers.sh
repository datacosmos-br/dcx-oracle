#!/usr/bin/env bash
# shellcheck shell=bash
#===============================================================================
# DCX Oracle Plugin - Test Helpers & Utilities
#
# Provides reusable test framework functions for creating realistic mocks,
# assertions, error injection, and test fixtures.
#
# Usage:
#   source "$(dirname "$0")/lib/test_helpers.sh"
#   run_test "test name" 'test code'
#   run_test_expect_error "test name" "expected error" 'test code'
#===============================================================================

set -Eeuo pipefail

# Test state tracking
TESTS_PASSED=0
TESTS_FAILED=0
FAILED_TEST_NAMES=()
TEST_TEMP_DIR=""

# Plugin paths
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN_DIR="${TEST_DIR}/.."
PLUGIN_LIB="${PLUGIN_DIR}/lib"

#===============================================================================
# SECTION 1: Test Execution Helpers
#===============================================================================

# Run a test expecting success
run_test() {
    local test_name="$1"
    local test_code="$2"

    if (eval "$test_code") 2>/dev/null; then
        echo "[PASS] $test_name"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        echo "[FAIL] $test_name"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        FAILED_TEST_NAMES+=("$test_name")
        return 1
    fi
}

# Run a test expecting failure with error message validation
run_test_expect_error() {
    local test_name="$1"
    local expected_msg="$2"
    local test_code="$3"

    local error_output
    error_output=$(eval "$test_code" 2>&1 || true)

    if [[ "$error_output" =~ $expected_msg ]]; then
        echo "[PASS] $test_name (correctly failed)"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        echo "[FAIL] $test_name (expected error with '$expected_msg', got: $error_output)"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        FAILED_TEST_NAMES+=("$test_name")
        return 1
    fi
}

# Print test summary
print_test_summary() {
    echo ""
    echo "========================================"
    echo "  TEST SUMMARY"
    echo "========================================"
    echo "Passed: $TESTS_PASSED"
    echo "Failed: $TESTS_FAILED"
    echo ""

    if [[ $TESTS_FAILED -gt 0 ]]; then
        echo "Failed tests:"
        for name in "${FAILED_TEST_NAMES[@]}"; do
            echo "  - $name"
        done
        return 1
    else
        echo "STATUS: ALL TESTS PASSED"
        return 0
    fi
}

#===============================================================================
# SECTION 2: Mock Setup & Teardown
#===============================================================================

# Setup temporary test environment
setup_test_env() {
    TEST_TEMP_DIR=$(mktemp -d)
    export TEST_TEMP_DIR

    # Create mock directories
    mkdir -p "$TEST_TEMP_DIR"/{mocks,logs,queue,fixtures}

    # Add mocks to PATH
    export PATH="$TEST_TEMP_DIR/mocks:$PATH"
}

# Cleanup temporary test environment
cleanup_test_env() {
    if [[ -n "${TEST_TEMP_DIR:-}" ]] && [[ -d "$TEST_TEMP_DIR" ]]; then
        rm -rf "$TEST_TEMP_DIR"
    fi
}

# Trap cleanup on exit
trap cleanup_test_env EXIT

#===============================================================================
# SECTION 3: Oracle Environment Mocking
#===============================================================================

# Setup mock Oracle environment
setup_mock_oracle_env() {
    local oracle_home="$TEST_TEMP_DIR/oracle_home"

    mkdir -p "$oracle_home"/bin

    # Create fake sqlplus
    cat > "$oracle_home/bin/sqlplus" << 'SQLPLUS_EOF'
#!/bin/bash
# Mock SQLPlus - returns canned responses based on arguments
case "$@" in
    *"select status from v$instance"*)
        echo "MOUNTED"
        ;;
    *"select current_scn"*)
        echo "12345678"
        ;;
    *)
        echo "SQL> "
        ;;
esac
exit 0
SQLPLUS_EOF
    chmod +x "$oracle_home/bin/sqlplus"

    # Create fake rman
    cat > "$oracle_home/bin/rman" << 'RMAN_EOF'
#!/bin/bash
# Mock RMAN - records command execution
echo "RMAN> "
while read -r line; do
    [[ -z "$line" ]] && continue
    echo "$line" >> /tmp/rman_commands.log
    echo "RMAN> "
done
exit 0
RMAN_EOF
    chmod +x "$oracle_home/bin/rman"

    # Create fake impdp/expdp
    cat > "$oracle_home/bin/impdp" << 'EOF'
#!/bin/bash
echo "Import: Release 19.0.0.0.0 - Mock"
exit 0
EOF
    chmod +x "$oracle_home/bin/impdp"

    cat > "$oracle_home/bin/expdp" << 'EOF'
#!/bin/bash
echo "Export: Release 19.0.0.0.0 - Mock"
exit 0
EOF
    chmod +x "$oracle_home/bin/expdp"

    export ORACLE_HOME="$oracle_home"
    export PATH="$oracle_home/bin:$PATH"
}

#===============================================================================
# SECTION 4: Mock Command Creation
#===============================================================================

# Create a mock command that returns specified output
mock_command() {
    local cmd_name="$1"
    local output="$2"
    local exit_code="${3:-0}"

    cat > "$TEST_TEMP_DIR/mocks/$cmd_name" << MOCK_EOF
#!/bin/bash
echo "$output"
exit $exit_code
MOCK_EOF
    chmod +x "$TEST_TEMP_DIR/mocks/$cmd_name"
}

# Create a mock command that fails with specific error
mock_command_fail() {
    local cmd_name="$1"
    local error_msg="$2"
    local exit_code="${3:-1}"

    cat > "$TEST_TEMP_DIR/mocks/$cmd_name" << MOCK_EOF
#!/bin/bash
echo "$error_msg" >&2
exit $exit_code
MOCK_EOF
    chmod +x "$TEST_TEMP_DIR/mocks/$cmd_name"
}

#===============================================================================
# SECTION 5: Test Data Generators
#===============================================================================

# Create a temporary test parfile
create_test_parfile() {
    local parfile_path="$TEST_TEMP_DIR/test.par"

    cat > "$parfile_path" << 'PARFILE_EOF'
-- Test Parfile
USERID=system/oracle@db
DIRECTORY=dpump_dir
DUMPFILE=test.dmp
LOGFILE=test.log
PARALLEL=4
TABLES=TEST_USER.TEST_TABLE
PARFILE_EOF

    echo "$parfile_path"
}

# Create temporary test configuration file
create_test_config() {
    local config_path="$TEST_TEMP_DIR/test.conf"

    cat > "$config_path" << 'CONFIG_EOF'
# Test Configuration
ORACLE_SID=test
ORACLE_HOME=/tmp/oracle_home
DB_USER=system
DB_PASS=oracle
PARALLEL_DEGREE=4
MAX_CONCURRENT_PROCESSES=2
CONFIG_EOF

    echo "$config_path"
}

#===============================================================================
# SECTION 6: Assertion Helpers
#===============================================================================

# Assert file exists
assert_file_exists() {
    local file="$1"
    [[ -f "$file" ]] || { echo "FAIL: File does not exist: $file"; return 1; }
}

# Assert file contains pattern
assert_file_contains() {
    local file="$1"
    local pattern="$2"
    grep -q "$pattern" "$file" || { echo "FAIL: Pattern not found in $file: $pattern"; return 1; }
}

# Assert directory exists
assert_dir_exists() {
    local dir="$1"
    [[ -d "$dir" ]] || { echo "FAIL: Directory does not exist: $dir"; return 1; }
}

# Assert variable equals value
assert_equals() {
    local var_name="$1"
    local expected="$2"
    local actual="$3"
    [[ "$actual" == "$expected" ]] || { echo "FAIL: $var_name: expected '$expected', got '$actual'"; return 1; }
}

# Assert variable matches pattern
assert_matches() {
    local var_name="$1"
    local pattern="$2"
    local actual="$3"
    [[ "$actual" =~ $pattern ]] || { echo "FAIL: $var_name: '$actual' does not match pattern '$pattern'"; return 1; }
}

#===============================================================================
# SECTION 7: Queue Testing Helpers
#===============================================================================

# Create queue for parallel job testing
setup_queue_env() {
    local queue_dir="$TEST_TEMP_DIR/queue"

    mkdir -p "$queue_dir"/{pending,running,completed,failed}

    export QUEUE_DIR="$queue_dir"
}

#===============================================================================
# SECTION 8: Initialization
#===============================================================================

# Initialize test environment on source
setup_test_env
