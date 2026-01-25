# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

DCX Oracle Plugin - Oracle automation scripts for RMAN restore/clone and Data Pump migrations. This is a plugin for DCX (dc-scripts) that extends the `dcx` command with Oracle-specific operations.

## Key Commands

```bash
# Run all tests
cd tests && ./run_all_tests.sh

# Quick syntax validation only
cd tests && ./run_all_tests.sh --quick

# Run individual test suites
./tests/test_oracle_core.sh
./tests/test_oracle_rman.sh

# Syntax check a library
bash -n lib/oracle_sql.sh

# Test library loading
bash -c 'source lib/oracle.sh && type -t oracle_sql_sysdba_exec'

# Install plugin to DCX
make install

# Test plugin commands
dcx oracle validate
dcx oracle restore --help
```

## Architecture

### Plugin Structure

```
dcx-oracle/
├── plugin.yaml      # Plugin metadata
├── init.sh          # Plugin initialization (loads libs)
├── lib/             # Bash modules (oracle_*.sh)
├── commands/        # CLI commands (dcx oracle <cmd>)
├── etc/             # Configuration
└── tests/           # Test suite
```

### DCX Integration

This plugin extends DCX with `dcx oracle <command>`:

```bash
dcx oracle restore   # RMAN restore/clone
dcx oracle migrate   # Data Pump migration
dcx oracle validate  # Validate Oracle environment
dcx oracle keyring   # Credential management
dcx oracle sql       # Execute SQL
dcx oracle rman      # Execute RMAN commands
```

### Module Hierarchy

| Module | Purpose | Prefix |
|--------|---------|--------|
| oracle_core.sh | ORACLE_HOME validation, binary discovery | `oracle_core_*` |
| oracle_sql.sh | SQL execution via sqlplus | `oracle_sql_*` |
| oracle_config.sh | PFILE, memory sizing, paths | `oracle_config_*` |
| oracle_cluster.sh | RAC detection, srvctl | `oracle_cluster_*` |
| oracle_instance.sh | Instance lifecycle (start/stop) | `oracle_instance_*` |
| oracle_rman.sh | RMAN operations | `oracle_rman_*` |
| oracle_datapump.sh | Data Pump operations | `dp_*` |
| oracle_oci.sh | OCI Object Storage | `oci_*` |
| oracle.sh | Unified loader for all oracle_* | - |

### DCX Infrastructure (Inherited)

The plugin inherits from DCX:
- `log_info`, `log_error`, etc. (structured logging)
- `gum` (terminal UI toolkit)
- `yq` (YAML processing)
- `need_cmd`, `assert_file`, etc. (runtime utilities)

## Configuration Variables

```bash
# Oracle Environment
ORACLE_HOME          # Required: Oracle installation directory
ORACLE_SID           # Target database SID
ORACLE_BASE          # Oracle base directory
TNS_ADMIN            # TNS configuration directory

# Restore Settings
BACKUP_ROOT          # Backup location (default: /backup-prod/rman)
DEST_BASE            # Destination base path (default: /restore)
DEST_TYPE            # FS or ASM (default: FS)
SGA_TARGET           # SGA memory override
PGA_TARGET           # PGA memory override

# Execution Control
DRY_RUN              # 0=full, 1=validate+state, 2=config only
AUTO_YES             # Skip confirmations
LOG_LEVEL            # 0=quiet, 1=normal, 2=verbose, 3=debug
```

## Code Conventions

- Function naming: `module_verb_noun()` (e.g., `oracle_sql_execute_batch`)
- Guard variables: `__MODULE_LOADED` for double-source protection
- Private variables: `_MODULE_VAR` prefix
- All modules auto-load dependencies via oracle.sh loader
