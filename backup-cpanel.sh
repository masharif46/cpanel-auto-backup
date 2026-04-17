#!/usr/bin/env bash
#
# cPanel Auto Backup
# ==================
# Automated, rotated, optionally off-site backups of every cPanel account,
# database, and system configuration file. Designed to be run from cron on
# a live cPanel server.
#
# Repository : https://github.com/masharif46/cpanel-auto-backup
# Author     : masharif46 <https://github.com/masharif46>
# License    : MIT
# Version    : 1.0.0
#
# Usage:
#   sudo ./backup-cpanel.sh                           # full run, default config
#   sudo ./backup-cpanel.sh --dry-run                 # show what would happen
#   sudo ./backup-cpanel.sh --accounts-only           # accounts only
#   sudo ./backup-cpanel.sh --config /path/backup.conf
#   sudo ./backup-cpanel.sh --no-upload               # skip remote upload
#
# ==============================================================================
set -Eeuo pipefail
IFS=$'\n\t'

# ------------------------------------------------------------------------------
# Globals
# ------------------------------------------------------------------------------
SCRIPT_VERSION="1.0.0"
SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"

LOG_DIR="/var/log/cpanel-auto-backup"
LOG_FILE="${LOG_DIR}/backup-$(date +%Y%m%d-%H%M%S).log"

DEFAULT_CONFIG="/etc/cpanel-auto-backup/backup.conf"
CONFIG_FILE="${DEFAULT_CONFIG}"

# Defaults (backup.conf can override these)
BACKUP_ROOT="/backup/cpanel"
RETENTION_DAYS=7
RETENTION_WEEKLY=0
RETENTION_MONTHLY=0

# CLI flags
DRY_RUN=0
FORCE=0
MODE="all"          # all | accounts | databases | system
NO_UPLOAD=0
VERBOSE=0

START_TS=0

# ------------------------------------------------------------------------------
# Colours
# ------------------------------------------------------------------------------
if [[ -t 1 ]]; then
    C_RED=$'\033[0;31m'
    C_GREEN=$'\033[0;32m'
    C_YELLOW=$'\033[1;33m'
    C_BLUE=$'\033[0;34m'
    C_CYAN=$'\033[0;36m'
    C_BOLD=$'\033[1m'
    C_RESET=$'\033[0m'
else
    C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_CYAN="" C_BOLD="" C_RESET=""
fi

# ------------------------------------------------------------------------------
# Sourcing library modules
# ------------------------------------------------------------------------------
for lib in common accounts databases system rotation remote notify; do
    if [[ -f "${LIB_DIR}/${lib}.sh" ]]; then
        # shellcheck disable=SC1090
        source "${LIB_DIR}/${lib}.sh"
    else
        echo "ERROR: Missing required library: ${LIB_DIR}/${lib}.sh" >&2
        exit 1
    fi
done

# ------------------------------------------------------------------------------
# Usage / CLI parsing
# ------------------------------------------------------------------------------
print_usage() {
    cat <<EOF
${SCRIPT_NAME} v${SCRIPT_VERSION}

Automated cPanel account + database + system backups with rotation and
optional off-site upload (rsync / S3 / SFTP).

USAGE
    sudo ${SCRIPT_NAME} [OPTIONS]

OPTIONS
    --config FILE        Path to backup.conf (default: ${DEFAULT_CONFIG})
    --dry-run            Show what would happen, change nothing on disk
    --force              Proceed past non-critical pre-flight failures
    --accounts-only      Back up cPanel accounts only
    --databases-only     Back up databases only
    --system-only        Back up /etc, /root, /var/cpanel, packages only
    --no-upload          Skip the remote upload step
    --verbose            Enable debug-level logging
    --version            Show version and exit
    --help, -h           Show this help and exit

EXAMPLES
    # Nightly cron (default /etc/cron.d/cpanel-auto-backup):
    sudo ${SCRIPT_NAME}

    # Test everything without writing backups:
    sudo ${SCRIPT_NAME} --dry-run --verbose

    # One-off local-only accounts backup:
    sudo ${SCRIPT_NAME} --accounts-only --no-upload

See docs/USAGE.md for the full guide.
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --config)          CONFIG_FILE="$2"; shift 2 ;;
            --dry-run)         DRY_RUN=1; shift ;;
            --force)           FORCE=1; shift ;;
            --accounts-only)   MODE="accounts"; shift ;;
            --databases-only)  MODE="databases"; shift ;;
            --system-only)     MODE="system"; shift ;;
            --no-upload)       NO_UPLOAD=1; shift ;;
            --verbose|-v)      VERBOSE=1; shift ;;
            --version)         echo "${SCRIPT_NAME} ${SCRIPT_VERSION}"; exit 0 ;;
            --help|-h)         print_usage; exit 0 ;;
            *)                 echo "Unknown option: $1" >&2; print_usage; exit 64 ;;
        esac
    done
}

# ------------------------------------------------------------------------------
# Phases
# ------------------------------------------------------------------------------
phase_preflight() {
    log_phase "PHASE 1/6  Pre-flight checks"
    require_root
    load_config "${CONFIG_FILE}"

    # Timestamp the backup directory *after* config load so BACKUP_ROOT is
    # known. Format: 2026-04-17_020000.
    BACKUP_DIR="${BACKUP_ROOT}/$(date +%Y-%m-%d_%H%M%S)"
    log_info "Backup dir will be: ${BACKUP_DIR}"

    # Most modes need cPanel; system-only + databases-only can run without.
    case "${MODE}" in
        all|accounts) require_cpanel ;;
    esac

    ensure_backup_dir
    check_free_space "${BACKUP_ROOT}" 1024
}

phase_accounts() {
    [[ "${MODE}" == "databases" || "${MODE}" == "system" ]] && {
        log_debug "Skipping accounts phase (MODE=${MODE})"
        return 0
    }
    log_phase "PHASE 2/6  Backing up cPanel accounts"
    backup_accounts
}

phase_databases() {
    [[ "${MODE}" == "accounts" || "${MODE}" == "system" ]] && {
        log_debug "Skipping databases phase (MODE=${MODE})"
        return 0
    }
    log_phase "PHASE 3/6  Backing up databases"
    backup_databases
    backup_mysql_grants
}

phase_system() {
    [[ "${MODE}" == "accounts" || "${MODE}" == "databases" ]] && {
        log_debug "Skipping system phase (MODE=${MODE})"
        return 0
    }
    log_phase "PHASE 4/6  Backing up system configuration"
    backup_system_configs
    backup_system_manifest
    backup_ssl_inventory
}

phase_upload() {
    log_phase "PHASE 5/6  Uploading to remote"
    upload_backup || log_warn "Upload failed; local backup is still at ${BACKUP_DIR}"
}

phase_rotate() {
    log_phase "PHASE 6/6  Rotating old backups"
    rotate_backups
}

# ------------------------------------------------------------------------------
# Final report
# ------------------------------------------------------------------------------
print_report() {
    local now elapsed total_size
    now=$(date +%s)
    elapsed=$(( now - START_TS ))
    total_size=$(du -sh "${BACKUP_DIR}" 2>/dev/null | awk '{print $1}')
    cat <<EOF

${C_GREEN}${C_BOLD}
================================================================================
                   cPanel Auto Backup Complete
================================================================================${C_RESET}
  Duration  : ${elapsed}s
  Mode      : ${MODE}
  Size      : ${total_size}
  Location  : ${BACKUP_DIR}
  Log file  : ${LOG_FILE}
  Manifest  : ${BACKUP_DIR}/manifest.tsv

${C_CYAN}${C_BOLD}Next Steps${C_RESET}
  - Inspect the manifest:  cat ${BACKUP_DIR}/manifest.tsv
  - Verify the backup:     sudo ${SCRIPT_DIR}/scripts/verify.sh ${BACKUP_DIR}
  - See docs/RESTORE.md to restore an account or database.
================================================================================
EOF
}

# ------------------------------------------------------------------------------
# ERR trap + main
# ------------------------------------------------------------------------------
on_error() {
    local exit_code=$?
    local line_no=${1:-?}
    local src="${BASH_SOURCE[1]:-${SCRIPT_NAME}}"
    log_error "Backup failed at ${src}:${line_no} with exit code ${exit_code}"
    log_error "See ${LOG_FILE} for details."
    local elapsed=0
    [[ ${START_TS} -gt 0 ]] && elapsed=$(( $(date +%s) - START_TS ))
    notify "failure" "${elapsed}" || true
    exit "${exit_code}"
}
trap 'on_error ${LINENO}' ERR

main() {
    START_TS=$(date +%s)

    parse_args "$@"
    init_logging
    phase_preflight
    phase_accounts
    phase_databases
    phase_system
    phase_upload
    phase_rotate

    local elapsed=$(( $(date +%s) - START_TS ))

    # Disarm the ERR trap before notify/report so post-run shell teardown
    # can't flip a successful run into a "failed" email.
    trap - ERR

    notify "success" "${elapsed}"
    print_report
}

main "$@"
