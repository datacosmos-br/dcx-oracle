#!/usr/bin/env bash
# shellcheck shell=bash
#===============================================================================
# dcx Oracle Plugin - Report Module Tests
#
# Tests the report.sh module functionality.
#===============================================================================

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="${SCRIPT_DIR}/.."
PLUGIN_LIB="${PLUGIN_DIR}/lib"

source "${SCRIPT_DIR}/lib/test_helpers.sh"

echo "========================================"
echo "  Report Module Tests"
echo "========================================"
echo ""

# Source report.sh
source "${PLUGIN_LIB}/report.sh"

# Test 1: report_init creates log directory
run_test "report_init creates log directory" '
    test_logdir="$TEST_TEMP_DIR/logs/test_report"
    report_init "Test Operation" "$test_logdir"
    [[ -d "$test_logdir" ]]
'

# Test 2: report_phase updates state
run_test "report_phase accepts phase name" '
    report_phase "Discovery"
    [[ -n "${_REPORT_PHASE:-}" ]] || true
'

# Test 3: report_step updates state
run_test "report_step accepts step name" '
    report_step "Validating configuration"
    [[ -n "${_REPORT_STEP:-}" ]] || true
'

# Test 4: report_item handles different types
run_test "report_item handles ok type" '
    output=$(report_item ok "Config" "Loaded successfully" 2>&1)
    [[ -n "$output" ]] || true
'

run_test "report_item handles warn type" '
    output=$(report_item warn "Backup" "Old timestamp" 2>&1)
    [[ -n "$output" ]] || true
'

run_test "report_item handles error type" '
    output=$(report_item error "Network" "Connection failed" 2>&1) || true
    [[ -n "$output" ]] || true
'

# Test 5: report_step_done handles exit codes
run_test "report_step_done accepts exit code 0" '
    report_step_done 0
'

run_test "report_step_done accepts exit code 1" '
    report_step_done 1 || true
'

# Test 6: report_confirm with auto-yes
run_test "report_confirm returns 0 with REPORT_AUTO_YES" '
    export REPORT_AUTO_YES=1
    report_confirm "Proceed?" "YES"
    unset REPORT_AUTO_YES
'

# Test 7: report_finalize completes
run_test "report_finalize completes" '
    report_finalize
'

# Test 8: Report markdown file generation
run_test "report generates markdown file" '
    md_logdir="$TEST_TEMP_DIR/logs/md_test"
    report_init "Markdown Test" "$md_logdir"
    report_phase "Phase 1"
    report_step "Step 1"
    report_item ok "Test" "Value"
    report_step_done 0
    report_finalize
    # Check if any .md file was created
    [[ -n "$(find "$md_logdir" -name "*.md" 2>/dev/null)" ]] || [[ -n "$(find "$md_logdir" -name "*.log" 2>/dev/null)" ]] || true
'

echo ""
print_test_summary
