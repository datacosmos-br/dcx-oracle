#!/usr/bin/env bash
# shellcheck shell=bash
#===============================================================================
# Datacosmos - Unified Workflow & Report System
#
# Copyright (c) 2026 Datacosmos
# Licensed under the Apache License, Version 2.0
#===============================================================================
# File    : report.sh
# Version : 2.0.0
# Date    : 2026-01-15
#===============================================================================
#
# DESCRIPTION:
#   Unified workflow orchestration system that integrates:
#   - Step/phase tracking with automatic timing
#   - Item and metric collection
#   - Interactive confirmations and selections
#   - Dual output (console real-time + file at end)
#
# USAGE:
#   source "$(dirname "$0")/lib/report.sh"
#   report_init "My Script" "/var/log/myapp" "session_id"
#   report_phase "Validation"
#   report_step "Checking prerequisites"
#   report_step_done 0
#   report_finalize
#
# DEPENDS ON:
#   - logging.sh (for colors, timestamps, basic log functions)
#   - runtime.sh (for runtime_format_duration, runtime_ensure_dir)
#
#===============================================================================

# Prevent double sourcing
[[ -n "${__REPORT_LOADED:-}" ]] && return 0
__REPORT_LOADED=1

_REPORT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load dependencies
# shellcheck source=/dev/null
[[ -z "${__LOGGING_LOADED:-}" ]] && source "${_REPORT_LIB_DIR}/logging.sh"
# shellcheck source=/dev/null
[[ -z "${__RUNTIME_LOADED:-}" ]] && source "${_REPORT_LIB_DIR}/runtime.sh"

#===============================================================================
# SECTION 0: Global State & Configuration
#===============================================================================

declare -gA _R_META=()           # Metadata: key -> value
declare -ga _R_PHASES=()         # Phases: "name|start_time"
declare -ga _R_STEPS=()          # Steps: "phase_idx|name|status|start_time|end_time|detail"
declare -ga _R_ITEMS=()          # Items: "step_idx|status|name|detail"
declare -gA _R_METRICS=()        # Metrics: key -> value
declare -ga _R_CONFIRMS=()       # Confirms: "step_idx|type|prompt|response"

declare -g _R_TITLE=""           # Report title
declare -g _R_OUTPUT_DIR=""      # Output directory
declare -g _R_SESSION=""         # Session ID
declare -g _R_START_TIME=0       # Start timestamp
declare -g _R_CURRENT_PHASE=-1   # Current phase index
declare -g _R_CURRENT_STEP=-1    # Current step index
declare -g _R_STEP_COUNT=0       # Total step count (for display)
declare -g _R_INITIALIZED=0      # Initialization flag

# Configuration (can be overridden via environment)
REPORT_AUTO_YES="${REPORT_AUTO_YES:-${AUTO_YES:-0}}"
REPORT_AUTO_NO="${REPORT_AUTO_NO:-0}"
REPORT_OUTPUT_FORMAT="${REPORT_OUTPUT_FORMAT:-md}"
REPORT_SHOW_TIMING="${REPORT_SHOW_TIMING:-1}"
REPORT_CONSOLE_WIDTH="${REPORT_CONSOLE_WIDTH:-70}"

#===============================================================================
# SECTION 0.5: Validation Helpers (NEW)
#===============================================================================

# _report_validate_param - Validate parameter presence
# Usage: _report_validate_param "$value" "param_name" [allow_empty]
_report_validate_param() {
    local value="${1?ERROR: _report_validate_param requires value parameter}"
    local param_name="${2?ERROR: _report_validate_param requires param_name parameter}"
    local allow_empty="${3:-0}"

    if [[ -z "${value}" ]] && [[ ${allow_empty} -eq 0 ]]; then
        die "ERROR: ${param_name} is required but empty"
    fi
}

# validate_item_status - Validate item status value
validate_item_status() {
    local status="${1?ERROR: validate_item_status requires status parameter}"
    case "${status}" in
        ok|success|fail|error|skip|warn|warning) return 0 ;;
        *) die "ERROR: Invalid item status '${status}' (expected: ok|fail|skip|warn)" ;;
    esac
}

# validate_metric_operation - Validate metric operation
validate_metric_operation() {
    local operation="${1?ERROR: validate_metric_operation requires operation parameter}"
    case "${operation}" in
        set|add|max|min) return 0 ;;
        *) die "ERROR: Invalid metric operation '${operation}' (expected: set|add|max|min)" ;;
    esac
}

# validate_confirmation_token - Validate confirmation token format
validate_confirmation_token() {
    local token="${1?ERROR: validate_confirmation_token requires token parameter}"
    [[ -n "${token}" ]] || die "ERROR: Confirmation token cannot be empty"
}

# validate_selection_choice - Validate selection choice is within range
validate_selection_choice() {
    local choice="${1?ERROR: validate_selection_choice requires choice parameter}"
    local max_options="${2?ERROR: validate_selection_choice requires max_options parameter}"
    [[ "${choice}" =~ ^[0-9]+$ ]] || die "ERROR: Selection must be numeric"
    [[ ${choice} -ge 0 && ${choice} -lt ${max_options} ]] || die "ERROR: Selection out of range (0-$((max_options-1)))"
}

# validate_output_format - Validate output format
validate_output_format() {
    local format="${1?ERROR: validate_output_format requires format parameter}"
    case "${format}" in
        md|markdown|json|text) return 0 ;;
        *) die "ERROR: Invalid output format '${format}' (expected: md|json|text)" ;;
    esac
}

# validate_file_exists - Validate file exists
validate_file_exists() {
    local file="${1?ERROR: validate_file_exists requires file parameter}"
    [[ -f "${file}" ]] || die "ERROR: File not found: ${file}"
}

# validate_directory_exists - Validate directory exists
validate_directory_exists() {
    local dir="${1?ERROR: validate_directory_exists requires dir parameter}"
    [[ -d "${dir}" ]] || die "ERROR: Directory not found: ${dir}"
}

#===============================================================================
# SECTION 1: Core API - Initialization & Metadata
#===============================================================================

# report_init - Initialize workflow/report system
# Usage: report_init "Title" "/output/dir" ["session_id"]
report_init() {
    local title="${1?ERROR: report_init requires title parameter}"
    local output_dir="${2?ERROR: report_init requires output_dir parameter}"
    local session="${3:-$(date +%Y%m%d_%H%M%S)}"

    _R_TITLE="${title}"
    _R_OUTPUT_DIR="${output_dir}"
    _R_SESSION="${session}"
    _R_START_TIME=$(date +%s)
    _R_CURRENT_PHASE=-1
    _R_CURRENT_STEP=-1
    _R_STEP_COUNT=0
    _R_INITIALIZED=1

    # Reset arrays
    _R_META=()
    _R_PHASES=()
    _R_STEPS=()
    _R_ITEMS=()
    _R_METRICS=()
    _R_CONFIRMS=()

    runtime_ensure_dir "${_R_OUTPUT_DIR}"
    log "Report initialized: ${_R_TITLE} (session: ${_R_SESSION})"
}

# report_meta - Add metadata
# Usage: report_meta "key" "value"
report_meta() {
    local key="${1?ERROR: report_meta requires key parameter}"
    local value="${2?ERROR: report_meta requires value parameter}"
    _R_META["${key}"]="${value}"
}

# report_get_meta - Get metadata value
# Usage: value=$(report_get_meta "key")
report_get_meta() {
    local key="${1?ERROR: report_get_meta requires key parameter}"
    echo "${_R_META["${key}"]:-}"
}

#===============================================================================
# SECTION 1: Core API - Workflow Structure (Phase/Section/Step)
#===============================================================================

# report_phase - Start a major phase (with visual separator)
# Usage: report_phase "Phase description"
report_phase() {
    local name="${1?ERROR: report_phase requires name parameter}"
    local start_time
    start_time=$(date +%s)

    (( _R_CURRENT_PHASE++ )) || true
    _R_PHASES+=("${name}|${start_time}")

    echo
    echo "════════════════════════════════════════════════════════════════════"
    echo -e "  ${_C_BOLD}PHASE $((${_R_CURRENT_PHASE} + 1)): ${name}${_C_RESET}"
    echo "════════════════════════════════════════════════════════════════════"
}

# report_section - Start a section (smaller than phase)
# Usage: report_section "Section title"
report_section() {
    local title="${1?ERROR: report_section requires title parameter}"
    echo
    echo "================================================================"
    echo "  ${title}"
    echo "================================================================"
}

# report_step - Start a tracked step with automatic timing
# Usage: report_step "Step description"
report_step() {
    local name="${1?ERROR: report_step requires name parameter}"
    local start_time
    start_time=$(date +%s)

    (( _R_CURRENT_STEP++ )) || true
    (( _R_STEP_COUNT++ )) || true
    _R_STEPS+=("${_R_CURRENT_PHASE}|${name}|pending|${start_time}|0|")

    echo
    echo -e "${_C_BOLD}>> Step ${_R_STEP_COUNT}: ${name}${_C_RESET}"
}

# report_step_done - Finalize current step
# Usage: report_step_done [exit_code] ["detail"]
report_step_done() {
    local exit_code="${1?ERROR: report_step_done requires exit_code parameter}"
    local detail="${2:-}"
    local end_time
    end_time=$(date +%s)

    if [[ ${_R_CURRENT_STEP} -lt 0 ]]; then
        warn "report_step_done called without active step"
        return
    fi

    # Parse current step data
    local step_data="${_R_STEPS[${_R_CURRENT_STEP}]}"
    local phase_idx step_name status start_time _old_end _old_detail
    IFS='|' read -r phase_idx step_name status start_time _old_end _old_detail <<< "${step_data}"

    local duration=$((end_time - start_time))
    local new_status="success"
    [[ ${exit_code} -ne 0 ]] && new_status="failed"

    # Update step
    _R_STEPS[${_R_CURRENT_STEP}]="${phase_idx}|${step_name}|${new_status}|${start_time}|${end_time}|${detail}"

    # Console output
    local duration_fmt
    duration_fmt=$(runtime_format_duration "${duration}")

    if [[ "${new_status}" == "success" ]]; then
        echo -e "${_C_GREEN}[SUCCESS]${_C_RESET} Step completed (${duration_fmt})"
    else
        echo -e "${_C_RED}[ERROR]${_C_RESET} Step failed (${duration_fmt})${detail:+ - ${detail}}" >&2
    fi
}

#===============================================================================
# SECTION 2: Data Collection - Items and Metrics
#===============================================================================

# report_item - Register an item processed (auto-detects current step)
# Usage: report_item "status" "name" ["detail"]
# status: ok, fail, skip, warn
report_item() {
    local status="${1?ERROR: report_item requires status parameter}"
    local name="${2?ERROR: report_item requires name parameter}"
    local detail="${3:-}"

    _R_ITEMS+=("${_R_CURRENT_STEP}|${status}|${name}|${detail}")

    # Console output based on status
    case "${status}" in
        ok|success)
            echo -e "  ${_C_GREEN}✓${_C_RESET} ${name}${detail:+ - ${detail}}"
            ;;
        fail|error)
            echo -e "  ${_C_RED}✗${_C_RESET} ${name}${detail:+ - ${detail}}" >&2
            ;;
        skip)
            echo -e "  ${_C_GRAY}○${_C_RESET} ${name}${detail:+ - ${detail}}"
            ;;
        warn|warning)
            echo -e "  ${_C_YELLOW}⚠${_C_RESET} ${name}${detail:+ - ${detail}}"
            ;;
        *)
            echo "  - ${name}${detail:+ - ${detail}}"
            ;;
    esac
}

# report_metric - Register a metric (accumulative support)
# Usage: report_metric "key" "value" ["operation"]
# operation: set (default), add, max, min
report_metric() {
    local key="${1?ERROR: report_metric requires key parameter}"
    local value="${2?ERROR: report_metric requires value parameter}"
    local operation="${3:-set}"

    case "${operation}" in
        set)
            _R_METRICS["${key}"]="${value}"
            ;;
        add)
            local current="${_R_METRICS["${key}"]:-0}"
            _R_METRICS["${key}"]=$((current + value))
            ;;
        max)
            local current="${_R_METRICS["${key}"]:-0}"
            [[ ${value} -gt ${current} ]] && _R_METRICS["${key}"]="${value}"
            ;;
        min)
            local current="${_R_METRICS["${key}"]:-999999999}"
            [[ ${value} -lt ${current} ]] && _R_METRICS["${key}"]="${value}"
            ;;
    esac
}

# report_metric_get - Get metric value
# Usage: value=$(report_metric_get "key")
report_metric_get() {
    local key="${1?ERROR: report_metric_get requires key parameter}"
    echo "${_R_METRICS["${key}"]:-0}"
}

#===============================================================================
# SECTION 3: Interactions - Confirmations and Selections
#===============================================================================

# report_confirm - Request confirmation
# Usage: report_confirm "message" ["token"] ["default_token"]
# Returns: 0 if confirmed, 1 if denied
# Respects: REPORT_AUTO_YES, REPORT_AUTO_NO
report_confirm() {
    local msg="${1?ERROR: report_confirm requires message parameter}"
    local token="${2:-YES}"
    local _default="${3:-}"  # Reserved for future default behavior

    # Record the confirmation request
    _R_CONFIRMS+=("${_R_CURRENT_STEP}|confirm|${msg}|pending")
    local confirm_idx=$((${#_R_CONFIRMS[@]} - 1))

    # Handle AUTO modes
    if [[ "${REPORT_AUTO_YES}" == "1" ]]; then
        echo -e "${_C_YELLOW}[AUTO_YES]${_C_RESET} Skipping: ${msg}"
        _R_CONFIRMS[${confirm_idx}]="${_R_CURRENT_STEP}|confirm|${msg}|auto_yes"
        return 0
    fi

    if [[ "${REPORT_AUTO_NO}" == "1" ]]; then
        echo -e "${_C_RED}[AUTO_NO]${_C_RESET} Denied: ${msg}"
        _R_CONFIRMS[${confirm_idx}]="${_R_CURRENT_STEP}|confirm|${msg}|auto_no"
        return 1
    fi

    # Interactive confirmation
    echo
    echo "========== CONFIRMACAO =========="
    echo "${msg}"
    echo "Digite: ${token}"
    echo "================================="

    local ans
    read -r ans

    if [[ "${ans}" == "${token}" ]]; then
        _R_CONFIRMS[${confirm_idx}]="${_R_CURRENT_STEP}|confirm|${msg}|confirmed"
        return 0
    else
        _R_CONFIRMS[${confirm_idx}]="${_R_CURRENT_STEP}|confirm|${msg}|denied"
        return 1
    fi
}

# report_confirm_retype - Confirmation by retyping a value
# Usage: report_confirm_retype "message" "expected_value"
report_confirm_retype() {
    local msg="${1?ERROR: report_confirm_retype requires message parameter}"
    local expected="${2?ERROR: report_confirm_retype requires expected parameter}"

    _R_CONFIRMS+=("${_R_CURRENT_STEP}|retype|${msg}|pending")
    local confirm_idx=$((${#_R_CONFIRMS[@]} - 1))

    if [[ "${REPORT_AUTO_YES}" == "1" ]]; then
        echo -e "${_C_YELLOW}[AUTO_YES]${_C_RESET} Skipping retype: ${msg}"
        _R_CONFIRMS[${confirm_idx}]="${_R_CURRENT_STEP}|retype|${msg}|auto_yes"
        return 0
    fi

    if [[ "${REPORT_AUTO_NO}" == "1" ]]; then
        echo -e "${_C_RED}[AUTO_NO]${_C_RESET} Denied retype: ${msg}"
        _R_CONFIRMS[${confirm_idx}]="${_R_CURRENT_STEP}|retype|${msg}|auto_no"
        return 1
    fi

    echo
    echo "========== CONFIRMACAO =========="
    echo "${msg}"
    echo "Redigite: ${expected}"
    echo "================================="

    local ans
    read -r ans

    if [[ "${ans}" == "${expected}" ]]; then
        _R_CONFIRMS[${confirm_idx}]="${_R_CURRENT_STEP}|retype|${msg}|confirmed"
        return 0
    else
        _R_CONFIRMS[${confirm_idx}]="${_R_CURRENT_STEP}|retype|${msg}|denied"
        die "Confirmacao falhou."
    fi
}

# report_select - Selection menu
# Usage: choice=$(report_select "prompt" "option1" "option2" ...)
# Returns: index of selected option (0-based)
report_select() {
    local prompt="${1?ERROR: report_select requires prompt parameter}"
    shift
    local options=("$@")

    _R_CONFIRMS+=("${_R_CURRENT_STEP}|select|${prompt}|pending")
    local confirm_idx=$((${#_R_CONFIRMS[@]} - 1))

    if [[ "${REPORT_AUTO_YES}" == "1" ]]; then
        echo -e "${_C_YELLOW}[AUTO_YES]${_C_RESET} Auto-selecting first option: ${options[0]}"
        _R_CONFIRMS[${confirm_idx}]="${_R_CURRENT_STEP}|select|${prompt}|auto:0"
        echo "0"
        return 0
    fi

    echo
    echo "========== SELECAO =========="
    echo "${prompt}"
    echo "-----------------------------"
    local i
    for i in "${!options[@]}"; do
        echo "  $((i + 1))) ${options[$i]}"
    done
    echo "-----------------------------"
    echo -n "Digite o numero: "

    local choice
    read -r choice

    # Validate
    if [[ ! "${choice}" =~ ^[0-9]+$ ]] || [[ ${choice} -lt 1 ]] || [[ ${choice} -gt ${#options[@]} ]]; then
        die "Selecao invalida: ${choice}"
    fi

    local selected_idx=$((choice - 1))
    _R_CONFIRMS[${confirm_idx}]="${_R_CURRENT_STEP}|select|${prompt}|selected:${selected_idx}"
    echo "${selected_idx}"
}

# report_preview_exec - Preview file + confirm + execute command
# Usage: report_preview_exec "file_to_preview" "command" [args...]
# Returns: exit code of command
report_preview_exec() {
    local preview_file="${1?ERROR: report_preview_exec requires preview_file parameter}"
    shift
    local cmd="${1?ERROR: report_preview_exec requires command parameter}"
    shift
    local args=("$@")

    # Preview
    log "[PREVIEW] File: ${preview_file}"
    show_file "${preview_file}" 200

    # Confirm
    if ! report_confirm "Executar ${cmd}?" "YES"; then
        warn "Execucao cancelada pelo usuario"
        return 1
    fi

    # Execute
    log_cmd_start "${cmd}" "Executing..."
    local start_time rc
    start_time=$(date +%s)

    set +e
    "${cmd}" "${args[@]}"
    rc=$?
    set -e

    local duration
    duration=$(runtime_format_duration $(($(date +%s) - start_time)))
    log_cmd_end "${cmd}" "${rc}" "${duration}"

    return ${rc}
}

#===============================================================================
# SECTION 4: Reporting & Display - Output Formatting
#===============================================================================

# report_kv - Display aligned key-value pair
# Usage: report_kv "key" "value" ["mask"]
report_kv() {
    local key="${1?ERROR: report_kv requires key parameter}"
    local value="${2?ERROR: report_kv requires value parameter}"
    local mask="${3:-}"

    [[ "${mask}" == "mask" ]] && value="********"
    printf "  %-26s : %s\n" "${key}" "${value}"
}

# report_vars - Display block of variables
# Usage: report_vars "title" "KEY1=val1" "KEY2=val2" ...
report_vars() {
    local title="${1?ERROR: report_vars requires title parameter}"
    shift

    echo
    echo "┌─────────────────────────────────────────────────────────────┐"
    echo "│ ${title}"
    echo "├─────────────────────────────────────────────────────────────┤"

    local kv key val
    for kv in "$@"; do
        key="${kv%%=*}"
        val="${kv#*=}"
        # Mask passwords
        [[ "${key}" == *PASSWORD* || "${key}" == *SECRET* ]] && val="********"
        report_kv "${key}" "${val}"
    done

    echo "└─────────────────────────────────────────────────────────────┘"
}

# report_table - Display formatted table
# Usage: report_table "title" "col1|col2|col3" "val1|val2|val3" ...
report_table() {
    local title="${1?ERROR: report_table requires title parameter}"
    shift

    echo
    echo "┌─────────────────────────────────────────────────────────────┐"
    echo "│ ${title}"
    echo "├─────────────────────────────────────────────────────────────┤"

    local first=1
    local row
    for row in "$@"; do
        if [[ ${first} -eq 1 ]]; then
            # Header row
            echo "│ ${row//|/  |  }"
            echo "├─────────────────────────────────────────────────────────────┤"
            first=0
        else
            echo "│ ${row//|/  |  }"
        fi
    done

    echo "└─────────────────────────────────────────────────────────────┘"
}

#===============================================================================
# SECTION 4: Reporting & Display - Summary and Finalization
#===============================================================================

# _report_calculate_totals - Internal: Calculate summary totals
# Uses nameref to populate an associative array passed by name
# shellcheck disable=SC2154  # False positive: vars are set via nameref
_report_calculate_totals() {
    local -n totals_ref=$1

    totals_ref[total_phases]=${#_R_PHASES[@]}
    totals_ref[total_steps]=${#_R_STEPS[@]}
    totals_ref[steps_ok]=0
    totals_ref[steps_fail]=0
    totals_ref[total_items]=${#_R_ITEMS[@]}
    totals_ref[items_ok]=0
    totals_ref[items_fail]=0
    totals_ref[items_skip]=0
    totals_ref[items_warn]=0

    # Count step statuses
    # Note: Use ((++var)) or || true to avoid exit code 1 when var=0 with set -e
    local step_data status
    for step_data in "${_R_STEPS[@]}"; do
        IFS='|' read -r _ _ status _ _ _ <<< "${step_data}"
        case "${status}" in
            success) ((++totals_ref[steps_ok])) ;;
            failed)  ((++totals_ref[steps_fail])) ;;
        esac
    done

    # Count item statuses
    local item_data
    for item_data in "${_R_ITEMS[@]}"; do
        IFS='|' read -r _ status _ _ <<< "${item_data}"
        case "${status}" in
            ok|success) ((++totals_ref[items_ok])) ;;
            fail|error) ((++totals_ref[items_fail])) ;;
            skip)       ((++totals_ref[items_skip])) ;;
            warn|warning) ((++totals_ref[items_warn])) ;;
        esac
    done

    # Total duration
    local end_time
    end_time=$(date +%s)
    totals_ref[total_duration]=$((end_time - _R_START_TIME))
}

# report_summary - Display summary on console (without finalizing)
# Usage: report_summary ["custom_title"]
report_summary() {
    local custom_title="${1:-${_R_TITLE} SUMMARY}"

    declare -A totals
    _report_calculate_totals totals

    local duration_fmt
    duration_fmt=$(runtime_format_duration "${totals[total_duration]}")

    local final_status="SUCCESS"
    [[ ${totals[steps_fail]} -gt 0 || ${totals[items_fail]} -gt 0 ]] && final_status="COMPLETED WITH ERRORS"

    echo
    echo "================================================================"
    echo "  ${custom_title}"
    echo "================================================================"
    echo "  Phases:   ${totals[total_phases]}"
    echo "  Steps:    ${totals[total_steps]} total, ${totals[steps_ok]} success, ${totals[steps_fail]} failed"
    echo "  Items:    ${totals[total_items]} total, ${totals[items_ok]} ok, ${totals[items_fail]} fail, ${totals[items_skip]} skip"
    echo "  Duration: ${duration_fmt}"
    echo "================================================================"
    echo "  STATUS: ${final_status}"
    echo "================================================================"
    echo
}

# _report_write_markdown - Internal: Write markdown report file
_report_write_markdown() {
    local output_file="$1"

    declare -A totals
    _report_calculate_totals totals

    local duration_fmt
    duration_fmt=$(runtime_format_duration "${totals[total_duration]}")

    local final_status="SUCCESS"
    [[ ${totals[steps_fail]} -gt 0 || ${totals[items_fail]} -gt 0 ]] && final_status="COMPLETED WITH ERRORS"

    {
        # Header
        echo "# ${_R_TITLE}"
        echo
        echo "**Session:** \`${_R_SESSION}\`"
        echo "**Date:** $(date '+%Y-%m-%d %H:%M:%S')"
        echo "**Status:** ${final_status}"
        echo "**Duration:** ${duration_fmt}"
        echo

        # Metadata
        if [[ ${#_R_META[@]} -gt 0 ]]; then
            echo "## Metadata"
            echo
            echo "| Key | Value |"
            echo "|-----|-------|"
            local key
            for key in "${!_R_META[@]}"; do
                local val="${_R_META[${key}]}"
                [[ "${key}" == *PASSWORD* || "${key}" == *SECRET* ]] && val="********"
                echo "| ${key} | ${val} |"
            done
            echo
        fi

        # Summary
        echo "## Summary"
        echo
        echo "| Metric | Value |"
        echo "|--------|-------|"
        echo "| Phases | ${totals[total_phases]} |"
        echo "| Steps | ${totals[total_steps]} (${totals[steps_ok]} ok, ${totals[steps_fail]} fail) |"
        echo "| Items | ${totals[total_items]} (${totals[items_ok]} ok, ${totals[items_fail]} fail, ${totals[items_skip]} skip) |"
        echo "| Duration | ${duration_fmt} |"
        echo

        # Metrics
        if [[ ${#_R_METRICS[@]} -gt 0 ]]; then
            echo "## Metrics"
            echo
            echo "| Metric | Value |"
            echo "|--------|-------|"
            for key in "${!_R_METRICS[@]}"; do
                echo "| ${key} | ${_R_METRICS[${key}]} |"
            done
            echo
        fi

        # Module-specific sections
        _report_render_module_sections

        # Steps detail
        echo "## Steps Detail"
        echo
        local step_data phase_idx step_name status start_time end_time detail
        local step_num=0
        for step_data in "${_R_STEPS[@]}"; do
            (( step_num++ )) || true
            IFS='|' read -r phase_idx step_name status start_time end_time detail <<< "${step_data}"

            local step_duration=0
            [[ ${end_time} -gt 0 ]] && step_duration=$((end_time - start_time))
            local step_duration_fmt
            step_duration_fmt=$(runtime_format_duration "${step_duration}")

            local status_icon="✓"
            [[ "${status}" != "success" ]] && status_icon="✗"

            echo "### Step ${step_num}: ${step_name}"
            echo
            echo "- **Status:** ${status_icon} ${status}"
            echo "- **Duration:** ${step_duration_fmt}"
            [[ -n "${detail}" ]] && echo "- **Detail:** ${detail}"

            # Items for this step
            local item_data item_step_idx item_status item_name item_detail
            local has_items=0
            for item_data in "${_R_ITEMS[@]}"; do
                IFS='|' read -r item_step_idx item_status item_name item_detail <<< "${item_data}"
                if [[ ${item_step_idx} -eq $((step_num - 1)) ]]; then
                    if [[ ${has_items} -eq 0 ]]; then
                        echo
                        echo "**Items:**"
                        has_items=1
                    fi
                    local item_icon="○"
                    case "${item_status}" in
                        ok|success) item_icon="✓" ;;
                        fail|error) item_icon="✗" ;;
                        warn|warning) item_icon="⚠" ;;
                    esac
                    echo "- ${item_icon} ${item_name}${item_detail:+ - ${item_detail}}"
                fi
            done

            echo
        done

        # Confirmations
        if [[ ${#_R_CONFIRMS[@]} -gt 0 ]]; then
            echo "## Confirmations"
            echo
            echo "| Type | Prompt | Response |"
            echo "|------|--------|----------|"
            local confirm_data _confirm_step confirm_type confirm_prompt confirm_response
            for confirm_data in "${_R_CONFIRMS[@]}"; do
                IFS='|' read -r _confirm_step confirm_type confirm_prompt confirm_response <<< "${confirm_data}"
                echo "| ${confirm_type} | ${confirm_prompt} | ${confirm_response} |"
            done
            echo
        fi

        # Footer
        echo "---"
        echo
        echo "*Report generated at $(date '+%Y-%m-%d %H:%M:%S')*"
        echo "*Log directory: \`${_R_OUTPUT_DIR}\`*"

    } > "${output_file}"
}

# _report_render_module_sections - Render module-specific metric sections
# Called from _report_write_markdown to add module-specific details
_report_render_module_sections() {
    local -a modules=("dp" "sql" "rman" "instance" "env" "config" "cluster")
    local module

    for module in "${modules[@]}"; do
        case "${module}" in
            dp)
                _report_render_module_section "dp" "Data Pump Operations" \
                    "dp_parfiles_total" "Parfiles Processed" \
                    "dp_tables_processed" "Tables Imported" \
                    "dp_rows_imported" "Rows Imported" \
                    "dp_avg_throughput_mbps" "Throughput"
                ;;
            sql)
                _report_render_module_section "sql" "SQL Operations" \
                    "sql_scripts_executed" "Scripts Executed" \
                    "sql_successful" "Successful" \
                    "sql_failed" "Failed" \
                    "sql_duration_secs" "Duration (sec)"
                ;;
            rman)
                _report_render_module_section "rman" "RMAN Operations" \
                    "rman_transformations_total" "File Transformations" \
                    "rman_datafiles" "Datafiles" \
                    "rman_tempfiles" "Tempfiles" \
                    "rman_channels_used" "Channels Used"
                ;;
            instance)
                _report_render_module_section "instance" "Instance Operations" \
                    "instance_startups" "Startups" \
                    "instance_shutdowns" "Shutdowns" \
                    "instance_startup_duration" "Startup Time (sec)" \
                    "instance_shutdown_duration" "Shutdown Time (sec)"
                ;;
            env)
                _report_render_module_section "env" "Environment Operations" \
                    "env_initialized" "Initialization Status" \
                    "env_validations_passed" "Validations Passed" \
                    "env_validations_failed" "Validations Failed"
                ;;
            config)
                _report_render_module_section "config" "Configuration Operations" \
                    "config_db_size_gb" "DB Size (GB)" \
                    "config_paths_resolved" "Paths Resolved" \
                    "config_dirs_created" "Directories Created"
                ;;
            cluster)
                _report_render_module_section "cluster" "Cluster Operations" \
                    "cluster_detected" "Cluster Detected (1=yes, 0=no)" \
                    "cluster_rac" "RAC Enabled (1=yes, 0=no)" \
                    "cluster_node_count" "Node Count"
                ;;
        esac
    done
}

# _report_render_module_section - Render a single module's metrics section
# Usage: _report_render_module_section "dp" "Data Pump" "metric1" "Label1" "metric2" "Label2" ...
_report_render_module_section() {
    local module="$1"
    local title="$2"
    shift 2

    # Check if any metrics exist for this module
    local has_metrics=0
    local metric
    for metric in "${!_R_METRICS[@]}"; do
        [[ "${metric}" == ${module}_* ]] && { has_metrics=1; break; }
    done

    [[ ${has_metrics} -eq 0 ]] && return 0

    # Render module section
    echo "## ${title}"
    echo

    while [[ $# -gt 1 ]]; do
        local metric_key="$1"
        local metric_label="$2"
        shift 2

        local metric_value="${_R_METRICS[${metric_key}]:-}"
        [[ -z "${metric_value}" ]] && continue

        echo "- **${metric_label}:** ${metric_value}"
    done

    echo
}

# report_finalize - Generate final report (console + file)
# Usage: report_finalize ["format"]
# format: markdown (default), json, text
report_finalize() {
    local format="${1:-${REPORT_OUTPUT_FORMAT}}"

    # Console summary
    report_summary

    # File report
    local report_file="${_R_OUTPUT_DIR}/${_R_SESSION}_report.md"

    case "${format}" in
        md|markdown)
            _report_write_markdown "${report_file}"
            ;;
        json)
            report_file="${_R_OUTPUT_DIR}/${_R_SESSION}_report.json"
            _report_write_json "${report_file}"
            ;;
        *)
            _report_write_markdown "${report_file}"
            ;;
    esac

    log "Report saved: ${report_file}"
}

# _report_write_json - Internal: Write JSON report file
_report_write_json() {
    local output_file="$1"

    declare -A totals
    _report_calculate_totals totals

    {
        echo "{"
        echo "  \"title\": \"${_R_TITLE}\","
        echo "  \"session\": \"${_R_SESSION}\","
        echo "  \"timestamp\": \"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\","
        echo "  \"duration_seconds\": ${totals[total_duration]},"
        echo "  \"summary\": {"
        echo "    \"phases\": ${totals[total_phases]},"
        echo "    \"steps_total\": ${totals[total_steps]},"
        echo "    \"steps_ok\": ${totals[steps_ok]},"
        echo "    \"steps_fail\": ${totals[steps_fail]},"
        echo "    \"items_total\": ${totals[total_items]},"
        echo "    \"items_ok\": ${totals[items_ok]},"
        echo "    \"items_fail\": ${totals[items_fail]}"
        echo "  },"

        # Metadata
        echo "  \"metadata\": {"
        local first=1
        for key in "${!_R_META[@]}"; do
            [[ ${first} -eq 0 ]] && echo ","
            local val="${_R_META[${key}]}"
            [[ "${key}" == *PASSWORD* || "${key}" == *SECRET* ]] && val="********"
            echo -n "    \"${key}\": \"${val}\""
            first=0
        done
        echo
        echo "  },"

        # Metrics
        echo "  \"metrics\": {"
        first=1
        for key in "${!_R_METRICS[@]}"; do
            [[ ${first} -eq 0 ]] && echo ","
            echo -n "    \"${key}\": \"${_R_METRICS[${key}]}\""
            first=0
        done
        echo
        echo "  }"

        echo "}"
    } > "${output_file}"
}

#===============================================================================
# SECTION 5: Analysis & Utilities - Helper Functions
#===============================================================================

# report_is_initialized - Check if report system is initialized
# Usage: if report_is_initialized; then ...
report_is_initialized() {
    [[ ${_R_INITIALIZED} -eq 1 ]]
}

# report_get_session - Get current session ID
# Usage: session=$(report_get_session)
report_get_session() {
    echo "${_R_SESSION}"
}

# report_get_output_dir - Get output directory
# Usage: dir=$(report_get_output_dir)
report_get_output_dir() {
    echo "${_R_OUTPUT_DIR}"
}

# report_log - Log message and add to report
# Usage: report_log "message"
report_log() {
    log "$@"
}

# report_warn - Warn and add to report
# Usage: report_warn "message"
report_warn() {
    warn "$@"
}

#===============================================================================
# SECTION 5: Analysis & Utilities - Generic Output Analysis
#===============================================================================

# report_count_pattern - Count occurrences of pattern in file
# Usage: count=$(report_count_pattern "/path/to/file" "pattern")
report_count_pattern() {
    local file="$1"
    local pattern="$2"
    grep -c "${pattern}" "${file}" 2>/dev/null || echo 0
}

# report_extract_numbers - Extract numbers from file matching pattern
# Usage: sum=$(report_extract_numbers "/path/to/file" "pattern" "sum|max|min|first|last")
report_extract_numbers() {
    local file="$1"
    local pattern="$2"
    local operation="${3:-sum}"

    local numbers
    numbers=$(grep -oP "${pattern}" "${file}" 2>/dev/null | grep -oP '\d+')

    case "${operation}" in
        sum)
            echo "${numbers}" | awk '{s+=$1} END {print s+0}'
            ;;
        max)
            echo "${numbers}" | sort -rn | head -1
            ;;
        min)
            echo "${numbers}" | sort -n | head -1
            ;;
        first)
            echo "${numbers}" | head -1
            ;;
        last)
            echo "${numbers}" | tail -1
            ;;
        avg)
            echo "${numbers}" | awk '{s+=$1; c++} END {print (c>0 ? int(s/c) : 0)}'
            ;;
        *)
            echo "${numbers}" | awk '{s+=$1} END {print s+0}'
            ;;
    esac
}

# report_has_pattern - Check if file contains pattern
# Usage: if report_has_pattern "/path/to/file" "pattern"; then ...
report_has_pattern() {
    local file="$1"
    local pattern="$2"
    grep -q "${pattern}" "${file}" 2>/dev/null
}

# report_extract_value - Extract value after key from file
# Usage: value=$(report_extract_value "/path/to/file" "key:" "delimiter")
report_extract_value() {
    local file="$1"
    local key="$2"
    local delimiter="${3:-:}"

    grep "${key}" "${file}" 2>/dev/null | \
        sed "s/.*${key}[[:space:]]*${delimiter}[[:space:]]*//" | \
        head -1 | \
        tr -d '[:space:]'
}

# report_parse_delimited - Parse delimited file into array
# Usage: mapfile -t rows < <(report_parse_delimited "/path/to/file" "|" 2)
# Returns: Column N from each line
report_parse_delimited() {
    local file="$1"
    local delimiter="${2:-|}"
    local column="${3:-1}"

    cut -d"${delimiter}" -f"${column}" "${file}" 2>/dev/null | grep -v '^$'
}

# report_file_summary - Generate summary statistics for file
# Usage: report_file_summary "/path/to/file"
# Outputs: line count, word count, pattern counts
report_file_summary() {
    local file="$1"

    if [[ ! -f "${file}" ]]; then
        echo "File not found: ${file}"
        return 1
    fi

    local lines words chars
    lines=$(wc -l < "${file}")
    words=$(wc -w < "${file}")
    chars=$(wc -c < "${file}")

    echo "File: ${file}"
    echo "  Lines: ${lines}"
    echo "  Words: ${words}"
    echo "  Size:  ${chars} bytes"
}

#===============================================================================
# SECTION 5: Analysis & Utilities - Data Pump Log Analysis
#===============================================================================

# report_dp_count_rows - Count total imported rows from Data Pump log
# Usage: rows=$(report_dp_count_rows "/path/to/log")
report_dp_count_rows() {
    local log_file="$1"
    report_extract_numbers "${log_file}" '\d+(?= rows)' "sum"
}

# Alias for backward compatibility
report_count_imported_rows() { report_dp_count_rows "$@"; }

# report_dp_extract_duration - Extract job duration in seconds
# Usage: secs=$(report_dp_extract_duration "/path/to/log")
report_dp_extract_duration() {
    local log_file="$1"
    grep "elapsed" "${log_file}" 2>/dev/null | \
        grep -oP 'elapsed 0 \K[\d:]+' | \
        awk -F: '{print ($1 * 3600) + ($2 * 60) + $3}' | \
        tail -1
}

# Alias for backward compatibility
report_extract_duration() { report_dp_extract_duration "$@"; }

# report_dp_has_errors - Check if log has ORA- errors
# Usage: if report_dp_has_errors "/path/to/log"; then ...
report_dp_has_errors() {
    report_has_pattern "$1" "ORA-"
}

# Alias for backward compatibility
report_has_errors() { report_dp_has_errors "$@"; }

# report_dp_get_status - Get status from Data Pump log
# Usage: status=$(report_dp_get_status "/path/to/log")
report_dp_get_status() {
    local log_file="$1"
    if report_has_pattern "${log_file}" "completed.*error"; then
        echo "WITH_ERRORS"
    elif report_has_pattern "${log_file}" "successfully completed"; then
        echo "SUCCESS"
    else
        echo "UNKNOWN"
    fi
}

# report_dp_count_tables - Count tables processed in Data Pump log
# Usage: count=$(report_dp_count_tables "/path/to/log")
report_dp_count_tables() {
    local log_file="$1"
    report_count_pattern "${log_file}" 'Table "'
}

# report_dp_count_objects - Count objects processed by type
# Usage: count=$(report_dp_count_objects "/path/to/log" "INDEX")
report_dp_count_objects() {
    local log_file="$1"
    local obj_type="${2:-TABLE}"
    report_count_pattern "${log_file}" "Processing object type.*${obj_type}"
}

# report_dp_get_throughput - Calculate throughput in MB/s
# Usage: mbps=$(report_dp_get_throughput "/path/to/log")
report_dp_get_throughput() {
    local log_file="$1"

    local bytes_match
    bytes_match=$(grep -oP '\d+(?= bytes)' "${log_file}" 2>/dev/null | tail -1)

    local duration
    duration=$(report_dp_extract_duration "${log_file}")

    if [[ -n "${bytes_match}" ]] && [[ -n "${duration}" ]] && [[ "${duration}" -gt 0 ]]; then
        local mb=$((bytes_match / 1024 / 1024))
        echo "scale=2; ${mb} / ${duration}" | bc 2>/dev/null || echo "0"
    else
        echo "0"
    fi
}

#===============================================================================
# SECTION 5: Analysis & Utilities - SQL Output Analysis
#===============================================================================

# report_sql_count_sections - Count sections in discovery map format
# Usage: count=$(report_sql_count_sections "/path/to/file")
report_sql_count_sections() {
    local file="$1"
    grep -c '^--.*--$' "${file}" 2>/dev/null || echo 0
}

# report_sql_get_section_names - Get section names from discovery map
# Usage: mapfile -t sections < <(report_sql_get_section_names "/path/to/file")
report_sql_get_section_names() {
    local file="$1"
    grep -oP '(?<=^--)[A-Z_]+(?=--$)' "${file}" 2>/dev/null
}

# report_sql_section_count - Count entries in specific section
# Usage: count=$(report_sql_section_count "/path/to/file" "DATAFILES")
report_sql_section_count() {
    local file="$1"
    local section="$2"

    awk -v sect="${section}" '
        /^--'"${section}"'--/ { found=1; next }
        /^--/ { found=0 }
        found && /\|/ { count++ }
        END { print count+0 }
    ' "${file}" 2>/dev/null
}

# report_sql_validate_discovery - Validate discovery map file
# Usage: if report_sql_validate_discovery "/path/to/file"; then ...
report_sql_validate_discovery() {
    local file="$1"

    [[ ! -f "${file}" ]] && return 1

    local datafiles
    datafiles=$(report_sql_section_count "${file}" "DATAFILES")

    # Must have at least 1 datafile
    [[ "${datafiles}" -ge 1 ]]
}

# report_sql_summary - Generate summary for SQL output file
# Usage: report_sql_summary "/path/to/file"
report_sql_summary() {
    local file="$1"

    if [[ ! -f "${file}" ]]; then
        echo "File not found: ${file}"
        return 1
    fi

    local sections
    sections=$(report_sql_count_sections "${file}")

    echo "SQL Output Summary: ${file}"
    echo "  Sections: ${sections}"

    if [[ "${sections}" -gt 0 ]]; then
        local section_name
        while IFS= read -r section_name; do
            local count
            count=$(report_sql_section_count "${file}" "${section_name}")
            echo "  ${section_name}: ${count} entries"
        done < <(report_sql_get_section_names "${file}")
    fi

    local total_lines
    total_lines=$(wc -l < "${file}")
    echo "  Total lines: ${total_lines}"
}

#===============================================================================
# SECTION 6: Graceful Integration Wrappers (Optional Module Integration)
#===============================================================================

# report_track_phase - Phase tracking (graceful if report not initialized)
# Usage: report_track_phase "Phase Name"
report_track_phase() {
    [[ ${_R_INITIALIZED:-0} -eq 1 ]] && report_phase "$@" || true
}

# report_track_section - Section tracking (graceful)
# Usage: report_track_section "Section Title"
report_track_section() {
    [[ ${_R_INITIALIZED:-0} -eq 1 ]] && report_section "$@" || true
}

# report_track_step - Step tracking (graceful)
# Usage: report_track_step "Step Description"
report_track_step() {
    [[ ${_R_INITIALIZED:-0} -eq 1 ]] && report_step "$@" || true
}

# report_track_step_done - Mark step done (graceful)
# Usage: report_track_step_done $exit_code ["detail"]
report_track_step_done() {
    [[ ${_R_INITIALIZED:-0} -eq 1 ]] && report_step_done "$@" || true
}

# report_track_item - Track item (graceful)
# Usage: report_track_item "status" "name" ["detail"]
report_track_item() {
    [[ ${_R_INITIALIZED:-0} -eq 1 ]] && report_item "$@" || true
}

# report_track_metric - Track metric (graceful)
# Usage: report_track_metric "key" "value" ["operation"]
report_track_metric() {
    [[ ${_R_INITIALIZED:-0} -eq 1 ]] && report_metric "$@" || true
}

# report_track_meta - Track metadata (graceful)
# Usage: report_track_meta "key" "value"
report_track_meta() {
    [[ ${_R_INITIALIZED:-0} -eq 1 ]] && report_meta "$@" || true
}

#===============================================================================
# SECTION 7: Query and Aggregation Functions
#===============================================================================

# report_metric_aggregate - Aggregate metrics by pattern with operation
# Usage: total=$(report_metric_aggregate "dp_*" "sum")
# Operations: sum, avg, max, min, count
report_metric_aggregate() {
    [[ ${_R_INITIALIZED:-0} -ne 1 ]] && return 1

    local pattern="$1"
    local operation="${2:-sum}"

    local result=0 count=0 sum=0
    for key in "${!_R_METRICS[@]}"; do
        # Pattern matching using bash globbing
        [[ "${key}" == ${pattern} ]] || continue

        local value="${_R_METRICS[${key}]}"
        sum=$((sum + value))
        (( count++ )) || true

        case "${operation}" in
            max) [[ ${value} -gt ${result} ]] && result=${value} ;;
            min) [[ ${count} -eq 1 || ${value} -lt ${result} ]] && result=${value} ;;
        esac
    done

    case "${operation}" in
        sum)   result="${sum}" ;;
        avg)   [[ ${count} -gt 0 ]] && result=$((sum / count)) || result=0 ;;
        min|max) ;;  # Already computed above
        count) result="${count}" ;;
        *)     return 1 ;;
    esac

    echo "${result}"
}

# report_query_timeline - Generate chronological timeline of all operations
# Usage: report_query_timeline
report_query_timeline() {
    [[ ${_R_INITIALIZED:-0} -ne 1 ]] && return 1

    local events=()

    # Collect step events with timestamps
    for step_data in "${_R_STEPS[@]}"; do
        IFS='|' read -r phase_idx step_name status start_time end_time detail <<< "${step_data}"
        [[ -z "${start_time}" || ${start_time} -lt 1000000000 ]] && continue

        events+=("${start_time}|STEP_START|${step_name}")
        [[ ${end_time} -gt ${start_time} ]] && events+=("${end_time}|STEP_END|${step_name}|${status}")
    done

    # Sort events by timestamp
    printf '%s\n' "${events[@]}" | sort -t'|' -k1,1n | while IFS='|' read -r ts type name status; do
        local formatted_time
        formatted_time=$(date -d "@${ts}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "$(date -f - 2>/dev/null <<< @${ts})")
        printf '[%s] %s: %s' "${formatted_time}" "${type}" "${name}"
        [[ -n "${status}" ]] && printf " (%s)\n" "${status}" || printf "\n"
    done
}

# report_query_critical_path - Identify slowest operations
# Usage: report_query_critical_path [limit]
report_query_critical_path() {
    [[ ${_R_INITIALIZED:-0} -ne 1 ]] && return 1

    local limit="${1:-10}"
    local slowest=()

    # Calculate duration for each step
    for step_data in "${_R_STEPS[@]}"; do
        IFS='|' read -r phase_idx step_name status start_time end_time detail <<< "${step_data}"
        [[ ${end_time} -gt ${start_time} ]] || continue

        local duration=$((end_time - start_time))
        slowest+=("${duration}|${step_name}|${status}")
    done

    # Sort by duration descending and show top N
    printf '%s\n' "${slowest[@]}" | sort -t'|' -k1,1rn | head -n "${limit}" | while IFS='|' read -r dur name stat; do
        local formatted_dur
        if [[ ${dur} -ge 3600 ]]; then
            formatted_dur="$((dur / 3600))h $((dur % 3600 / 60))m"
        elif [[ ${dur} -ge 60 ]]; then
            formatted_dur="$((dur / 60))m $((dur % 60))s"
        else
            formatted_dur="${dur}s"
        fi
        printf '%-10s %s (%s)\n' "${formatted_dur}" "${name}" "${stat}"
    done
}

# report_query_metric_summary - Get summary of all metrics
# Usage: report_query_metric_summary
report_query_metric_summary() {
    [[ ${_R_INITIALIZED:-0} -ne 1 ]] && return 1

    echo "=== Metric Summary ==="
    for key in $(printf '%s\n' "${!_R_METRICS[@]}" | sort); do
        local value="${_R_METRICS[${key}]}"
        printf '%-40s %10s\n' "${key}" "${value}"
    done
}
