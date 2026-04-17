#!/usr/bin/env bash
# lib/system.sh - server-wide config + metadata backup

# This captures things that are NOT inside per-account tarballs:
# - /etc server config (sshd, named, httpd, exim, etc.)
# - /root dotfiles and scripts
# - cron spool, fstab, resolv.conf, hosts, yum/dnf repos
# - cPanel system config (/var/cpanel, /etc/cpanel, etc.)
# - Installed package list so a fresh box can be rebuilt quickly

SYSTEM_PATHS=(
    /etc
    /root
    /var/spool/cron
    /var/cpanel
    /usr/local/cpanel/3rdparty
)

SYSTEM_EXCLUDES=(
    '/etc/shadow.cache'
    '/var/cpanel/tmp'
    '/var/cpanel/sessions'
    '/root/.bash_history'
    '/root/.mysql_history'
    '/root/.viminfo'
    '/root/.lesshst'
    '/root/.cache'
)

# ------------------------------------------------------------------------------
# Tar up /etc, /root, /var/cpanel, /var/spool/cron.
# ------------------------------------------------------------------------------
backup_system_configs() {
    local dest="${BACKUP_DIR}/system"
    local out="${dest}/system-config.tar.gz"
    run_cmd "mkdir -p '${dest}'"

    if [[ ${DRY_RUN} -eq 1 ]]; then
        log_info "[DRY-RUN] tar czf ${out} ${SYSTEM_PATHS[*]}"
        return 0
    fi

    log_info "Archiving system config: ${SYSTEM_PATHS[*]}"

    local tar_args=(
        --create
        --gzip
        --preserve-permissions
        --acls
        --xattrs
        --ignore-failed-read
        --one-file-system
        --file "${out}"
    )
    local excl
    for excl in "${SYSTEM_EXCLUDES[@]}"; do
        tar_args+=(--exclude="${excl}")
    done

    local inputs=()
    local p
    for p in "${SYSTEM_PATHS[@]}"; do
        [[ -e "${p}" ]] && inputs+=("${p}")
    done
    if [[ ${#inputs[@]} -eq 0 ]]; then
        log_warn "No system paths present; skipping"
        return 0
    fi
    tar_args+=("${inputs[@]}")

    if tar "${tar_args[@]}" 2>>"${LOG_FILE}"; then
        record_artifact "system:configs" "${out}"
    else
        log_error "System config tar failed (see ${LOG_FILE})"
        return 1
    fi
}

# ------------------------------------------------------------------------------
# Installed package manifest (rpm -qa) + service list.
# ------------------------------------------------------------------------------
backup_system_manifest() {
    local dest="${BACKUP_DIR}/system"
    run_cmd "mkdir -p '${dest}'"
    if [[ ${DRY_RUN} -eq 1 ]]; then
        log_info "[DRY-RUN] write package + service manifest to ${dest}"
        return 0
    fi
    log_info "Writing system manifest"
    if command -v rpm &>/dev/null; then
        rpm -qa --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\n' 2>/dev/null \
            | sort > "${dest}/packages.txt" || true
        record_artifact "system:packages" "${dest}/packages.txt"
    fi
    if command -v systemctl &>/dev/null; then
        systemctl list-unit-files --no-legend --type=service 2>/dev/null \
            | sort > "${dest}/services.txt" || true
        record_artifact "system:services" "${dest}/services.txt"
    fi
    # Kernel / OS release snapshot
    {
        echo "# cpanel-auto-backup environment snapshot"
        echo "date=$(date)"
        echo "hostname=$(hostname)"
        echo "kernel=$(uname -r)"
        [[ -f /etc/almalinux-release ]] && echo "os=$(cat /etc/almalinux-release)"
        [[ -f /etc/redhat-release  ]] && echo "os=$(cat /etc/redhat-release)"
        if command -v /usr/local/cpanel/cpanel &>/dev/null; then
            echo "cpanel=$(/usr/local/cpanel/cpanel -V 2>/dev/null || echo unknown)"
        fi
    } > "${dest}/environment.txt"
    record_artifact "system:environment" "${dest}/environment.txt"
}

# ------------------------------------------------------------------------------
# SSL certificate inventory (for audit; the certs themselves are inside
# /var/cpanel and /etc/pki already captured by the configs tarball).
# ------------------------------------------------------------------------------
backup_ssl_inventory() {
    local dest="${BACKUP_DIR}/system"
    run_cmd "mkdir -p '${dest}'"
    if [[ ${DRY_RUN} -eq 1 ]]; then
        log_info "[DRY-RUN] write SSL inventory"
        return 0
    fi
    if [[ -d /var/cpanel/ssl ]]; then
        find /var/cpanel/ssl -type f -name '*.crt' 2>/dev/null | sort > "${dest}/ssl-inventory.txt" || true
        record_artifact "system:ssl-inventory" "${dest}/ssl-inventory.txt"
    fi
}
