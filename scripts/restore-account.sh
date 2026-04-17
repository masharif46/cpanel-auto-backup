#!/usr/bin/env bash
#
# scripts/restore-account.sh — restore one cPanel account from a backup.
#
# Uses cPanel's official restorepkg, which safely recreates the account,
# home dir, databases, DNS, mail, SSL, subdomains, etc.
#
# Usage:
#   sudo ./scripts/restore-account.sh /backup/cpanel/2026-04-17_020000/accounts/cpmove-alice.tar.gz
#   sudo ./scripts/restore-account.sh --user alice /backup/cpanel/2026-04-17_020000

set -Eeuo pipefail

RESTOREPKG="/usr/local/cpanel/scripts/restorepkg"

usage() {
    cat <<EOF
Restore a cPanel account from a cpmove-<user>.tar.gz produced by this tool.

Usage:
  sudo $0 <path-to-cpmove-USER.tar.gz>
  sudo $0 --user USER <path-to-backup-dir-containing-accounts/>

Notes:
  * Wraps /usr/local/cpanel/scripts/restorepkg.
  * If the account already exists, cPanel prompts for confirmation.
  * Requires cPanel to be installed and running on this server.
EOF
}

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    echo "Must be run as root." >&2
    exit 2
fi

if [[ ! -x "${RESTOREPKG}" ]]; then
    echo "cPanel restorepkg not found at ${RESTOREPKG}." >&2
    echo "Install cPanel, or for manual restore see docs/RESTORE.md" >&2
    exit 3
fi

if [[ $# -lt 1 ]]; then usage; exit 64; fi

if [[ "$1" == "--user" ]]; then
    [[ $# -eq 3 ]] || { usage; exit 64; }
    user="$2"
    root="$3"
    tarball="${root%/}/accounts/cpmove-${user}.tar.gz"
else
    tarball="$1"
    base=$(basename "${tarball}")
    user="${base#cpmove-}"
    user="${user%.tar.gz}"
fi

if [[ ! -f "${tarball}" ]]; then
    echo "Tarball not found: ${tarball}" >&2
    exit 4
fi

echo "==> Restoring account '${user}' from ${tarball}"
workdir=$(mktemp -d /home/cpmove-restore-XXXXXX)
trap 'rm -rf "${workdir}"' EXIT
cp -a "${tarball}" "${workdir}/"
cd "${workdir}"

# restorepkg prefers the file in /home; move + invoke.
mv "$(basename "${tarball}")" "/home/cpmove-${user}.tar.gz"
"${RESTOREPKG}" "${user}"

echo "==> Restore complete for '${user}'."
echo "    Verify:  whoami ${user}; ls /home/${user}; whmapi1 listaccts search=${user}"
