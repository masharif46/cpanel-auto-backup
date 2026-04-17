#!/usr/bin/env bash
# lib/accounts.sh - per-account cPanel backups via pkgacct

# pkgacct is cPanel's official account-packaging tool. It produces a
# cpmove-<user>.tar.gz containing the home dir, databases, DNS zones,
# mail, SSL, subdomains, parked/addon domains, and cPanel metadata.
# Restoring that tarball on another cPanel server recreates the account.

PKGACCT="/usr/local/cpanel/scripts/pkgacct"

# ------------------------------------------------------------------------------
# List accounts to back up, honouring INCLUDE_ACCOUNTS / EXCLUDE_ACCOUNTS.
# ------------------------------------------------------------------------------
list_cpanel_accounts() {
    if [[ ! -d /var/cpanel/users ]]; then
        return 0
    fi
    local user
    for user in /var/cpanel/users/*; do
        [[ -f "${user}" ]] || continue
        user=$(basename "${user}")
        # Skip system pseudo-accounts that sometimes appear there.
        case "${user}" in
            system|root|nobody) continue ;;
        esac
        echo "${user}"
    done | sort -u
}

_account_selected() {
    local user="$1"
    # EXCLUDE wins over INCLUDE.
    if [[ -n "${EXCLUDE_ACCOUNTS:-}" ]]; then
        local ex
        for ex in ${EXCLUDE_ACCOUNTS}; do
            [[ "${user}" == "${ex}" ]] && return 1
        done
    fi
    if [[ -n "${INCLUDE_ACCOUNTS:-}" ]]; then
        local inc
        for inc in ${INCLUDE_ACCOUNTS}; do
            [[ "${user}" == "${inc}" ]] && return 0
        done
        return 1
    fi
    return 0
}

# ------------------------------------------------------------------------------
# Back up a single account.
# ------------------------------------------------------------------------------
backup_one_account() {
    local user="$1"
    local dest="${BACKUP_DIR}/accounts"
    local out="${dest}/cpmove-${user}.tar.gz"

    if [[ ! -x "${PKGACCT}" ]]; then
        log_error "${PKGACCT} not found — cannot back up accounts"
        return 1
    fi

    run_cmd "mkdir -p '${dest}'"

    if [[ ${DRY_RUN} -eq 1 ]]; then
        log_info "[DRY-RUN] ${PKGACCT} ${user} ${dest}"
        return 0
    fi

    log_info "Packaging account: ${user}"
    # pkgacct writes cpmove-<user>.tar.gz directly into the dest dir.
    # --skiphomedir / --skipemail / --skiplogs control optional content;
    # we honour BACKUP_SKIP_* environment variables from the config.
    local pkg_args=("${user}" "${dest}")
    [[ ${BACKUP_SKIP_HOMEDIR:-0} -eq 1 ]] && pkg_args+=(--skiphomedir)
    [[ ${BACKUP_SKIP_EMAIL:-0}   -eq 1 ]] && pkg_args+=(--skipemail)
    [[ ${BACKUP_SKIP_LOGS:-0}    -eq 1 ]] && pkg_args+=(--skiplogs)
    [[ ${BACKUP_SKIP_MAILMAN:-0} -eq 1 ]] && pkg_args+=(--skipmailman)

    if "${PKGACCT}" "${pkg_args[@]}" >>"${LOG_FILE}" 2>&1; then
        if [[ -f "${out}" ]]; then
            record_artifact "account:${user}" "${out}"
        else
            log_warn "pkgacct exited 0 but ${out} not found"
            return 1
        fi
    else
        log_error "pkgacct failed for ${user} (see ${LOG_FILE})"
        return 1
    fi
}

# ------------------------------------------------------------------------------
# Back up every selected account.
# ------------------------------------------------------------------------------
backup_accounts() {
    log_info "Enumerating cPanel accounts"
    local users
    mapfile -t users < <(list_cpanel_accounts)
    if [[ ${#users[@]} -eq 0 ]]; then
        log_warn "No cPanel accounts found at /var/cpanel/users"
        return 0
    fi

    local selected=()
    local u
    for u in "${users[@]}"; do
        if _account_selected "${u}"; then
            selected+=("${u}")
        fi
    done

    if [[ ${#selected[@]} -eq 0 ]]; then
        log_warn "No accounts selected after applying INCLUDE/EXCLUDE filters"
        return 0
    fi

    log_info "Backing up ${#selected[@]} account(s): ${selected[*]}"

    local ok=0 fail=0
    for u in "${selected[@]}"; do
        if backup_one_account "${u}"; then
            ok=$((ok+1))
        else
            fail=$((fail+1))
        fi
    done
    log_info "Accounts complete: ${ok} ok, ${fail} failed"
    return 0
}
