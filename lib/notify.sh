#!/usr/bin/env bash
# lib/notify.sh - email / webhook notifications

# Supported channels (any combination, configured in backup.conf):
#   NOTIFY_EMAIL           (comma-separated recipients)
#   NOTIFY_WEBHOOK_URL     generic POST (JSON body with status + summary)
#   NOTIFY_SLACK_WEBHOOK   Slack incoming webhook
#   NOTIFY_ON              success|failure|always  (default: failure)

# ------------------------------------------------------------------------------
_should_notify() {
    local status="$1"
    local when="${NOTIFY_ON:-failure}"
    case "${when}" in
        always)  return 0 ;;
        success) [[ "${status}" == "success" ]] ;;
        failure) [[ "${status}" == "failure" ]] ;;
        *)       [[ "${status}" == "failure" ]] ;;
    esac
}

# Build a short text summary from the backup manifest + status.
_build_summary() {
    local status="$1"
    local duration_s="$2"
    local host; host=$(hostname)
    local date; date=$(date)
    local artifact_count=0
    local total_size="-"
    if [[ -f "${BACKUP_DIR}/manifest.tsv" ]]; then
        artifact_count=$(wc -l < "${BACKUP_DIR}/manifest.tsv")
    fi
    if [[ -d "${BACKUP_DIR}" ]]; then
        total_size=$(du -sh "${BACKUP_DIR}" 2>/dev/null | awk '{print $1}')
    fi

    cat <<EOF
cpanel-auto-backup ${status^^}
host     : ${host}
date     : ${date}
duration : ${duration_s}s
artifacts: ${artifact_count}
size     : ${total_size}
path     : ${BACKUP_DIR}
log      : ${LOG_FILE}
EOF
}

# ------------------------------------------------------------------------------
notify() {
    local status="$1"      # "success" | "failure"
    local duration_s="$2"

    if ! _should_notify "${status}"; then
        log_debug "Notification suppressed (NOTIFY_ON=${NOTIFY_ON:-failure}, status=${status})"
        return 0
    fi

    local summary
    summary=$(_build_summary "${status}" "${duration_s}")

    [[ -n "${NOTIFY_EMAIL:-}" ]]         && _notify_email "${status}" "${summary}"
    [[ -n "${NOTIFY_SLACK_WEBHOOK:-}" ]] && _notify_slack "${status}" "${summary}"
    [[ -n "${NOTIFY_WEBHOOK_URL:-}" ]]   && _notify_webhook "${status}" "${summary}" "${duration_s}"
    return 0
}

_notify_email() {
    local status="$1"
    local body="$2"
    if ! command -v mail &>/dev/null && ! command -v sendmail &>/dev/null; then
        log_warn "Neither mail nor sendmail installed; skipping email notification"
        return 0
    fi
    local subj="[cpanel-auto-backup ${status}] $(hostname) $(date +%F)"
    local rcpt="${NOTIFY_EMAIL}"
    log_info "Emailing ${rcpt}"
    if command -v mail &>/dev/null; then
        printf '%s\n' "${body}" | mail -s "${subj}" "${rcpt}" || log_warn "mail send failed"
    else
        {
            printf 'To: %s\n'      "${rcpt}"
            printf 'Subject: %s\n' "${subj}"
            printf 'Content-Type: text/plain; charset=UTF-8\n\n'
            printf '%s\n' "${body}"
        } | sendmail -t || log_warn "sendmail send failed"
    fi
}

_notify_slack() {
    local status="$1"
    local body="$2"
    if ! command -v curl &>/dev/null; then
        log_warn "curl not installed; skipping Slack notification"
        return 0
    fi
    local emoji=":white_check_mark:"
    [[ "${status}" == "failure" ]] && emoji=":rotating_light:"
    # Escape double quotes and newlines for JSON.
    local safe_body
    safe_body=$(printf '%s' "${body}" | sed 's/"/\\"/g' | awk 'BEGIN{ORS="\\n"}{print}')
    local payload
    payload=$(printf '{"text":"%s *cpanel-auto-backup %s* on %s\\n```%s```"}' \
        "${emoji}" "${status}" "$(hostname)" "${safe_body}")
    log_info "Posting to Slack"
    curl -sS -X POST -H 'Content-Type: application/json' \
        --data "${payload}" "${NOTIFY_SLACK_WEBHOOK}" >/dev/null \
        || log_warn "Slack webhook POST failed"
}

_notify_webhook() {
    local status="$1"
    local body="$2"
    local duration_s="$3"
    if ! command -v curl &>/dev/null; then
        log_warn "curl not installed; skipping webhook notification"
        return 0
    fi
    local safe_body
    safe_body=$(printf '%s' "${body}" | sed 's/"/\\"/g' | awk 'BEGIN{ORS="\\n"}{print}')
    local payload
    payload=$(printf '{"status":"%s","host":"%s","duration_seconds":%s,"backup_path":"%s","summary":"%s"}' \
        "${status}" "$(hostname)" "${duration_s}" "${BACKUP_DIR}" "${safe_body}")
    log_info "Posting to webhook ${NOTIFY_WEBHOOK_URL}"
    curl -sS -X POST -H 'Content-Type: application/json' \
        --data "${payload}" "${NOTIFY_WEBHOOK_URL}" >/dev/null \
        || log_warn "Webhook POST failed"
}
