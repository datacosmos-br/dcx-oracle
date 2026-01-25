# DCX Oracle Plugin

Oracle automation plugin for [DCX](https://github.com/datacosmos-br/dc-scripts) - RMAN restore/clone, Data Pump migrations, SQL execution, and more.

## Features

- **RMAN Restore/Clone**: Automated restore from disk backups with PITR support
- **Data Pump Migration**: Network link or OCI dumpfile-based migrations
- **Instance Management**: Start, stop, status with RAC/srvctl support
- **SQL Execution**: Interactive and batch SQL execution
- **Credential Management**: Secure credential storage via system keyring
- **State Tracking**: Resumable operations with DRY_RUN workflow

## Installation

### Via DCX Plugin Manager

```bash
dcx plugin install oracle
```

### Manual Installation

```bash
curl -fsSL https://raw.githubusercontent.com/datacosmos-br/dcx-oracle/main/install.sh | bash
```

### From Source

```bash
git clone https://github.com/datacosmos-br/dcx-oracle.git
cd dcx-oracle
make install
```

## Usage

```bash
# Validate Oracle environment
dcx oracle validate

# RMAN restore
dcx oracle restore --sid PROD --backup-root /backup --dest-base /restore

# Data Pump migration
dcx oracle migrate --source PROD --target DEV --schemas HR,SCOTT

# Execute SQL
dcx oracle sql "SELECT * FROM v\$instance"

# Execute RMAN
dcx oracle rman "LIST BACKUP SUMMARY"

# Credential management
dcx oracle keyring set PROD_PASSWORD
dcx oracle keyring get PROD_PASSWORD
```

## Commands

| Command | Description |
|---------|-------------|
| `dcx oracle restore` | RMAN restore/clone from backup |
| `dcx oracle migrate` | Data Pump migration |
| `dcx oracle validate` | Validate Oracle environment |
| `dcx oracle keyring` | Credential management |
| `dcx oracle sql` | Execute SQL statements |
| `dcx oracle rman` | Execute RMAN commands |

## Requirements

- **DCX** >= 0.0.1
- **Oracle Client** or **Oracle Home** with sqlplus, rman, impdp, expdp
- **Bash** >= 4.0

## Configuration

Environment variables:

```bash
export ORACLE_HOME=/u01/app/oracle/product/19c/dbhome_1
export ORACLE_SID=PROD
export BACKUP_ROOT=/backup-prod/rman
export DEST_BASE=/restore
```

## Documentation

- [State Tracking](docs/STATE_TRACKING.md) - DRY_RUN workflow and resumable operations
- [Architecture](docs/ARCHITECTURE.md) - Module system and dependencies

## License

MIT License - see [LICENSE](LICENSE) for details.

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Run tests: `make test`
5. Submit a pull request

## Related

- [DCX (dc-scripts)](https://github.com/datacosmos-br/dc-scripts) - Parent project
