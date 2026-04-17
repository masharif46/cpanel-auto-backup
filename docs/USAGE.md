# Usage

Everything about running the tool after it's installed. For installation itself see [INSTALL.md](INSTALL.md); for config options see [CONFIG.md](CONFIG.md).

## Contents

- [One-line cheat sheet](#one-line-cheat-sheet)
- [CLI reference](#cli-reference)
- [Exit codes](#exit-codes)
- [Typical workflows](#typical-workflows)
  - [Fire-and-forget nightly](#fire-and-forget-nightly)
  - [Pre-release safety snapshot](#pre-release-safety-snapshot)
  - [Mid-day database-only snapshot](#mid-day-database-only-snapshot)
  - [Backup before a cPanel upgrade](#backup-before-a-cpanel-upgrade)
- [Environment variables](#environment-variables)
- [Progress & monitoring](#progress--monitoring)
- [Interpreting the output](#interpreting-the-output)

## One-line cheat sheet

```bash
sudo cpanel-auto-backup                            # full run, default config
sudo cpanel-auto-backup --dry-run --verbose        # see what it would do
sudo cpanel-auto-backup --accounts-only            # accounts only
sudo cpanel-auto-backup --databases-only           # databases only
sudo cpanel-auto-backup --system-only              # /etc, /root, manifest only
sudo cpanel-auto-backup --no-upload                # local only, skip remote
sudo cpanel-auto-backup --config /path/alt.conf    # custom config file
```

## CLI reference

```
sudo cpanel-auto-backup [OPTIONS]

  --config FILE        Path to backup.conf  (default: /etc/cpanel-auto-backup/backup.conf)
  --dry-run            Show what would happen, change nothing on disk
  --force              Proceed past non-critical pre-flight failures
                       (missing cPanel, low disk space, etc.)
  --accounts-only      Run only the accounts phase (skip dbs, system)
  --databases-only     Run only the databases phase
  --system-only        Run only the system-config phase
  --no-upload          Skip the remote-upload phase; backups remain local
  --verbose, -v        Log DEBUG-level messages
  --version            Print version and exit
  --help, -h           Print usage and exit
```

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Success |
| `2` | Not run as root |
| `3` | cPanel not detected and `--force` not passed |
| `4` | Required tool missing (tar, gzip, mysqldump, …) |
| `5` | Insufficient free space and `--force` not passed |
| `6` | Config file not found or unreadable |
| `64` | Invalid CLI argument |
| other | Propagated from an internal step (see the log) |

Anything non-zero is logged with a `Backup failed at lib/xxx.sh:N` line and fires a `failure` notification if `NOTIFY_ON` allows.

## Typical workflows

### Fire-and-forget nightly

Installed cron entry (`/etc/cron.d/cpanel-auto-backup`) — nothing for you to do after editing `backup.conf`:

```cron
15 2 * * * root /usr/local/sbin/cpanel-auto-backup --config /etc/cpanel-auto-backup/backup.conf >/dev/null 2>&1
```

### Pre-release safety snapshot

Before deploying risky changes, take a one-off local snapshot without touching the nightly rotation cycle:

```bash
# Use a side config that writes to a different root — keeps the nightly
# chain tidy.
sudo install -m 600 /etc/cpanel-auto-backup/backup.conf /root/backup-release.conf
sudo sed -i 's|^BACKUP_ROOT=.*|BACKUP_ROOT="/backup/cpanel-release"|' /root/backup-release.conf
sudo cpanel-auto-backup --config /root/backup-release.conf --no-upload
```

### Mid-day database-only snapshot

When users are about to run a big DB migration and you want a fresh dump without re-running pkgacct:

```bash
sudo cpanel-auto-backup --databases-only --no-upload
```

Runtime is usually a few seconds per database.

### Backup before a cPanel upgrade

cPanel's own `/scripts/upcp` has broken things before. Take a full snapshot first and hold the upgrade until the verify passes:

```bash
sudo cpanel-auto-backup && \
  sudo /opt/cpanel-auto-backup/scripts/verify.sh \
       "/backup/cpanel/$(ls -1 /backup/cpanel | tail -1)" && \
  sudo /scripts/upcp
```

## Environment variables

Most options live in `backup.conf`, but a few overrides are accepted as env vars to simplify one-off runs:

| Var | Effect |
|---|---|
| `DRY_RUN=1` | Same as `--dry-run` |
| `VERBOSE=1` | Same as `--verbose` |
| `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / `AWS_DEFAULT_REGION` | Used by the S3 remote driver |

## Progress & monitoring

Each phase prints a banner to stdout *and* the log:

```
==============================================================================
PHASE 2/6  Backing up cPanel accounts
==============================================================================
2026-04-17 02:15:03 [INFO]  Enumerating cPanel accounts
2026-04-17 02:15:03 [INFO]  Backing up 3 account(s): alice bob carol
2026-04-17 02:15:03 [INFO]  Packaging account: alice
2026-04-17 02:18:42 [INFO]    account:alice: 4.2G  /backup/cpanel/…/accounts/cpmove-alice.tar.gz
```

To watch a live run:

```bash
sudo tail -f /var/log/cpanel-auto-backup/backup-*.log
```

To confirm the next cron fire:

```bash
systemctl list-timers --all | grep -i cron
```

## Interpreting the output

- **`[INFO]`** — normal progress.
- **`[WARN]`** — something unusual happened but the run continues. Example: an individual pkgacct failed but others succeeded. Fix these over time; they don't break the backup.
- **`[ERROR]`** — hard failure; script aborts. Read the preceding lines for the real cause.
- **`[DRY-RUN] <cmd>`** — only appears with `--dry-run`; shows the exact shell command that would have run.

Green "cPanel Auto Backup Complete" banner at the end = success. Everything else = go look at the log.
