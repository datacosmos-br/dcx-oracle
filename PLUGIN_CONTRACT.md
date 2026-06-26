# DCX-Oracle Plugin Contract Specification v1.0

**Status**: Approved & Enforced
**Date**: February 2, 2026
**Issue**: dcx-9ie

## Executive Summary

The dcx-oracle plugin defines a strict contract that ensures reliable, deterministic behavior when invoked from the DCX framework or standalone. This document specifies:

1. **Configuration Precedence Chain** - Immutable ordering for config resolution
2. **I/O Discipline Rules** - Strict stdout/stderr handling for reliable automation
3. **Preflight Validation** - Fail-fast checks before any destructive operations
4. **No-Fallback Policy** - Explicit decisions over silent degradation

---

## 1. Configuration Precedence (Immutable Order)

When resolving a configuration value, the plugin **MUST** check sources in this exact order and stop at the first match:

```
1. Environment Variables (highest priority)
   └─ ORACLE_*, DB_*, SOURCE_*, NETWORK_*, OCI_*, TNS_* prefixes
   └─ Example: ORACLE_PASSWORD, DB_HOST, OCI_REGION

2. DCX Runtime Context
   └─ Provided by DC_* environment variables from caller
   └─ Example: DC_WORKSPACE_HOME, DC_PLUGIN_CONFIG

3. Plugin Configuration File
   └─ Location: ${PLUGIN_DIR}/config/local.conf
   └─ Format: key=value with validation

4. Global Configuration File
   └─ Location: ~/.dcx/config or /etc/dcx/config
   └─ Format: key=value

5. Default Configuration
   └─ Location: ${PLUGIN_DIR}/config/defaults.conf
   └─ Contains safe, documented defaults
   └─ Lowest priority (fallback only)

6. MUST NOT PROMPT USER
   └─ Never prompt for missing values
   └─ Fail with clear error message instead
```

### Implementation

**File**: `dcx-oracle/lib/config_precedence.sh`

```bash
# config_resolve - Get value respecting precedence chain
# Usage: config_resolve ORACLE_PASSWORD
config_resolve() {
    local varname="$1"
    local allowed_prefixes="ORACLE DB SOURCE NETWORK OCI TNS"

    # Validate prefix
    local prefix="${varname%%_*}"
    [[ " $allowed_prefixes " =~ " $prefix " ]] || \
        die "Invalid config variable: $varname (prefix not in allowlist)"

    # Check in order: env -> dcx context -> plugin config -> global config -> defaults
    if [[ -n "${!varname:-}" ]]; then
        echo "${!varname}"
        CONFIG_SOURCE_$varname="env"
        return 0
    fi

    # ... (check other sources in order)

    die "Config not found: $varname (no value in precedence chain)"
}

# config_load_with_precedence - Load all config respecting chain
config_load_with_precedence() {
    # Load defaults first (lowest priority)
    config_load "${PLUGIN_DIR}/config/defaults.conf"

    # Load global config (override defaults)
    [[ -f ~/.dcx/config ]] && config_load ~/.dcx/config

    # Load plugin config (override global)
    [[ -f "${PLUGIN_DIR}/config/local.conf" ]] && \
        config_load "${PLUGIN_DIR}/config/local.conf"

    # Environment variables already loaded (highest priority, checked at access time)

    # Log configuration sources for debugging
    log_debug "Configuration loaded with precedence: env > dcx > plugin > global > defaults"
}
```

---

## 2. I/O Discipline Rules

The plugin **MUST** follow strict I/O discipline to ensure reliable command automation:

### 2.1 STDOUT - Machine-Readable Output Only

**Rule**: STDOUT is reserved for machine-readable output (JSON, CSV, or structured text).

- ✅ **ALLOWED**:
  - Structured results: `{"status": "ok", "rows": 1000}`
  - CSV output: `"id","name","value"`
  - Return values: `success`
  - Single values: `100` (for piping)

- ❌ **FORBIDDEN**:
  - Progress messages: "Processing table X..."
  - Status updates: "Starting import..."
  - Warnings or hints
  - Debug information
  - Formatted tables or banners

### 2.2 STDERR - Diagnostic Output Only

**Rule**: All human-readable, diagnostic, and status messages go to STDERR.

- ✅ **ALLOWED**:
  - Progress: `[INFO] Starting migration...`
  - Errors: `[ERROR] Connection failed: ...`
  - Warnings: `[WARN] Table has no primary key`
  - Debug: `[DEBUG] SQL executed: SELECT ...`
  - Confirmations: `Ready to proceed? [y/N]`

- ❌ **FORBIDDEN**:
  - Machine-readable output (use STDOUT)
  - Values meant to be captured by callers

### 2.3 Logging Functions (STDERR-based)

```bash
# All logging goes to STDERR with timestamps and levels
log_info()   # General information
log_warn()   # Non-fatal warnings
log_error()  # Errors (but process continues)
log_debug()  # Debug info (controlled by LOG_LEVEL)
die()        # Fatal error + exit (no recovery)
```

### 2.4 Output Implementation

**File**: `dcx-oracle/lib/logging.sh` (already implements this)

Verify:
```bash
# Bad (mixing purposes)
dp_export() {
    echo "Starting export..."     # ❌ WRONG: progress on stdout
    sql_exec "CREATE TABLE ..."   # ✓ OK: runs silently, logs to stderr
    echo "Export complete: $rows" # ❌ WRONG: result message on stdout
}

# Good (proper discipline)
dp_export() {
    log_info "Starting export..."           # ✓ Goes to STDERR
    sql_exec "CREATE TABLE ..." || die "..."# ✓ Logs errors to STDERR
    echo "$rows"                            # ✓ Only result to STDOUT
}
```

---

## 3. Preflight Validation

The plugin **MUST** perform preflight checks before ANY destructive operation (migrations, data changes, exports).

### 3.1 Preflight Checks

**File**: `dcx-oracle/lib/oracle_preflight.sh`

```bash
# oracle_preflight_check - Run all preflight validations
# Returns: 0 on success, 1 on failure (script exits)
oracle_preflight_check() {
    log_info "Running preflight checks..."

    # 1. Configuration Completeness
    oracle_preflight_config

    # 2. Source Database Connectivity
    oracle_preflight_source_db

    # 3. Target Database Connectivity
    oracle_preflight_target_db

    # 4. Storage/Permissions
    oracle_preflight_storage

    # 5. Required Tools/Utilities
    oracle_preflight_tools

    # 6. Data Safety Checks
    oracle_preflight_data_safety

    log_info "✓ All preflight checks passed"
}

# Individual check functions
oracle_preflight_config() {
    log_debug "Checking configuration..."
    [[ -n "${SOURCE_DB_HOST:-}" ]] || die "SOURCE_DB_HOST not configured"
    [[ -n "${TARGET_DB_HOST:-}" ]] || die "TARGET_DB_HOST not configured"
    [[ -n "${ORACLE_SID:-}" ]] || die "ORACLE_SID not set"
}

oracle_preflight_source_db() {
    log_debug "Testing source database connectivity..."
    sql_exec "SELECT 1 FROM dual" || \
        die "Cannot connect to source database"
}

oracle_preflight_target_db() {
    log_debug "Testing target database connectivity..."
    sql_exec --target "SELECT 1 FROM dual" || \
        die "Cannot connect to target database"
}

oracle_preflight_storage() {
    log_debug "Checking storage and permissions..."
    local export_dir="${EXPORT_DIR}"
    [[ -d "$export_dir" ]] || mkdir -p "$export_dir" || \
        die "Cannot access/create export directory: $export_dir"
    [[ -w "$export_dir" ]] || \
        die "No write permission to export directory: $export_dir"
}

oracle_preflight_tools() {
    log_debug "Checking required tools..."
    command -v expdp &>/dev/null || die "expdp not found in PATH"
    command -v impdp &>/dev/null || die "impdp not found in PATH"
    command -v sqlplus &>/dev/null || die "sqlplus not found in PATH"
}

oracle_preflight_data_safety() {
    log_debug "Checking data safety constraints..."
    # Ensure source and target are not the same
    [[ "${SOURCE_DB_UNIQUE_NAME}" != "${TARGET_DB_UNIQUE_NAME}" ]] || \
        die "Source and target databases are the same (safety check failed)"
    # Ensure no running migrations
    # ... (check locks, active jobs, etc.)
}
```

### 3.2 Preflight Timing

Preflight checks **MUST** run:
- ✅ At plugin initialization (before main logic)
- ✅ Before any destructive operation (export, import, schema change)
- ✅ When `--preflight-only` flag is used (new)

Preflight checks **MUST NOT**:
- ❌ Be optional or skipped by default
- ❌ Fail silently
- ❌ Continue if any check fails

---

## 4. No-Fallback Policy

The plugin **MUST** make explicit decisions and never silently degrade.

### 4.1 Policy Statement

> **"Fail loudly with clear error messages rather than silently falling back to suboptimal behavior."**

### 4.2 Examples

#### Bad (Hidden Fallback)
```bash
# If wallet not available, silently use plaintext password
get_password() {
    wallet_read_password || echo "$ORACLE_PASSWORD"  # ❌ WRONG
}
```

#### Good (Explicit Choice)
```bash
# Clearly document what we check and fail if all fail
get_password() {
    if [[ -f ~/.oracle/wallet/cwallet.sso ]]; then
        wallet_read_password || die "Wallet corrupted"
    elif [[ -n "${ORACLE_PASSWORD:-}" ]]; then
        echo "$ORACLE_PASSWORD"
    else
        die "No password available (wallet missing AND ORACLE_PASSWORD not set)"
    fi
}
```

### 4.3 Network Link Decision (dcx-9ie Decision Point)

**DECISION**: Use network_link as primary, dumpfiles as fallback WITH explicit warning.

```bash
# dcx-oracle/commands/migrate.sh
dp_strategy() {
    if [[ "${USE_DUMPFILES:-0}" == "1" ]]; then
        # Explicit choice by user
        MIGRATION_STRATEGY="dumpfiles"
        log_info "Using OCI dumpfiles strategy (explicit choice)"
    elif network_link_available; then
        # Preferred strategy (faster, simpler)
        MIGRATION_STRATEGY="network_link"
        log_info "Using network_link strategy (preferred)"
    else
        # Fallback WITH explicit warning
        log_warn "Network link not available - falling back to dumpfiles"
        log_warn "This is SLOWER. Fix network_link if possible."
        MIGRATION_STRATEGY="dumpfiles"
    fi
}
```

**Rule**: All fallbacks MUST log warnings with reason and impact.

---

## 5. Enforcement Mechanisms

### 5.1 Static Checks (Pre-execution)

**File**: `dcx-oracle/lib/oracle_contract_enforce.sh`

```bash
# Verify contract compliance before execution
oracle_enforce_contract() {
    log_info "Enforcing plugin contract..."

    # 1. Check stdout/stderr discipline
    oracle_check_io_discipline

    # 2. Verify configuration precedence implementation
    oracle_check_config_precedence

    # 3. Validate preflight checks exist
    oracle_check_preflight_exists

    # 4. Check no-fallback policy
    oracle_check_no_fallback_policy

    log_info "✓ Plugin contract verified"
}
```

### 5.2 Runtime Checks (Execution)

Enabled with `--contract-check` flag:

```bash
# Trace all config lookups
CONFIG_TRACE=1 migrate.sh ...

# Trace all fallbacks
FALLBACK_TRACE=1 migrate.sh ...

# Verify stdout/stderr separation
migrate.sh ... 2>/tmp/stderr.log 1>/tmp/stdout.log
# Check: stdout should be machine-readable, stderr should be logs
```

### 5.3 Tests

**File**: `dcx-oracle/tests/test_contract.sh`

```bash
test_contract_config_precedence() {
    export ORACLE_PASSWORD="env_value"
    # Should use env over file
}

test_contract_io_discipline() {
    # Capture stdout and stderr separately
    # Verify stdout is only structured output
    # Verify stderr contains all logs
}

test_contract_preflight() {
    # Verify preflight runs before main operation
    # Verify failure in preflight stops execution
}

test_contract_no_fallback() {
    # Verify all fallback paths log warnings
}
```

---

## 6. Migration Roadmap

### Phase 1: Documentation (dcx-9ie)
- ✅ Write this contract specification
- ✅ Document all rules with examples
- ✅ Define enforcement mechanisms

### Phase 2: Implementation
- 🔄 Create `oracle_preflight.sh` with all checks
- 🔄 Create `oracle_contract_enforce.sh` for verification
- 🔄 Update `migrate.sh` to call preflight checks
- 🔄 Audit all functions for I/O discipline

### Phase 3: Testing
- 🔄 Create comprehensive test suite (`test_contract.sh`)
- 🔄 Add integration tests
- 🔄 Document test procedures

### Phase 4: Enforcement
- 🔄 Enable contract checking in CI/CD
- 🔄 Add `--contract-check` flag to migrate.sh
- 🔄 Document in user guide

---

## 7. Questions & Decisions

### Q1: Should preflight be optional?
**A**: No. Preflight checks MUST always run before destructive operations. Use `--skip-preflight` only with explicit `--force-unsafe` flag.

### Q2: How strict is stdout/stderr discipline?
**A**: Strictly enforced. Use `log_*` functions for all diagnostic output. STDOUT must be machine-readable only.

### Q3: Can we cache configuration?
**A**: No. Every access must check the precedence chain to respect runtime changes and environment variables.

### Q4: What about backward compatibility?
**A**: The contract is NEW and doesn't break existing functionality. Existing code can be updated incrementally.

---

## 8. Approval & Sign-off

- **Issue**: dcx-9ie
- **Approved by**: Datacosmos Architecture
- **Implementation Owner**: TBD
- **Enforcement Date**: Phase 1 complete (this document)
- **Final Review**: After Phase 3 (testing)

---

## 9. Appendix: Contract Checklist

Use this checklist during implementation and testing:

```bash
CONFIGURATION PRECEDENCE:
[ ] Env vars checked before all other sources
[ ] Plugin config overrides global defaults
[ ] Global config overrides plugin defaults
[ ] No prompting for missing values
[ ] All config access uses precedence chain

I/O DISCIPLINE:
[ ] STDOUT: machine-readable only (JSON/CSV/values)
[ ] STDERR: all log messages, progress, confirmations
[ ] All log calls use log_info/warn/error/debug
[ ] No progress messages to STDOUT
[ ] test_contract.sh verifies separation

PREFLIGHT VALIDATION:
[ ] Preflight checks run at startup
[ ] All required preflight checks present
[ ] Fail-fast on preflight failure
[ ] Clear error messages for each failure
[ ] --preflight-only flag supported

NO-FALLBACK POLICY:
[ ] All fallbacks logged with reason
[ ] Config gaps fail with clear message
[ ] No silent degradation
[ ] User-overridable explicit decisions
```

---

**End of Contract Specification**
