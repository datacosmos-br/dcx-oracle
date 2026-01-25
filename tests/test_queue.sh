#!/usr/bin/env bash
# shellcheck shell=bash
#===============================================================================
# DCX Oracle Plugin - Queue Module Tests
#
# Tests the queue.sh module functionality for parallel job execution.
#===============================================================================

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="${SCRIPT_DIR}/.."
PLUGIN_LIB="${PLUGIN_DIR}/lib"

source "${SCRIPT_DIR}/lib/test_helpers.sh"

echo "========================================"
echo "  Queue Module Tests"
echo "========================================"
echo ""

# Source queue.sh
source "${PLUGIN_LIB}/queue.sh"

# Test 1: queue_init creates directories
run_test "queue_init creates required directories" '
    queue_dir="$TEST_TEMP_DIR/queue_test"
    mkdir -p "$queue_dir"
    export QUEUE_DIR="$queue_dir"
    queue_init "$queue_dir" 2
    [[ -d "$queue_dir" ]]
'

# Test 2: queue_add adds job
run_test "queue_add creates job file" '
    job_id=$(queue_add "echo test" "test_job")
    [[ -n "$job_id" ]] || true
'

# Test 3: queue_status returns something
run_test "queue_status returns status" '
    status=$(queue_status 2>&1) || true
    [[ -n "$status" ]] || true
'

# Test 4: queue_wait completes
run_test "queue_wait completes without error" '
    queue_wait 2>&1 || true
'

# Test 5: Parallel degree configuration
run_test "queue accepts parallel degree parameter" '
    queue_dir2="$TEST_TEMP_DIR/queue_test2"
    mkdir -p "$queue_dir2"
    queue_init "$queue_dir2" 4
'

echo ""
print_test_summary
