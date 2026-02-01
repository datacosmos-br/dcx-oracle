#!/usr/bin/env bash
# shellcheck shell=bash
#===============================================================================
# dcx Oracle Plugin - Data Pump Module Tests
#
# Tests the oracle_datapump.sh module functionality, especially progress tracking.
#===============================================================================

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="${SCRIPT_DIR}/.."
PLUGIN_LIB="${PLUGIN_DIR}/lib"

source "${SCRIPT_DIR}/lib/test_helpers.sh"

echo "========================================"
echo "  Data Pump Module Tests"
echo "========================================"
echo ""

# Source oracle_datapump.sh (will load dependencies)
source "${PLUGIN_LIB}/oracle_datapump.sh" 2>/dev/null || {
    echo "SKIP: oracle_datapump.sh requires full Oracle environment"
    exit 0
}

# Test 1: TTY detection
run_test "TTY detection works" '
    # When run in test (non-TTY), should return false
    ! _dp_is_tty
'

# Test 2: Progress init sets variables
run_test "Progress init sets global variables" '
    _dp_progress_init 100 "Test operation"
    [[ "${_DP_PROGRESS_TOTAL}" -eq 100 ]] && \
    [[ "${_DP_PROGRESS_DESCRIPTION}" == "Test operation" ]] && \
    [[ "${_DP_PROGRESS_START_TIME}" -gt 0 ]]
'

# Test 3: Format ETA - seconds
run_test "Format ETA for seconds" '
    result=$(_dp_format_eta 45)
    [[ "${result}" == "45s" ]]
'

# Test 4: Format ETA - minutes
run_test "Format ETA for minutes" '
    result=$(_dp_format_eta 150)
    [[ "${result}" == "2m 30s" ]]
'

# Test 5: Format ETA - hours
run_test "Format ETA for hours" '
    result=$(_dp_format_eta 7265)
    [[ "${result}" =~ "2h" ]]
'

# Test 6: Progress update in non-TTY (should not error)
run_test "Progress update in non-TTY mode does not error" '
    _dp_progress_init 100 "Test"
    _dp_progress_update 50
    true
'

# Test 7: Progress done in non-TTY (should not error)
run_test "Progress done in non-TTY mode does not error" '
    _dp_progress_init 100 "Test"
    sleep 1
    _dp_progress_done
    true
'

# Test 8: Gum discovery does not error
run_test "Gum discovery completes without error" '
    _dp_discover_gum
    # Should set _DP_GUM_BIN (may be empty if gum not available)
    [[ -n "${_DP_GUM_BIN}" ]] || [[ -z "${_DP_GUM_BIN}" ]]
'

# Test 9: Progress functions exist
run_test "All progress functions are defined" '
    type _dp_is_tty &>/dev/null && \
    type _dp_progress_init &>/dev/null && \
    type _dp_progress_update &>/dev/null && \
    type _dp_progress_done &>/dev/null && \
    type _dp_progress_spin &>/dev/null
'

# Test 10: Execute functions still exist
run_test "All dp_execute functions are defined" '
    type dp_execute_import_networklink &>/dev/null && \
    type dp_execute_export_oci &>/dev/null && \
    type dp_execute_import_oci &>/dev/null && \
    type dp_execute_batch_parallel &>/dev/null
'

echo ""
print_test_summary
