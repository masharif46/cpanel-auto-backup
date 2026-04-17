# Configuration reference

Every knob in `/etc/cpanel-auto-backup/backup.conf`, what it does, and what happens if you leave it unset. The shipped [`config/backup.conf.example`](../config/backup.conf.example) is the authoritative template.

The file is sourced as a Bash script — quote values containing spaces.

## Contents

- [Local storage](#local-storage)
- [Retention](#retention)
- [Account selection](#account-selection)
- [pkgacct content control](#pkgacct-content-control)
- [Remote upload](#remote-upload)
- [Notifications](#notifications)
- [Permissions & secrets handling](#permissions--secrets-handling)
- [Config validation checklist](#config-validation-checklist)

## Local storage

| Variable | Default | Description |
|---|---|---|
| `BACKUP_ROOT` | `/backup/cpanel` | Parent directory — each run creates a `YYYY-MM-DD_HHMMSS` subdir inside it. Must be on a filesystem with enough room for at least one full run. |

**Recommended**: mount a dedicated volume here. Never point `BACKUP_ROOT` at `/home`, `/var`, or anywhere inside `/usr/local/cpanel` — rotation *only* touches directories that match its timestamp pattern, so a misconfig can't wipe user data, but the backup process will still race with cPanel itself.

## Retention

| Variable | Default | Description |
|---|---|---|
| `RETENTION_DAYS` | `7` | Keep the newest N daily runs. |
| `RETENTION_WEEKLY` | `0` | Additionally keep the newest run from each of the last N ISO weeks. |
| `RETENTION_MONTHLY` | `0` | Additionally keep the newest run from each of the last N calendar months. |

The three are additive. A run kept by the daily rule AND the weekly rule counts once — it just won't be deleted.

Examples:

```bash
# Minimal: one week of nightlies, nothing else.
RETENTION_DAYS=7
RETENTION_WEEKLY=0
RETENTION_MONTHLY=0

# Grandfather-father-son: 7 days + 4 weeks + 12 months (~1 year).
RETENTION_DAYS=7
RETENTION_WEEKLY=4
RETENTION_MONTHLY=12

# Paranoid: 30 days of nightlies.
RETENTION_DAYS=30
```

## Account selection

| Variable | Default | Description |
|---|---|---|
| `INCLUDE_ACCOUNTS` | *(empty — all accounts)* | Space-separated list of usernames to back up. Empty means "all". |
| `EXCLUDE_ACCOUNTS` | *(empty)* | Space-separated list of usernames to skip. Wins over INCLUDE. |

```bash
INCLUDE_ACCOUNTS="alice bob"           # only these two
EXCLUDE_ACCOUNTS="testuser staging"    # skip these; all others included
```

Usernames are matched exactly against directory names under `/var/cpanel/users/`.

## pkgacct content control

pkgacct produces very large tarballs if you include everything. Skip heavy items you don't need:

| Variable | Default | Skips |
|---|---|---|
| `BACKUP_SKIP_HOMEDIR` | `0` | `/home/<user>` contents (use with care — you lose website files!) |
| `BACKUP_SKIP_EMAIL` | `0` | Maildir contents (not mail routing config) |
| `BACKUP_SKIP_LOGS` | `1` | `/home/<user>/logs`, `access_log`, `error_log` |
| `BACKUP_SKIP_MAILMAN` | `1` | Mailman mailing-list archives |

Defaults skip logs (usually several GB of noise) and mailman (rarely used). Override explicitly if you care about them.

## Remote upload

The `REMOTE_DRIVER` chooses which off-site uploader to use. Exactly one of:

| Value | Driver | Required variables |
|---|---|---|
| `rsync` | SSH + rsync | `REMOTE_RSYNC_TARGET`, (`REMOTE_RSYNC_SSH_KEY`) |
| `s3` | AWS S3 / compatible | `REMOTE_S3_BUCKET`, AWS creds |
| `sftp` | lftp + SFTP | `REMOTE_SFTP_HOST`, `REMOTE_SFTP_USER`, `REMOTE_SFTP_PATH`, auth |
| `none` | no upload | — |

Full configuration examples for each driver: [REMOTE.md](REMOTE.md).

## Notifications

| Variable | Meaning |
|---|---|
| `NOTIFY_ON` | `success`, `failure`, or `always`. Default `failure`. |
| `NOTIFY_EMAIL` | Comma-separated recipients. Requires `mail` or `sendmail`. |
| `NOTIFY_SLACK_WEBHOOK` | Slack Incoming Webhook URL. |
| `NOTIFY_WEBHOOK_URL` | Generic JSON POST. Body: `{status, host, duration_seconds, backup_path, summary}`. |

Any combination of the three channels can fire in the same run.

## Permissions & secrets handling

`backup.conf` may contain SSH key paths, MySQL passwords, S3 keys, or Slack webhooks. The tool checks permissions at load time and warns if they're loose:

```bash
sudo chown root:root /etc/cpanel-auto-backup/backup.conf
sudo chmod 600       /etc/cpanel-auto-backup/backup.conf
```

Prefer env-var or file-based credentials over inlining secrets in the config:

- **AWS**: use `~/.aws/credentials` for the `root` user — the AWS CLI will pick it up without the config touching the keys.
- **rsync / SFTP**: use SSH keys instead of passwords. Put the key at `/root/.ssh/id_rsa` (mode `0600`) and reference its path in the config; the key itself stays out of `backup.conf`.
- **MySQL**: use `/root/.my.cnf` (`0600`). The tool automatically picks it up without you writing a password into `backup.conf`.

## Config validation checklist

After editing, run through this:

```bash
# Syntax (any Bash error means the file won't load):
sudo bash -n /etc/cpanel-auto-backup/backup.conf

# Permissions (must be 600 or 400):
stat -c '%a %n' /etc/cpanel-auto-backup/backup.conf

# Full dry-run — exercises every code path, writes nothing:
sudo cpanel-auto-backup --dry-run --verbose

# Upload reachability (rsync / sftp / s3), if you set one up:
sudo cpanel-auto-backup --system-only --dry-run   # smallest possible path
```

If `--dry-run --verbose` ends on the green "Complete" banner and your upload target accepts a test connection, the config is good.
