# cpanel-auto-backup

Automated, rotated, optionally off-site backups of every cPanel account, every database, and every system-level configuration file on an AlmaLinux / RHEL / Rocky cPanel server.

Built to run from cron on a live production server. Small, readable Bash. No Python, no agent, no daemon. Pure shell + cPanel's own `pkgacct`.

[![ShellCheck](https://github.com/masharif46/cpanel-auto-backup/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/masharif46/cpanel-auto-backup/actions/workflows/shellcheck.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](./LICENSE)

---

## Table of Contents

- [What it does](#what-it-does)
- [What it does NOT do](#what-it-does-not-do)
- [Requirements](#requirements)
- [Quick start (5 minutes)](#quick-start-5-minutes)
- [Install](#install)
- [Configuration](#configuration)
- [Usage](#usage)
  - [CLI flags](#cli-flags)
  - [Running from cron](#running-from-cron)
  - [Dry-run before committing](#dry-run-before-committing)
  - [Partial backups](#partial-backups)
- [Backup layout on disk](#backup-layout-on-disk)
- [Remote storage](#remote-storage)
  - [rsync over SSH](#rsync-over-ssh)
  - [S3 / S3-compatible](#s3--s3-compatible)
  - [SFTP](#sftp)
- [Retention & rotation](#retention--rotation)
- [Notifications](#notifications)
- [Verifying a backup](#verifying-a-backup)
- [Restoring a backup](#restoring-a-backup)
- [Logs](#logs)
- [Troubleshooting](#troubleshooting)
- [FAQ](#faq)
- [Project layout](#project-layout)
- [Contributing](#contributing)
- [Security](#security)
- [License](#license)

---

## What it does

For each nightly run the script produces **one self-contained, timestamped directory** containing everything you need to rebuild the server:

1. **Per-account tarballs** (`cpmove-<user>.tar.gz`) via cPanel's official `pkgacct`. These are the same format WHM's "Transfer Tool" produces and can be restored on any other cPanel server with `restorepkg`.
2. **Database dumps** (`*.sql.gz`) via `mysqldump --single-transaction --routines --triggers --events`. MySQL user + grants snapshot included.
3. **System configuration tarball** (`system-config.tar.gz`) — `/etc`, `/root`, `/var/cpanel`, `/var/spool/cron`, preserving ACLs/xattrs.
4. **System manifest** — installed RPM list, enabled systemd services, kernel / OS release, cPanel version. Lets a fresh box be rebuilt with `dnf install $(cat packages.txt)`.
5. **Manifest file** (`manifest.tsv`) listing every artifact, its size, and its path — drives the verify and restore tooling.

Then:

6. **Uploads** the directory off-site to rsync / S3 / SFTP (configurable).
7. **Rotates** old backups with a daily + weekly + monthly retention policy.
8. **Notifies** you via email / Slack / webhook on failure (or always, if you prefer).

## What it does NOT do

- It does **not** modify `/home`, databases, or running services — it only reads and packages.
- It does **not** create WHM "Transfers & Restorations" jobs; it uses the lower-level `pkgacct` directly so it can run fully unattended.
- It does **not** replace [JetBackup](https://www.jetbackup.com/) or [R1Soft](https://www.r1soft.com/) for incremental/block-level backups. This is a simple full-dump tool. One night = one full copy. See [FAQ](#faq) for the tradeoff.
- It does **not** include `/home` outside of cPanel accounts (e.g. non-cPanel system users). Add paths to `SYSTEM_PATHS` in `lib/system.sh` if you need them.

## Requirements

- **OS**: AlmaLinux 9 (primary target), RHEL 9, Rocky 9. Should work on AlmaLinux 8 / CentOS 7 with minor tweaks.
- **cPanel/WHM**: any 11.x+ version. Only `pkgacct` / `restorepkg` are assumed.
- **Tools**: `bash` 4.2+, `tar`, `gzip`, `mysqldump`, `rsync` (or `aws` / `lftp` depending on remote driver), `mail` or `sendmail` if you want email notifications.
- **Privileges**: must run as `root` (needs `pkgacct`, read-access to `/var/cpanel`, SSH keys in `/root`, etc.).
- **Disk**: at least the size of your largest single account backup free on `${BACKUP_ROOT}`. A nightly full backup of a 50 GB cPanel install typically produces a 25–35 GB compressed snapshot.

## Quick start (5 minutes)

```bash
# On your cPanel server, as root:
git clone https://github.com/masharif46/cpanel-auto-backup.git /opt/cpanel-auto-backup
cd /opt/cpanel-auto-backup
sudo ./scripts/install.sh --cron

# Configure:
sudo vi /etc/cpanel-auto-backup/backup.conf
# (set BACKUP_ROOT, REMOTE_DRIVER, NOTIFY_EMAIL — defaults work for local-only)

# Dry-run first — writes nothing:
sudo /usr/local/sbin/cpanel-auto-backup --dry-run --verbose

# Real run:
sudo /usr/local/sbin/cpanel-auto-backup

# Verify:
sudo /opt/cpanel-auto-backup/scripts/verify.sh /backup/cpanel/$(ls -1 /backup/cpanel | tail -1)
```

That's it. Cron runs `cpanel-auto-backup` every night at 02:15.

## Install

### Method 1 — installer script (recommended)

The installer clones/copies to `/opt/cpanel-auto-backup`, drops a symlink at `/usr/local/sbin/cpanel-auto-backup`, creates `/etc/cpanel-auto-backup/backup.conf`, and optionally installs `/etc/cron.d/cpanel-auto-backup`.

```bash
# From a local checkout:
git clone https://github.com/masharif46/cpanel-auto-backup.git
cd cpanel-auto-backup
sudo ./scripts/install.sh           # prompts about cron
sudo ./scripts/install.sh --cron    # install cron, no prompt
sudo ./scripts/install.sh --no-cron # skip cron

# Piped from the internet (curl | bash):
curl -fsSL https://raw.githubusercontent.com/masharif46/cpanel-auto-backup/main/scripts/install.sh \
  | sudo bash -s -- --cron
```

### Method 2 — manual

```bash
sudo mkdir -p /opt/cpanel-auto-backup /etc/cpanel-auto-backup /var/log/cpanel-auto-backup
sudo chmod 700 /etc/cpanel-auto-backup /var/log/cpanel-auto-backup
sudo git clone https://github.com/masharif46/cpanel-auto-backup.git /opt/cpanel-auto-backup
sudo chmod +x /opt/cpanel-auto-backup/backup-cpanel.sh /opt/cpanel-auto-backup/scripts/*.sh
sudo ln -s /opt/cpanel-auto-backup/backup-cpanel.sh /usr/local/sbin/cpanel-auto-backup
sudo cp /opt/cpanel-auto-backup/config/backup.conf.example /etc/cpanel-auto-backup/backup.conf
sudo chmod 600 /etc/cpanel-auto-backup/backup.conf
```

## Configuration

Everything lives in **one file**: `/etc/cpanel-auto-backup/backup.conf`. It's sourced as a Bash script. See [`config/backup.conf.example`](config/backup.conf.example) for every knob, fully commented. The highlights:

```bash
# Where backups live locally.
BACKUP_ROOT="/backup/cpanel"

# Keep the last 7 daily runs, plus newest of each of the last 4 weeks
# and 6 months.
RETENTION_DAYS=7
RETENTION_WEEKLY=4
RETENTION_MONTHLY=6

# Back up every account — or filter:
# INCLUDE_ACCOUNTS="alice bob"
# EXCLUDE_ACCOUNTS="testuser"

# Remote driver: rsync | s3 | sftp | none
REMOTE_DRIVER="rsync"
REMOTE_RSYNC_TARGET="backup@nas.example.com:/srv/backups/cpanel"
REMOTE_RSYNC_SSH_KEY="/root/.ssh/id_rsa"

# Notify only when something fails:
NOTIFY_ON="failure"
NOTIFY_EMAIL="ops@example.com"
```

**MySQL credentials:** the tool uses `/root/.my.cnf`. Create one if your MySQL root requires a password:

```ini
[client]
user=root
password=your-secure-password
```

```bash
chmod 600 /root/.my.cnf
```

More detail: [docs/CONFIG.md](docs/CONFIG.md).

## Usage

### CLI flags

```
sudo cpanel-auto-backup [OPTIONS]

  --config FILE        Path to backup.conf (default: /etc/cpanel-auto-backup/backup.conf)
  --dry-run            Show what would happen, change nothing on disk
  --force              Proceed past non-critical pre-flight failures
  --accounts-only      Back up cPanel accounts only
  --databases-only     Back up databases only
  --system-only        Back up /etc, /root, /var/cpanel, packages only
  --no-upload          Skip the remote upload step
  --verbose, -v        Enable debug-level logging
  --version            Show version and exit
  --help, -h           Show help
```

### Running from cron

The installer drops this at `/etc/cron.d/cpanel-auto-backup`:

```cron
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
15 2 * * * root /usr/local/sbin/cpanel-auto-backup --config /etc/cpanel-auto-backup/backup.conf >/dev/null 2>&1
```

Tweak the schedule as you like. Every run writes `/var/log/cpanel-auto-backup/backup-<timestamp>.log`.

More scheduling patterns (twice daily, off-peak windows, skip-if-running, concurrency guards): [docs/CRON.md](docs/CRON.md).

### Dry-run before committing

```bash
sudo cpanel-auto-backup --dry-run --verbose
```

No files are written, no `pkgacct` runs, no uploads happen. Every command that *would* run is logged with a `[DRY-RUN]` prefix. Do this at least once after any config change.

### Partial backups

Useful for ad-hoc work or heavy servers where a full run takes too long:

```bash
# Only new/changed account data — dbs untouched, system untouched:
sudo cpanel-auto-backup --accounts-only --no-upload

# Daily dbs + nightly full runs:
15 1 * * * root /usr/local/sbin/cpanel-auto-backup --databases-only
15 3 * * * root /usr/local/sbin/cpanel-auto-backup
```

## Backup layout on disk

Each run creates **one timestamped directory** under `BACKUP_ROOT`:

```
/backup/cpanel/
├── 2026-04-17_021500/
│   ├── accounts/
│   │   ├── cpmove-alice.tar.gz
│   │   ├── cpmove-bob.tar.gz
│   │   └── cpmove-carol.tar.gz
│   ├── databases/
│   │   ├── alice_wp.sql.gz
│   │   ├── bob_shop.sql.gz
│   │   └── grants.sql
│   ├── system/
│   │   ├── system-config.tar.gz
│   │   ├── packages.txt
│   │   ├── services.txt
│   │   ├── environment.txt
│   │   └── ssl-inventory.txt
│   └── manifest.tsv
├── 2026-04-16_021500/
└── 2026-04-15_021500/
```

`manifest.tsv` is a `<label>\t<size>\t<path>` file consumed by `scripts/verify.sh` and makes it trivial to find a single artifact.

## Remote storage

Set `REMOTE_DRIVER` in `backup.conf` and configure the matching variables. Skip with `--no-upload` on the CLI or `REMOTE_DRIVER="none"` in the config.

### rsync over SSH

**Simplest and recommended** for backups to a dedicated storage box, NAS, or another server.

```bash
REMOTE_DRIVER="rsync"
REMOTE_RSYNC_TARGET="backup@nas.example.com:/srv/backups/cpanel"
REMOTE_RSYNC_SSH_KEY="/root/.ssh/id_rsa"
REMOTE_RSYNC_OPTS="--bwlimit=20000"   # optional, rate-limit to ~20 MB/s
```

Prereqs:

```bash
# On the cPanel server:
ssh-keygen -t ed25519 -f /root/.ssh/id_rsa -N ''      # if no key yet
ssh-copy-id -i /root/.ssh/id_rsa.pub backup@nas.example.com

# Verify:
ssh -i /root/.ssh/id_rsa backup@nas.example.com 'true' && echo OK
```

### S3 / S3-compatible

Works with AWS S3, Wasabi, Backblaze B2 (S3 gateway), DigitalOcean Spaces, MinIO, etc.

```bash
REMOTE_DRIVER="s3"
REMOTE_S3_BUCKET="my-backup-bucket"
REMOTE_S3_PREFIX="cpanel-backups/prod"
REMOTE_S3_SC="STANDARD_IA"            # STANDARD, STANDARD_IA, GLACIER, DEEP_ARCHIVE
# For non-AWS providers:
REMOTE_S3_ENDPOINT="https://s3.us-west-1.wasabisys.com"

export AWS_ACCESS_KEY_ID="AKIA..."
export AWS_SECRET_ACCESS_KEY="..."
export AWS_DEFAULT_REGION="us-east-1"
```

Install the AWS CLI:

```bash
dnf install -y python3-pip
pip3 install awscli
aws --version
```

### SFTP

Useful when all you have is an SFTP-only hosting account. Uses `lftp` under the hood for parallel mirror + retry.

```bash
REMOTE_DRIVER="sftp"
REMOTE_SFTP_HOST="backup.example.com"
REMOTE_SFTP_PORT=22
REMOTE_SFTP_USER="backup"
REMOTE_SFTP_SSH_KEY="/root/.ssh/id_rsa"       # preferred
# REMOTE_SFTP_PASS="..."                      # only if no key
REMOTE_SFTP_PATH="/srv/backups/cpanel"
```

```bash
dnf install -y lftp
```

Full deep-dive (network topology, bandwidth tuning, two-site replication): [docs/REMOTE.md](docs/REMOTE.md).

## Retention & rotation

Configured via three knobs:

| Variable | Meaning |
|---|---|
| `RETENTION_DAYS` | Keep the newest N daily runs (default `7`) |
| `RETENTION_WEEKLY` | Also keep the newest run from each of the last N ISO weeks (default `0`) |
| `RETENTION_MONTHLY` | Also keep the newest run from each of the last N calendar months (default `0`) |

Rotation runs at the **end** of every backup, so a successful new run is already in place before old ones are removed. Rotation refuses to delete any directory that isn't under `BACKUP_ROOT` *and* doesn't match the `YYYY-MM-DD_HHMMSS` timestamp pattern — a misconfigured `BACKUP_ROOT` cannot wipe `/home`.

Example grandfather-father-son policy:

```bash
RETENTION_DAYS=7       # last 7 days
RETENTION_WEEKLY=4     # 4 weekly
RETENTION_MONTHLY=12   # 12 monthly = 1 year retention
```

With nightly runs that retains ~23 snapshots (7 daily + 4 weekly + 12 monthly = some overlap collapses it).

## Notifications

Any combination of channels — all optional.

```bash
# Fire on: success | failure | always
NOTIFY_ON="failure"

# Email (requires mail or sendmail installed)
NOTIFY_EMAIL="ops@example.com,oncall@example.com"

# Slack incoming webhook (https://api.slack.com/messaging/webhooks)
NOTIFY_SLACK_WEBHOOK="https://hooks.slack.com/services/XXX/YYY/ZZZ"

# Generic JSON POST — receives:
#   { status, host, duration_seconds, backup_path, summary }
NOTIFY_WEBHOOK_URL="https://monitoring.example.com/hooks/cpanel-backup"
```

Summary body sent to email/Slack/webhook:

```
cpanel-auto-backup SUCCESS
host     : web01.example.com
date     : Fri Apr 17 02:24:33 UTC 2026
duration : 541s
artifacts: 18
size     : 28G
path     : /backup/cpanel/2026-04-17_021500
log      : /var/log/cpanel-auto-backup/backup-20260417-021500.log
```

## Verifying a backup

Every artifact that ends up in the manifest can be checked with one command:

```bash
sudo ./scripts/verify.sh /backup/cpanel/2026-04-17_021500
```

It walks `manifest.tsv`, gunzip-tests every `*.gz` / `*.sql.gz`, `tar -tzf`s every `*.tar.gz`, and prints a `[ OK ]` / `[FAIL]` per artifact. Exits non-zero if anything fails — drop it in a cron or monitoring hook.

## Restoring a backup

**Single account** (recommended — uses cPanel's own `restorepkg`):

```bash
sudo ./scripts/restore-account.sh /backup/cpanel/2026-04-17_021500/accounts/cpmove-alice.tar.gz
# or by name:
sudo ./scripts/restore-account.sh --user alice /backup/cpanel/2026-04-17_021500
```

**Single database:**

```bash
gunzip -c /backup/cpanel/2026-04-17_021500/databases/alice_wp.sql.gz \
  | mysql --defaults-file=/root/.my.cnf
```

**System config**: extract selectively — don't blindly over-write a running server.

```bash
mkdir /tmp/restore
tar -xzf /backup/cpanel/2026-04-17_021500/system/system-config.tar.gz -C /tmp/restore
# pick what you need from /tmp/restore/etc, /tmp/restore/root, /tmp/restore/var/cpanel
```

Full runbooks for bare-metal and same-server restores: [docs/RESTORE.md](docs/RESTORE.md).

## Logs

```
/var/log/cpanel-auto-backup/
├── backup-20260417-021500.log        ← this night's run
├── backup-20260416-021500.log
└── backup-20260415-021500.log
```

Every run creates a dedicated timestamped file. There is no log rotation built-in — the logs are small (typically < 1 MB) and are covered by the backup's own retention policy via the `system` tarball if you ever need to audit older runs.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `pkgacct: command not found` | cPanel not installed, or script run on wrong host | Run on the cPanel server as root |
| `Cannot connect to MySQL` | No `/root/.my.cnf` or wrong credentials | Create `/root/.my.cnf` with `[client]` block, `chmod 600` |
| `mysqldump: Error: Access denied … for user 'root'@'localhost'` | MariaDB's `unix_socket` plugin vs TCP | Either run as root (so unix_socket works) or add an explicit password in `/root/.my.cnf` |
| `Insufficient free space on /backup/cpanel` | `RETENTION_DAYS` too high | Lower retention, or mount a bigger volume at `BACKUP_ROOT` |
| `rsync: ssh: Permission denied (publickey)` | SSH key not authorised on remote | Re-run `ssh-copy-id backup@nas.example.com` |
| `aws: command not found` | AWS CLI missing | `dnf install python3-pip && pip3 install awscli` |
| Silent cron failures | Cron's empty `PATH` / missing env | The installed cron entry already sets `PATH`; if you write your own, copy it verbatim |

Deeper troubleshooting with actual log excerpts: [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).

## FAQ

**Is this incremental?** No — every run is a full dump. If you need block-level or incremental, use JetBackup / R1Soft / restic alongside this.

**How long does a run take?** Roughly `5–15 minutes per 100 GB` of account data on modern NVMe, plus upload bandwidth time. Accounts are packaged sequentially (pkgacct is IO-heavy; parallelism usually doesn't help).

**Can I exclude `/home/*/logs`?** pkgacct respects `BACKUP_SKIP_LOGS=1` in `backup.conf` — logs are skipped by default.

**Does it work on WHM resellers?** Yes — any account listed under `/var/cpanel/users` is picked up, including resold ones.

**What happens if a backup is interrupted?** The current timestamped directory stays partial. The next successful run leaves it behind (it doesn't match the "kept" set), and rotation cleans it up on the following night. You can delete it manually at any time.

**Can I encrypt the backups at rest?** Not built-in; either (a) mount an encrypted volume at `BACKUP_ROOT`, or (b) set `REMOTE_DRIVER=s3` with an AES-256-encrypted bucket. Client-side encryption is on the roadmap.

More: [docs/FAQ.md](docs/FAQ.md).

## Project layout

```
cpanel-auto-backup/
├── backup-cpanel.sh                    # entry point
├── lib/
│   ├── common.sh                       # logging, helpers, pre-flight
│   ├── accounts.sh                     # per-account pkgacct
│   ├── databases.sh                    # mysqldump + grants
│   ├── system.sh                       # /etc, /root, manifest
│   ├── rotation.sh                     # retention policy
│   ├── remote.sh                       # rsync / S3 / SFTP upload
│   └── notify.sh                       # email / Slack / webhook
├── scripts/
│   ├── install.sh                      # installer (supports curl|bash)
│   ├── verify.sh                       # verify a backup directory
│   └── restore-account.sh              # restore one account via restorepkg
├── config/
│   └── backup.conf.example             # fully commented template
├── docs/
│   ├── USAGE.md, INSTALL.md, CONFIG.md
│   ├── CRON.md, REMOTE.md, RESTORE.md
│   ├── TROUBLESHOOTING.md, FAQ.md
│   └── CONTRIBUTING.md
├── .github/workflows/shellcheck.yml    # CI
├── CHANGELOG.md
├── LICENSE
├── Makefile
├── README.md                           # ← you are here
└── SECURITY.md
```

## Contributing

PRs welcome. See [docs/CONTRIBUTING.md](docs/CONTRIBUTING.md). The CI gate is simply ShellCheck-clean at `warning` severity on every `.sh`.

## Security

Found a vulnerability (e.g. a way to trick the script into reading/writing outside `BACKUP_ROOT`)? Please **don't** open a public issue. See [SECURITY.md](SECURITY.md) for how to report privately.

## License

[MIT](./LICENSE). Use it, fork it, sell it, just don't blame me if you don't test your restores.
