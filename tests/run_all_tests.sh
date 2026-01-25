#!/usr/bin/env bash
# shellcheck shell=bash
#===============================================================================
# dcx Oracle Plugin - Master Test Runner
#
# Executes all test scripts and provides summary.
#
# Usage:
#   ./run_all_tests.sh           # Run all tests
#   ./run_all_tests.sh --quick   # Run only syntax validation
#===============================================================================

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="${SCRIPT_DIR}/.."

QUICK_MODE=0
[[ "${1:-}" == "--quick" ]] && QUICK_MODE=1

TOTAL_PASS=0
TOTAL_FAIL=0
FAILED_TESTS=()

echo "========================================"
echo "  dcx Oracle Plugin Test Suite"
echo "========================================"
echo
echo "Plugin Directory: ${PLUGIN_DIR}"
echo "Test Directory: ${SCRIPT_DIR}"
echo

#===============================================================================
# PHASE 1: Syntax Validation
#===============================================================================

echo "========================================"
echo "  Phase 1: Syntax Validation (bash -n)"
echo "========================================"
echo

syntax_ok=0
syntax_fail=0

# Test all library files
lib_files=(
    "lib/oracle_core.sh"
    "lib/oracle_env.sh"
    "lib/oracle_config.sh"
    "lib/oracle_cluster.sh"
    "lib/oracle_instance.sh"
    "lib/oracle.sh"
    "lib/oracle_sql.sh"
    "lib/oracle_datapump.sh"
    "lib/oracle_oci.sh"
    "lib/oracle_rman.sh"
    "lib/report.sh"
    "lib/session.sh"
    "lib/queue.sh"
    "lib/keyring.sh"
)

# Test command scripts
command_scripts=(
    "commands/restore.sh"
    "commands/migrate.sh"
    "commands/validate.sh"
    "commands/sql.sh"
    "commands/rman.sh"
    "commands/keyring.sh"
)

echo "Testing library files..."
for script in "${lib_files[@]}"; do
    if [[ -f "${PLUGIN_DIR}/${script}" ]]; then
        if bash -n "${PLUGIN_DIR}/${script}" 2>/dev/null; then
            echo "[PASS] Syntax OK: ${script}"
            syntax_ok=$((syntax_ok + 1))
        else
            echo "[FAIL] Syntax ERROR: ${script}"
            syntax_fail=$((syntax_fail + 1))
            FAILED_TESTS+=("Syntax: ${script}")
        fi
    else
        echo "[SKIP] Not found: ${script}"
    fi
done

echo
echo "Testing command scripts..."
for script in "${command_scripts[@]}"; do
    if [[ -f "${PLUGIN_DIR}/${script}" ]]; then
        if bash -n "${PLUGIN_DIR}/${script}" 2>/dev/null; then
            echo "[PASS] Syntax OK: ${script}"
            syntax_ok=$((syntax_ok + 1))
        else
            echo "[FAIL] Syntax ERROR: ${script}"
            syntax_fail=$((syntax_fail + 1))
            FAILED_TESTS+=("Syntax: ${script}")
        fi
    else
        echo "[SKIP] Not found: ${script}"
    fi
done

# Test plugin initialization
echo
echo "Testing plugin files..."
for script in "init.sh"; do
    if [[ -f "${PLUGIN_DIR}/${script}" ]]; then
        if bash -n "${PLUGIN_DIR}/${script}" 2>/dev/null; then
            echo "[PASS] Syntax OK: ${script}"
            syntax_ok=$((syntax_ok + 1))
        else
            echo "[FAIL] Syntax ERROR: ${script}"
            syntax_fail=$((syntax_fail + 1))
            FAILED_TESTS+=("Syntax: ${script}")
        fi
    else
        echo "[SKIP] Not found: ${script}"
    fi
done

echo
echo "Syntax validation: ${syntax_ok} passed, ${syntax_fail} failed"
TOTAL_PASS=$((TOTAL_PASS + syntax_ok))
TOTAL_FAIL=$((TOTAL_FAIL + syntax_fail))

#===============================================================================
# PHASE 2: Library Loading Test
#===============================================================================

echo
echo "========================================"
echo "  Phase 2: Library Loading Test"
echo "========================================"
echo

# Test oracle.sh loads correctly with mock environment
if bash -c '
    export ORACLE_HOME=/tmp/mock_oh_$$
    mkdir -p "$ORACLE_HOME/bin"
    touch "$ORACLE_HOME/bin/sqlplus" "$ORACLE_HOME/bin/rman"
    chmod +x "$ORACLE_HOME/bin/sqlplus" "$ORACLE_HOME/bin/rman"
    source "'"${PLUGIN_DIR}"'/lib/oracle.sh"
    type -t oracle_core_validate_home >/dev/null
    rm -rf "$ORACLE_HOME"
' 2>/dev/null; then
    echo "[PASS] oracle.sh loads correctly"
    TOTAL_PASS=$((TOTAL_PASS + 1))
else
    echo "[FAIL] oracle.sh failed to load"
    TOTAL_FAIL=$((TOTAL_FAIL + 1))
    FAILED_TESTS+=("Load: oracle.sh")
fi

# Test double-sourcing protection
if bash -c '
    export ORACLE_HOME=/tmp/mock_oh2_$$
    mkdir -p "$ORACLE_HOME/bin"
    touch "$ORACLE_HOME/bin/sqlplus" "$ORACLE_HOME/bin/rman"
    chmod +x "$ORACLE_HOME/bin/sqlplus" "$ORACLE_HOME/bin/rman"
    source "'"${PLUGIN_DIR}"'/lib/oracle.sh"
    source "'"${PLUGIN_DIR}"'/lib/oracle.sh"
    [[ -n "${__ORACLE_LOADED:-}" ]]
    rm -rf "$ORACLE_HOME"
' 2>/dev/null; then
    echo "[PASS] oracle.sh double-source protection works"
    TOTAL_PASS=$((TOTAL_PASS + 1))
else
    echo "[FAIL] oracle.sh double-source protection failed"
    TOTAL_FAIL=$((TOTAL_FAIL + 1))
    FAILED_TESTS+=("Double-source: oracle.sh")
fi

# Test report.sh loads correctly
if bash -c '
    source "'"${PLUGIN_DIR}"'/lib/report.sh"
    type -t report_init >/dev/null
' 2>/dev/null; then
    echo "[PASS] report.sh loads correctly"
    TOTAL_PASS=$((TOTAL_PASS + 1))
else
    echo "[FAIL] report.sh failed to load"
    TOTAL_FAIL=$((TOTAL_FAIL + 1))
    FAILED_TESTS+=("Load: report.sh")
fi

# Test queue.sh loads correctly
if bash -c '
    source "'"${PLUGIN_DIR}"'/lib/queue.sh"
    type -t queue_init >/dev/null
' 2>/dev/null; then
    echo "[PASS] queue.sh loads correctly"
    TOTAL_PASS=$((TOTAL_PASS + 1))
else
    echo "[FAIL] queue.sh failed to load"
    TOTAL_FAIL=$((TOTAL_FAIL + 1))
    FAILED_TESTS+=("Load: queue.sh")
fi

if [[ "${QUICK_MODE}" -eq 1 ]]; then
    echo
    echo "========================================"
    echo "  Quick Mode: Skipping unit tests"
    echo "========================================"
    echo
else
    #===============================================================================
    # PHASE 3: Unit Tests - Oracle
    #===============================================================================

    echo
    echo "========================================"
    echo "  Phase 3: Unit Tests - Oracle"
    echo "========================================"
    echo

    if [[ -x "${SCRIPT_DIR}/test_oracle.sh" ]]; then
        if "${SCRIPT_DIR}/test_oracle.sh"; then
            echo
            echo "[PASS] test_oracle.sh completed"
            TOTAL_PASS=$((TOTAL_PASS + 1))
        else
            echo
            echo "[FAIL] test_oracle.sh had failures"
            TOTAL_FAIL=$((TOTAL_FAIL + 1))
            FAILED_TESTS+=("Unit: test_oracle.sh")
        fi
    else
        echo "[SKIP] test_oracle.sh not found or not executable"
    fi

    #===============================================================================
    # PHASE 4: Unit Tests - Report
    #===============================================================================

    echo
    echo "========================================"
    echo "  Phase 4: Unit Tests - Report"
    echo "========================================"
    echo

    if [[ -x "${SCRIPT_DIR}/test_report.sh" ]]; then
        if "${SCRIPT_DIR}/test_report.sh"; then
            echo
            echo "[PASS] test_report.sh completed"
            TOTAL_PASS=$((TOTAL_PASS + 1))
        else
            echo
            echo "[FAIL] test_report.sh had failures"
            TOTAL_FAIL=$((TOTAL_FAIL + 1))
            FAILED_TESTS+=("Unit: test_report.sh")
        fi
    else
        echo "[SKIP] test_report.sh not found or not executable"
    fi

    #===============================================================================
    # PHASE 5: Unit Tests - Queue
    #===============================================================================

    echo
    echo "========================================"
    echo "  Phase 5: Unit Tests - Queue"
    echo "========================================"
    echo

    if [[ -x "${SCRIPT_DIR}/test_queue.sh" ]]; then
        if "${SCRIPT_DIR}/test_queue.sh"; then
            echo
            echo "[PASS] test_queue.sh completed"
            TOTAL_PASS=$((TOTAL_PASS + 1))
        else
            echo
            echo "[FAIL] test_queue.sh had failures"
            TOTAL_FAIL=$((TOTAL_FAIL + 1))
            FAILED_TESTS+=("Unit: test_queue.sh")
        fi
    else
        echo "[SKIP] test_queue.sh not found or not executable"
    fi
fi

#===============================================================================
# SUMMARY
#===============================================================================

echo
echo "========================================"
echo "  FINAL SUMMARY"
echo "========================================"
echo
echo "Total Passed: ${TOTAL_PASS}"
echo "Total Failed: ${TOTAL_FAIL}"

if [[ "${TOTAL_FAIL}" -gt 0 ]]; then
    echo
    echo "Failed tests:"
    for test in "${FAILED_TESTS[@]}"; do
        echo "  - ${test}"
    done
    echo
    echo "STATUS: FAILED"
    exit 1
else
    echo
    echo "STATUS: ALL TESTS PASSED"
    exit 0
fi
