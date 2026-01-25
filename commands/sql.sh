#!/usr/bin/env bash
#===============================================================================
# dcx oracle sql - Execute SQL Statements
#===============================================================================
# Usage:
#   dcx oracle sql "SELECT * FROM v\$instance"
#   dcx oracle sql -f script.sql
#   dcx oracle sql --sysdba "SELECT * FROM v\$database"
#
# Options:
#   -f, --file FILE     Execute SQL from file
#   --sysdba            Connect as SYSDBA
#   --sysbackup         Connect as SYSBACKUP
#   --connection STR    Connection string (user/pass@tns)
#   --sid SID           Set ORACLE_SID
#   --timeout SEC       Query timeout in seconds
#   --help              Show this help message
#===============================================================================

set -eo pipefail

#===============================================================================
# LIBRARY LOADING
#===============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="${SCRIPT_DIR}/.."
PLUGIN_LIB="${PLUGIN_DIR}/lib"

# Load DCX infrastructure or fallbacks
if [[ -z "${DC_LIB_DIR:-}" ]]; then
    log_info() { echo "[INFO] $*"; }
    log_error() { echo "[ERROR] $*" >&2; }
    die() { echo "[FATAL] $*" >&2; exit 1; }
fi

# Load Oracle libraries
source "${PLUGIN_LIB}/oracle.sh"

#===============================================================================
# ARGUMENT PARSING
#===============================================================================

SQL_FILE=""
SQL_STMT=""
CONNECT_AS=""
CONNECTION=""
SID_OVERRIDE=""
TIMEOUT=""

show_help() {
    cat << 'EOF'
dcx oracle sql - Execute SQL Statements

Usage:
  dcx oracle sql "SELECT * FROM v\$instance"
  dcx oracle sql -f script.sql
  dcx oracle sql --sysdba "SELECT * FROM v\$database"

Options:
  -f, --file FILE     Execute SQL from file
  --sysdba            Connect as SYSDBA
  --sysbackup         Connect as SYSBACKUP
  --connection STR    Connection string (user/pass@tns)
  --sid SID           Set ORACLE_SID
  --timeout SEC       Query timeout in seconds
  --help              Show this help message

Examples:
  dcx oracle sql "SELECT instance_name, status FROM v\$instance"
  dcx oracle sql --sysdba "ALTER SYSTEM SWITCH LOGFILE"
  dcx oracle sql -f /tmp/query.sql --connection "scott/tiger@ORCL"
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -f|--file)
            SQL_FILE="$2"
            shift 2
            ;;
        --sysdba)
            CONNECT_AS="SYSDBA"
            shift
            ;;
        --sysbackup)
            CONNECT_AS="SYSBACKUP"
            shift
            ;;
        --connection)
            CONNECTION="$2"
            shift 2
            ;;
        --sid)
            SID_OVERRIDE="$2"
            shift 2
            ;;
        --timeout)
            TIMEOUT="$2"
            shift 2
            ;;
        --help|-h)
            show_help
            ;;
        -*)
            log_error "Unknown option: $1"
            exit 1
            ;;
        *)
            SQL_STMT="$1"
            shift
            ;;
    esac
done

#===============================================================================
# VALIDATION
#===============================================================================

if [[ -z "$SQL_FILE" && -z "$SQL_STMT" ]]; then
    log_error "No SQL statement or file provided"
    echo "Usage: dcx oracle sql \"SQL statement\" or dcx oracle sql -f file.sql"
    exit 1
fi

if [[ -n "$SQL_FILE" && ! -f "$SQL_FILE" ]]; then
    die "SQL file not found: $SQL_FILE"
fi

if [[ -z "${ORACLE_HOME:-}" ]]; then
    die "ORACLE_HOME is not set"
fi

# Override SID if specified
if [[ -n "$SID_OVERRIDE" ]]; then
    export ORACLE_SID="$SID_OVERRIDE"
fi

#===============================================================================
# EXECUTION
#===============================================================================

# Build sqlplus command
SQLPLUS="${ORACLE_HOME}/bin/sqlplus"
if [[ ! -x "$SQLPLUS" ]]; then
    die "sqlplus not found: $SQLPLUS"
fi

# Build connection string
if [[ -n "$CONNECTION" ]]; then
    CONN_STR="$CONNECTION"
elif [[ -n "$CONNECT_AS" ]]; then
    CONN_STR="/ as $CONNECT_AS"
else
    CONN_STR="/ as sysdba"  # Default to SYSDBA
fi

# Execute SQL
if [[ -n "$SQL_FILE" ]]; then
    # Execute from file
    "$SQLPLUS" -S "$CONN_STR" @"$SQL_FILE"
else
    # Execute inline SQL
    echo "SET HEADING ON
SET LINESIZE 200
SET PAGESIZE 100
SET FEEDBACK ON
$SQL_STMT
EXIT" | "$SQLPLUS" -S "$CONN_STR"
fi
