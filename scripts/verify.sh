#!/usr/bin/env bash
#
# scripts/verify.sh — sanity-check a completed backup directory.
#
# Usage:
#   sudo ./scripts/verify.sh /backup/cpanel/2026-04-17_020000
#
# Exits 0 if every artifact in manifest.tsv passes its check, 1 otherwise.

set -Eeuo pipefail

RED=$'\033[0;31m'; GRN=$'\033[0;32m'; YLW=$'\033[1;33m'; RST=$'\033[0m'

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 /backup/cpanel/YYYY-MM-DD_HHMMSS" >&2
    exit 64
fi

DIR="$1"
if [[ ! -d "${DIR}" ]]; then
    echo "Not a directory: ${DIR}" >&2
    exit 1
fi
MANIFEST="${DIR}/manifest.tsv"
if [[ ! -f "${MANIFEST}" ]]; then
    echo "Missing manifest.tsv in ${DIR}" >&2
    exit 1
fi

fail=0
ok=0

check() {
    local label="$1" path="$2"
    if [[ ! -s "${path}" ]]; then
        printf '%b[FAIL]%b %s  missing or empty: %s\n' "${RED}" "${RST}" "${label}" "${path}"
        fail=$((fail+1))
        return
    fi
    case "${path}" in
        *.tar.gz|*.tgz)
            if gzip -t -- "${path}" 2>/dev/null && tar -tzf "${path}" >/dev/null 2>&1; then
                printf '%b[ OK ]%b %s  %s\n' "${GRN}" "${RST}" "${label}" "${path}"
                ok=$((ok+1))
            else
                printf '%b[FAIL]%b %s  corrupt tarball: %s\n' "${RED}" "${RST}" "${label}" "${path}"
                fail=$((fail+1))
            fi ;;
        *.sql.gz)
            if gzip -t -- "${path}" 2>/dev/null; then
                printf '%b[ OK ]%b %s  %s\n' "${GRN}" "${RST}" "${label}" "${path}"
                ok=$((ok+1))
            else
                printf '%b[FAIL]%b %s  corrupt gzip: %s\n' "${RED}" "${RST}" "${label}" "${path}"
                fail=$((fail+1))
            fi ;;
        *)
            printf '%b[ OK ]%b %s  %s\n' "${GRN}" "${RST}" "${label}" "${path}"
            ok=$((ok+1)) ;;
    esac
}

echo "==== cpanel-auto-backup verify: ${DIR} ===="
while IFS=$'\t' read -r label size path; do
    [[ -z "${label}" ]] && continue
    check "${label}" "${path}"
done < "${MANIFEST}"

echo "----------------------------------------------"
if [[ ${fail} -gt 0 ]]; then
    printf '%b%d failed%b, %d ok\n' "${RED}" "${fail}" "${RST}" "${ok}"
    exit 1
fi
printf '%ball %d artifacts verified%b\n' "${GRN}" "${ok}" "${RST}"
