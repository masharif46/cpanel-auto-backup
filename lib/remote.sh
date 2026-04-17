#!/usr/bin/env bash
# lib/remote.sh - upload backup to a remote target

# Supported drivers (set REMOTE_DRIVER in backup.conf):
#   rsync  — SSH+rsync to any server you have key access to
#   s3     — AWS CLI (aws s3 sync) to any S3-compatible bucket
#   sftp   — lftp mirror to an SFTP server
#   none   — skip upload (local-only backups)

# ------------------------------------------------------------------------------
upload_backup() {
    if [[ ${NO_UPLOAD} -eq 1 ]]; then
        log_info "Skipping upload (--no-upload)"
        return 0
    fi
    local driver="${REMOTE_DRIVER:-none}"
    case "${driver}" in
        none)
            log_info "REMOTE_DRIVER=none; skipping upload"
            return 0 ;;
        rsync) _upload_rsync ;;
        s3)    _upload_s3 ;;
        sftp)  _upload_sftp ;;
        *)
            log_error "Unknown REMOTE_DRIVER: ${driver} (expected: rsync|s3|sftp|none)"
            return 1 ;;
    esac
}

# ------------------------------------------------------------------------------
# rsync driver.
#   REMOTE_RSYNC_TARGET   e.g. backup@nas.example.com:/srv/backups/cpanel
#   REMOTE_RSYNC_SSH_KEY  path to the SSH key (default: ~/.ssh/id_rsa)
#   REMOTE_RSYNC_OPTS     extra rsync options (optional)
# ------------------------------------------------------------------------------
_upload_rsync() {
    if ! command -v rsync &>/dev/null; then
        log_error "rsync not installed. dnf install -y rsync"
        return 1
    fi
    if [[ -z "${REMOTE_RSYNC_TARGET:-}" ]]; then
        log_error "REMOTE_RSYNC_TARGET not set in config"
        return 1
    fi
    local key="${REMOTE_RSYNC_SSH_KEY:-/root/.ssh/id_rsa}"
    local ssh_opts="-o StrictHostKeyChecking=accept-new -o BatchMode=yes"
    if [[ -f "${key}" ]]; then
        ssh_opts="${ssh_opts} -i ${key}"
    fi

    local src="${BACKUP_DIR}/"
    local dst
    dst="${REMOTE_RSYNC_TARGET%/}/$(basename "${BACKUP_DIR}")/"

    log_info "Uploading via rsync to ${REMOTE_RSYNC_TARGET}"
    if [[ ${DRY_RUN} -eq 1 ]]; then
        log_info "[DRY-RUN] rsync -aHAX --partial --info=progress2 -e 'ssh ${ssh_opts}' ${REMOTE_RSYNC_OPTS:-} ${src} ${dst}"
        return 0
    fi

    # shellcheck disable=SC2086
    if rsync -aHAX --partial --info=stats2 \
            -e "ssh ${ssh_opts}" \
            ${REMOTE_RSYNC_OPTS:-} \
            "${src}" "${dst}" 2>&1 | tee -a "${LOG_FILE}"; then
        log_info "rsync upload complete"
    else
        log_error "rsync upload failed"
        return 1
    fi
}

# ------------------------------------------------------------------------------
# S3 driver.
#   REMOTE_S3_BUCKET    bucket name (no s3:// prefix)
#   REMOTE_S3_PREFIX    key prefix, e.g. "cpanel-backups/prod"
#   REMOTE_S3_ENDPOINT  optional S3-compatible endpoint (DigitalOcean, Wasabi)
#   REMOTE_S3_SC        storage class (STANDARD, STANDARD_IA, GLACIER, ...)
#   AWS_ACCESS_KEY_ID   \ env vars, or use ~/.aws/credentials
#   AWS_SECRET_ACCESS_KEY/
#   AWS_DEFAULT_REGION /
# ------------------------------------------------------------------------------
_upload_s3() {
    if ! command -v aws &>/dev/null; then
        log_error "aws CLI not installed. See docs/REMOTE.md for install steps."
        return 1
    fi
    if [[ -z "${REMOTE_S3_BUCKET:-}" ]]; then
        log_error "REMOTE_S3_BUCKET not set in config"
        return 1
    fi

    local prefix="${REMOTE_S3_PREFIX:-cpanel-backups}"
    local dst
    dst="s3://${REMOTE_S3_BUCKET}/${prefix%/}/$(basename "${BACKUP_DIR}")"
    local endpoint_arg=""
    [[ -n "${REMOTE_S3_ENDPOINT:-}" ]] && endpoint_arg="--endpoint-url ${REMOTE_S3_ENDPOINT}"
    local sc_arg=""
    [[ -n "${REMOTE_S3_SC:-}" ]] && sc_arg="--storage-class ${REMOTE_S3_SC}"

    log_info "Uploading via S3 to ${dst}"
    if [[ ${DRY_RUN} -eq 1 ]]; then
        log_info "[DRY-RUN] aws s3 sync ${BACKUP_DIR} ${dst} ${endpoint_arg} ${sc_arg}"
        return 0
    fi

    # shellcheck disable=SC2086
    if aws s3 sync "${BACKUP_DIR}" "${dst}" \
            ${endpoint_arg} ${sc_arg} \
            --only-show-errors 2>>"${LOG_FILE}"; then
        log_info "S3 upload complete"
    else
        log_error "S3 upload failed (see ${LOG_FILE})"
        return 1
    fi
}

# ------------------------------------------------------------------------------
# SFTP driver (via lftp so we get mirror + retry + parallel).
#   REMOTE_SFTP_HOST
#   REMOTE_SFTP_PORT     default 22
#   REMOTE_SFTP_USER
#   REMOTE_SFTP_PASS     (consider keyfile via REMOTE_SFTP_SSH_KEY instead)
#   REMOTE_SFTP_SSH_KEY  path to SSH key (takes precedence over password)
#   REMOTE_SFTP_PATH     remote dir
# ------------------------------------------------------------------------------
_upload_sftp() {
    if ! command -v lftp &>/dev/null; then
        log_error "lftp not installed. dnf install -y lftp"
        return 1
    fi
    : "${REMOTE_SFTP_HOST:?REMOTE_SFTP_HOST not set in config}"
    : "${REMOTE_SFTP_USER:?REMOTE_SFTP_USER not set in config}"
    : "${REMOTE_SFTP_PATH:?REMOTE_SFTP_PATH not set in config}"
    local port="${REMOTE_SFTP_PORT:-22}"
    local remote_dir
    remote_dir="${REMOTE_SFTP_PATH%/}/$(basename "${BACKUP_DIR}")"

    log_info "Uploading via SFTP to ${REMOTE_SFTP_USER}@${REMOTE_SFTP_HOST}:${remote_dir}"
    if [[ ${DRY_RUN} -eq 1 ]]; then
        log_info "[DRY-RUN] lftp sftp://${REMOTE_SFTP_USER}@${REMOTE_SFTP_HOST}:${port} mirror ${BACKUP_DIR} ${remote_dir}"
        return 0
    fi

    local lftp_cmds=(
        "set sftp:auto-confirm yes"
        "set net:max-retries 3"
        "set net:timeout 30"
    )
    if [[ -n "${REMOTE_SFTP_SSH_KEY:-}" && -f "${REMOTE_SFTP_SSH_KEY}" ]]; then
        lftp_cmds+=("set sftp:connect-program 'ssh -a -x -i ${REMOTE_SFTP_SSH_KEY}'")
        lftp_cmds+=("open -u ${REMOTE_SFTP_USER}, sftp://${REMOTE_SFTP_HOST}:${port}")
    else
        lftp_cmds+=("open -u ${REMOTE_SFTP_USER},${REMOTE_SFTP_PASS:-} sftp://${REMOTE_SFTP_HOST}:${port}")
    fi
    lftp_cmds+=("mkdir -p ${remote_dir}")
    lftp_cmds+=("mirror --reverse --parallel=4 --verbose ${BACKUP_DIR} ${remote_dir}")
    lftp_cmds+=("bye")

    local script
    script=$(printf '%s\n' "${lftp_cmds[@]}")
    if echo "${script}" | lftp 2>>"${LOG_FILE}"; then
        log_info "SFTP upload complete"
    else
        log_error "SFTP upload failed (see ${LOG_FILE})"
        return 1
    fi
}
