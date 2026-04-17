#!/usr/bin/env bash
# lib/common.sh - shared helper functions for cpanel-auto-backup
# shellcheck disable=SC2034

# ------------------------------------------------------------------------------
# Logging
# ------------------------------------------------------------------------------
init_logging() {
    mkdir -p "${LOG_DIR}"
    : > "${LOG_FILE}"
    chmod 600 "${LOG_FILE}"
    exec > >(tee -a "${LOG_FILE}") 2>&1
    log_info "cpanel-auto-backup v${SCRIPT_VERSION} starting on $(hostname) at $(date)"
    log_info "Flags: DRY_RUN=${DRY_RUN} FORCE=${FORCE} MODE=${MODE} NO_UPLOAD=${NO_UPLOAD}"
}

_ts() { date +'%Y-%m-%d %H:%M:%S'; }

log_info()  { printf '%s %b[INFO]%b  %s\n'  "$(_ts)" "${C_GREEN}"  "${C_RESET}" "$*"; }
log_warn()  { printf '%s %b[WARN]%b  %s\n'  "$(_ts)" "${C_YELLOW}" "${C_RESET}" "$*"; }
log_error() { printf '%s %b[ERROR]%b %s\n' "$(_ts)" "${C_RED}"    "${C_RESET}" "$*" >&2; }
log_debug() {
    [[ ${VERBOSE:-0} -eq 1 ]] && printf '%s %b[DEBUG]%b %s\n' "$(_ts)" "${C_BLUE}" "${C_RESET}" "$*"
    return 0
}

log_phase() {
    echo
    printf '%b==============================================================================%b\n' "${C_CYAN}${C_BOLD}" "${C_RESET}"
    printf '%b%s%b\n' "${C_CYAN}${C_BOLD}" "$*" "${C_RESET}"
    printf '%b==============================================================================%b\n' "${C_CYAN}${C_BOLD}" "${C_RESET}"
}

# ------------------------------------------------------------------------------
# Command execution
# ------------------------------------------------------------------------------
run_cmd() {
    local cmd="$*"
    if [[ ${DRY_RUN} -eq 1 ]]; then
        log_info "[DRY-RUN] ${cmd}"
        return 0
    fi
    log_debug "\$ ${cmd}"
    eval "${cmd}"
}

# Best-effort: log a warning on failure but do not abort.
safe_cmd() {
    local cmd="$*"
    if [[ ${DRY_RUN} -eq 1 ]]; then
        log_info "[DRY-RUN] ${cmd}"
        return 0
    fi
    log_debug "\$ ${cmd}"
    eval "${cmd}" || log_warn "Command failed (ignored): ${cmd}"
}

# ------------------------------------------------------------------------------
# Pre-flight
# ------------------------------------------------------------------------------
require_root() {
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        log_error "This script must be run as root (use sudo)."
        exit 2
    fi
}

require_cpanel() {
    if [[ ! -x /usr/local/cpanel/cpanel ]]; then
        log_error "cPanel not detected at /usr/local/cpanel. Is this the right server?"
        if [[ ${FORCE} -ne 1 ]]; then
            exit 3
        fi
        log_warn "--force passed; continuing without cPanel (databases/system only)."
    fi
}

require_tool() {
    local tool="$1"
    if ! command -v "${tool}" &>/dev/null; then
        log_error "Required tool not found in PATH: ${tool}"
        exit 4
    fi
}

# ------------------------------------------------------------------------------
# Disk space check (bytes required vs. free)
# ------------------------------------------------------------------------------
check_free_space() {
    local path="$1"
    local need_mb="${2:-1024}"
    local free_mb
    free_mb=$(df -Pm "${path}" 2>/dev/null | awk 'NR==2{print $4}')
    if [[ -z "${free_mb}" ]]; then
        log_warn "Could not determine free space on ${path}"
        return 0
    fi
    if [[ ${free_mb} -lt ${need_mb} ]]; then
        log_error "Insufficient free space on ${path}: ${free_mb}MB free, need ${need_mb}MB"
        if [[ ${FORCE} -ne 1 ]]; then
            exit 5
        fi
        log_warn "--force passed; proceeding despite low disk space"
    else
        log_debug "Free space on ${path}: ${free_mb}MB (>= ${need_mb}MB required)"
    fi
}

# ------------------------------------------------------------------------------
# Config loader
# ------------------------------------------------------------------------------
load_config() {
    local file="$1"
    if [[ ! -f "${file}" ]]; then
        log_error "Config file not found: ${file}"
        log_error "Copy config/backup.conf.example to /etc/cpanel-auto-backup/backup.conf"
        log_error "or pass --config /path/to/backup.conf"
        exit 6
    fi
    # Enforce safe permissions — the config can hold remote credentials.
    local perms
    perms=$(stat -c '%a' "${file}" 2>/dev/null || echo "")
    if [[ -n "${perms}" && "${perms}" != "600" && "${perms}" != "400" ]]; then
        log_warn "Config ${file} has loose permissions (${perms}); should be 600 or 400"
    fi
    # shellcheck disable=SC1090
    source "${file}"
    log_info "Loaded config: ${file}"
}

# ------------------------------------------------------------------------------
# Backup directory helpers
# ------------------------------------------------------------------------------
ensure_backup_dir() {
    if [[ ! -d "${BACKUP_ROOT}" ]]; then
        run_cmd "mkdir -p '${BACKUP_ROOT}'"
        run_cmd "chmod 700 '${BACKUP_ROOT}'"
    fi
    run_cmd "mkdir -p '${BACKUP_DIR}'"
    run_cmd "chmod 700 '${BACKUP_DIR}'"
}

# Human-readable size of a file/dir
hsize() {
    du -sh "$1" 2>/dev/null | awk '{print $1}'
}

# Emit a summary line that post-backup reports / notifications can pick up.
record_artifact() {
    local label="$1"
    local path="$2"
    local size
    size=$(hsize "${path}")
    printf '%s\t%s\t%s\n' "${label}" "${size}" "${path}" >> "${BACKUP_DIR}/manifest.tsv"
    log_info "  ${label}: ${size}  ${path}"
}
