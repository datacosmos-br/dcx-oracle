#!/usr/bin/env bash
#===============================================================================
# Test: Oracle Data Pump Optimization
#===============================================================================

# Load test helpers
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../tests/test_helpers.sh"

# Mock oracle_datapump.sh dependencies
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/oracle_core.sh"
# Mock log functions to avoid clutter
log_info() { echo "[INFO] $*"; }
log_debug() { echo "[DEBUG] $*"; }
log_error() { echo "[ERROR] $*"; }
rt_assert_file_exists() { [[ -f "$2" ]] || return 1; }

# Source module under test
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/oracle_datapump.sh"

describe "Data Pump Categorization"

# Test 1: Ants vs Elephants
test_ants_elephants() {
	TEST_DIR=$(mktemp -d)
	SIZES_FILE="${TEST_DIR}/sizes.txt"

	cat >"${SIZES_FILE}" <<EOF
BIG_TABLE|2000
MEDIUM_TABLE|500
SMALL_TABLE_1|50
SMALL_TABLE_2|10
EOF

	# Run categorization
	dp_categorize_tables "${SIZES_FILE}" 100 1000

	# Check Ants
	assert_eq 2 "${#_DP_ANTS[@]}" "Should identify 2 ants"
	assert_match 'SMALL_TABLE_1' "${_DP_ANTS[*]}"
	assert_match 'SMALL_TABLE_2' "${_DP_ANTS[*]}"

	# Check Elephants
	assert_eq 2 "${#_DP_ELEPHANTS[@]}" "Should identify 2 elephants/mediums"
	assert_match 'BIG_TABLE' "${_DP_ELEPHANTS[*]}"
	assert_match 'MEDIUM_TABLE' "${_DP_ELEPHANTS[*]}"

	rm -rf "${TEST_DIR}"
}
run_test "categorizes tables correctly" test_ants_elephants

# Test 2: Empty File
test_empty_file() {
	TEST_DIR=$(mktemp -d)
	SIZES_FILE="${TEST_DIR}/sizes.txt"
	touch "${SIZES_FILE}"

	dp_categorize_tables "${SIZES_FILE}"

	assert_eq 0 "${#_DP_ANTS[@]}" "Should have 0 ants"
	assert_eq 0 "${#_DP_ELEPHANTS[@]}" "Should have 0 elephants"

	rm -rf "${TEST_DIR}"
}
run_test "handles empty file gracefully" test_empty_file

# Test 3: Custom Thresholds
test_custom_thresholds() {
	TEST_DIR=$(mktemp -d)
	SIZES_FILE="${TEST_DIR}/sizes.txt"
	cat >"${SIZES_FILE}" <<EOF
T1|50
T2|150
T3|500
EOF

	# Threshold: Ant < 200, Elephant > 1000
	dp_categorize_tables "${SIZES_FILE}" 200 1000

	assert_eq 2 "${#_DP_ANTS[@]}" "Should have 2 ants with higher threshold"
	assert_match 'T2' "${_DP_ANTS[*]}"
	assert_eq 1 "${#_DP_ELEPHANTS[@]}" "Should have 1 elephant"
	assert_match 'T3' "${_DP_ELEPHANTS[*]}"

	rm -rf "${TEST_DIR}"
}
run_test "respects custom thresholds" test_custom_thresholds

test_summary
