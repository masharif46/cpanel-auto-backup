#!/usr/bin/env bash
#
# scripts/install.sh — one-shot installer for cpanel-auto-backup.
#
# Installs the script tree into /opt/cpanel-auto-backup, drops a
# configuration stub at /etc/cpanel-auto-backup/backup.conf (only if one
# doesn't already exist), and optionally installs a nightly cron entry.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/masharif46/cpanel-auto-backup/main/scripts/install.sh | sudo bash
#   # or from a checkout:
#   sudo ./scripts/install.sh [--cron] [--no-cron]

set -Eeuo pipefail

INSTALL_DIR="/opt/cpanel-auto-backup"
CONF_DIR="/etc/cpanel-auto-backup"
CONF_FILE="${CONF_DIR}/backup.conf"
BIN_LINK="/usr/local/sbin/cpanel-auto-backup"
CRON_FILE="/etc/cron.d/cpanel-auto-backup"
REPO_URL="https://github.com/masharif46/cpanel-auto-backup.git"
REPO_BRANCH="main"

CRON_MODE="ask"       # ask | yes | no

for a in "$@"; do
    case "$a" in
        --cron)    CRON_MODE="yes" ;;
        --no-cron) CRON_MODE="no"  ;;
        --help|-h)
            cat <<EOF
Install cpanel-auto-backup to ${INSTALL_DIR}.

Usage:
  sudo $0 [--cron | --no-cron]

  --cron     Install the default nightly cron entry (${CRON_FILE}) without prompting.
  --no-cron  Skip cron installation.
EOF
            exit 0 ;;
        *) echo "Unknown arg: $a" >&2; exit 64 ;;
    esac
done

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    echo "Must be run as root. Re-run with sudo." >&2
    exit 2
fi

for tool in git bash tar gzip; do
    if ! command -v "${tool}" &>/dev/null; then
        echo "Missing required tool: ${tool}" >&2
        exit 3
    fi
done

echo "==> Installing cpanel-auto-backup to ${INSTALL_DIR}"

# If we were piped from curl, there is no local checkout — clone.
# If we're run from a working tree, copy it instead.
src_dir=""
if [[ -f "$(dirname "$0")/../backup-cpanel.sh" ]]; then
    src_dir="$(cd "$(dirname "$0")/.." && pwd)"
fi

if [[ -n "${src_dir}" ]]; then
    mkdir -p "${INSTALL_DIR}"
    cp -a "${src_dir}/." "${INSTALL_DIR}/"
else
    tmp=$(mktemp -d)
    trap 'rm -rf "${tmp}"' EXIT
    git clone --depth=1 --branch="${REPO_BRANCH}" "${REPO_URL}" "${tmp}"
    mkdir -p "${INSTALL_DIR}"
    cp -a "${tmp}/." "${INSTALL_DIR}/"
fi

chmod +x "${INSTALL_DIR}/backup-cpanel.sh" \
         "${INSTALL_DIR}"/scripts/*.sh

ln -sfn "${INSTALL_DIR}/backup-cpanel.sh" "${BIN_LINK}"
echo "==> Symlinked ${BIN_LINK} → ${INSTALL_DIR}/backup-cpanel.sh"

mkdir -p "${CONF_DIR}"
chmod 700 "${CONF_DIR}"
if [[ ! -f "${CONF_FILE}" ]]; then
    cp "${INSTALL_DIR}/config/backup.conf.example" "${CONF_FILE}"
    chmod 600 "${CONF_FILE}"
    echo "==> Wrote example config to ${CONF_FILE}"
    echo "    EDIT IT before running: ${CONF_FILE}"
else
    echo "==> Existing config kept at ${CONF_FILE}"
fi

mkdir -p /var/log/cpanel-auto-backup
chmod 700 /var/log/cpanel-auto-backup

if [[ "${CRON_MODE}" == "ask" ]]; then
    read -r -p "Install nightly cron at 02:15? [y/N] " ans
    case "${ans,,}" in y|yes) CRON_MODE="yes" ;; *) CRON_MODE="no" ;; esac
fi

if [[ "${CRON_MODE}" == "yes" ]]; then
    cat > "${CRON_FILE}" <<EOF
# cpanel-auto-backup — nightly full backup at 02:15
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
15 2 * * * root ${BIN_LINK} --config ${CONF_FILE} >/dev/null 2>&1
EOF
    chmod 644 "${CRON_FILE}"
    echo "==> Installed cron entry at ${CRON_FILE}"
else
    echo "==> Skipped cron installation (run '${BIN_LINK}' manually or add your own cron)."
fi

echo ""
echo "==> Done. Next steps:"
echo "    1. Edit ${CONF_FILE}"
echo "    2. Test run:  sudo ${BIN_LINK} --dry-run --verbose"
echo "    3. Real run:  sudo ${BIN_LINK}"
