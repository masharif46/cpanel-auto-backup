#!/usr/bin/env bash
# lib/databases.sh - MySQL/MariaDB backups

# Per-account databases are already captured by pkgacct (see accounts.sh).
# This module exists for:
#   1. Full-server dumps (including cPanel system DBs, stats, etc.).
#   2. Standalone database servers where you don't want the cPanel account
#      overhead.
#   3. A sanity-check copy outside the per-account tarballs.

# ------------------------------------------------------------------------------
# Detect mysqldump and its credentials source.
# ------------------------------------------------------------------------------
_mysql_cmd() {
    if [[ -f /root/.my.cnf ]]; then
        echo "mysql --defaults-file=/root/.my.cnf"
    else
        echo "mysql"
    fi
}

_mysqldump_cmd() {
    if [[ -f /root/.my.cnf ]]; then
        echo "mysqldump --defaults-file=/root/.my.cnf"
    else
        echo "mysqldump"
    fi
}

list_databases() {
    local sql="SHOW DATABASES"
    local mysql_cmd
    mysql_cmd=$(_mysql_cmd)
    # Skip system schemas.
    eval "${mysql_cmd}" -N -B -e "'${sql}'" 2>/dev/null \
        | grep -Ev '^(information_schema|performance_schema|mysql|sys)$' \
        || true
}

# ------------------------------------------------------------------------------
# Dump a single database. --single-transaction on InnoDB keeps the dump
# consistent without blocking writers; MyISAM tables get --lock-tables.
# ------------------------------------------------------------------------------
backup_one_database() {
    local db="$1"
    local dest="${BACKUP_DIR}/databases"
    local out="${dest}/${db}.sql.gz"

    run_cmd "mkdir -p '${dest}'"
    if [[ ${DRY_RUN} -eq 1 ]]; then
        log_info "[DRY-RUN] mysqldump ${db} | gzip > ${out}"
        return 0
    fi

    log_info "Dumping database: ${db}"
    local dump_cmd
    dump_cmd=$(_mysqldump_cmd)
    if eval "${dump_cmd}" \
        --single-transaction \
        --quick \
        --routines \
        --triggers \
        --events \
        --hex-blob \
        --add-drop-database \
        --databases "${db}" 2>>"${LOG_FILE}" | gzip -c > "${out}"; then
        if [[ -s "${out}" ]]; then
            record_artifact "db:${db}" "${out}"
        else
            log_warn "Dump for ${db} is empty"
            rm -f "${out}"
            return 1
        fi
    else
        log_error "mysqldump failed for ${db} (see ${LOG_FILE})"
        rm -f "${out}"
        return 1
    fi
}

# ------------------------------------------------------------------------------
# Back up all user databases.
# ------------------------------------------------------------------------------
backup_databases() {
    if ! command -v mysqldump &>/dev/null; then
        log_warn "mysqldump not found; skipping database dumps"
        return 0
    fi

    # A quick auth probe so we fail loudly here rather than per-database.
    local mysql_cmd
    mysql_cmd=$(_mysql_cmd)
    if ! eval "${mysql_cmd}" -e "'SELECT 1'" &>/dev/null; then
        log_error "Cannot connect to MySQL. Create /root/.my.cnf with [client] user/password."
        log_error "Example:"
        log_error "  [client]"
        log_error "  user=root"
        log_error "  password=yourpassword"
        log_error "  chmod 600 /root/.my.cnf"
        return 1
    fi

    log_info "Enumerating databases"
    local dbs
    mapfile -t dbs < <(list_databases)
    if [[ ${#dbs[@]} -eq 0 ]]; then
        log_warn "No user databases found"
        return 0
    fi

    log_info "Dumping ${#dbs[@]} database(s)"
    local ok=0 fail=0
    local db
    for db in "${dbs[@]}"; do
        if backup_one_database "${db}"; then
            ok=$((ok+1))
        else
            fail=$((fail+1))
        fi
    done
    log_info "Databases complete: ${ok} ok, ${fail} failed"
    return 0
}

# ------------------------------------------------------------------------------
# Dump MySQL users + grants (handy for a fresh server restore).
# ------------------------------------------------------------------------------
backup_mysql_grants() {
    if ! command -v mysql &>/dev/null; then
        return 0
    fi
    local out="${BACKUP_DIR}/databases/grants.sql"
    run_cmd "mkdir -p '$(dirname "${out}")'"
    if [[ ${DRY_RUN} -eq 1 ]]; then
        log_info "[DRY-RUN] dump MySQL grants to ${out}"
        return 0
    fi
    log_info "Dumping MySQL grants"
    local mysql_cmd
    mysql_cmd=$(_mysql_cmd)
    {
        echo "-- MySQL grants snapshot ($(date))"
        eval "${mysql_cmd}" -N -B -e "\"SELECT CONCAT('SHOW CREATE USER ''', user, '''@''', host, ''';') FROM mysql.user WHERE user NOT IN ('mysql.sys','mysql.session','mysql.infoschema')\"" 2>/dev/null \
            | eval "${mysql_cmd}" -N 2>/dev/null \
            | sed 's/$/;/'
        eval "${mysql_cmd}" -N -B -e "\"SELECT CONCAT('SHOW GRANTS FOR ''', user, '''@''', host, ''';') FROM mysql.user WHERE user NOT IN ('mysql.sys','mysql.session','mysql.infoschema')\"" 2>/dev/null \
            | eval "${mysql_cmd}" -N 2>/dev/null \
            | sed 's/$/;/'
    } > "${out}" 2>>"${LOG_FILE}" || {
        log_warn "Grants dump failed (continuing)"
        return 0
    }
    record_artifact "db:grants" "${out}"
}
