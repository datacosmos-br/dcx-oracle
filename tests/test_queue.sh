#!/usr/bin/env bash
# shellcheck shell=bash
#===============================================================================
# dcx Oracle Plugin - Queue Module Tests
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

# Test 1: queue_init configures queue state
run_test "queue_init configures concurrency" '
    queue_init 2
    [[ "$QUEUE_MAX_CONCURRENT" == "2" ]]
    [[ "$QUEUE_ACTIVE_COUNT" == "0" ]]
'

# Test 2: queue_add adds job
run_test "queue_add creates job file" '
    job_id=$(queue_add "echo test" "test_job")
    [[ -n "$job_id" ]]
'

# Test 3: queue_status returns something
run_test "queue_status returns status" '
    status=$(queue_status 2>&1)
    [[ "$status" == active=* ]]
'

# Test 4: queue_wait completes
run_test "queue_wait completes without error" '
    queue_wait 2>&1
'

# Test 5: Parallel degree configuration
run_test "queue accepts parallel degree parameter" '
    queue_init 4
    [[ "$QUEUE_MAX_CONCURRENT" == "4" ]]
'

echo ""
print_test_summary
