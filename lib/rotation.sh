#!/usr/bin/env bash
# lib/rotation.sh - retention / cleanup of old backups

# Directory layout:
#   ${BACKUP_ROOT}/
#     2026-04-17_020000/   <-- one run
#       accounts/
#       databases/
#       system/
#       manifest.tsv
#     2026-04-16_020000/
#     ...
#
# Rotation keeps the last N daily runs (RETENTION_DAYS) plus weekly/monthly
# rollups if RETENTION_WEEKLY / RETENTION_MONTHLY are set.

# Safe-guard: any directory we delete must live under BACKUP_ROOT and match
# the timestamp naming convention, so a misconfigured BACKUP_ROOT can't
# wipe /home.
_is_backup_dir() {
    local d="$1"
    [[ "${d}" == "${BACKUP_ROOT}"/* ]] || return 1
    local base
    base=$(basename "${d}")
    [[ "${base}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}$ ]]
}

list_backup_dirs() {
    # Sorted oldest → newest.
    find "${BACKUP_ROOT}" -maxdepth 1 -mindepth 1 -type d \
        -regextype posix-extended \
        -regex '.*/[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}$' \
        2>/dev/null | sort
}

# ------------------------------------------------------------------------------
# Apply the retention policy.
#   RETENTION_DAYS     : keep last N daily backups (default 7)
#   RETENTION_WEEKLY   : also keep the newest backup of each of the last N
#                        ISO weeks (optional, default 0)
#   RETENTION_MONTHLY  : also keep the newest backup of each of the last N
#                        months (optional, default 0)
# ------------------------------------------------------------------------------
rotate_backups() {
    local keep_days="${RETENTION_DAYS:-7}"
    local keep_weekly="${RETENTION_WEEKLY:-0}"
    local keep_monthly="${RETENTION_MONTHLY:-0}"

    log_info "Applying retention: daily=${keep_days} weekly=${keep_weekly} monthly=${keep_monthly}"

    local all=()
    mapfile -t all < <(list_backup_dirs)
    if [[ ${#all[@]} -eq 0 ]]; then
        log_debug "Nothing to rotate"
        return 0
    fi

    # Mark-keep, sweep-rest.
    declare -A keep=()

    # Daily: keep the newest N.
    local i
    local n=${#all[@]}
    for (( i=0; i<keep_days && i<n; i++ )); do
        keep["${all[n-1-i]}"]=1
    done

    # Weekly: newest per ISO week-of-year, newest N weeks.
    if [[ ${keep_weekly} -gt 0 ]]; then
        declare -A seen_week=()
        local d week
        for (( i=n-1; i>=0; i-- )); do
            d="${all[i]}"
            local base iso
            base=$(basename "${d}")
            # 2026-04-17_020000 → 2026-04-17
            iso="${base%%_*}"
            week=$(date -d "${iso}" +'%G-W%V' 2>/dev/null || echo "unknown")
            if [[ -z "${seen_week[${week}]:-}" ]]; then
                seen_week[${week}]=1
                keep["${d}"]=1
                if [[ ${#seen_week[@]} -ge ${keep_weekly} ]]; then
                    break
                fi
            fi
        done
    fi

    # Monthly: newest per YYYY-MM, newest N months.
    if [[ ${keep_monthly} -gt 0 ]]; then
        declare -A seen_month=()
        local d month
        for (( i=n-1; i>=0; i-- )); do
            d="${all[i]}"
            local base
            base=$(basename "${d}")
            month="${base:0:7}"  # YYYY-MM
            if [[ -z "${seen_month[${month}]:-}" ]]; then
                seen_month[${month}]=1
                keep["${d}"]=1
                if [[ ${#seen_month[@]} -ge ${keep_monthly} ]]; then
                    break
                fi
            fi
        done
    fi

    # Sweep.
    local removed=0
    local d
    for d in "${all[@]}"; do
        if [[ -n "${keep[${d}]:-}" ]]; then
            log_debug "Keep: ${d}"
            continue
        fi
        if ! _is_backup_dir "${d}"; then
            log_warn "Refusing to delete non-backup dir: ${d}"
            continue
        fi
        if [[ ${DRY_RUN} -eq 1 ]]; then
            log_info "[DRY-RUN] rm -rf ${d}"
        else
            log_info "Rotating out: ${d}"
            rm -rf --one-file-system -- "${d}" || log_warn "Could not remove ${d}"
            removed=$((removed+1))
        fi
    done

    log_info "Rotation complete: kept ${#keep[@]}, removed ${removed}"
}
