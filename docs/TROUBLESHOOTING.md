# Troubleshooting

Every error we've seen in real runs, with the root cause and the fix. Use the log file first — it's usually the fastest answer.

```bash
ls -1tr /var/log/cpanel-auto-backup/ | tail -3
sudo less /var/log/cpanel-auto-backup/backup-<latest>.log
```

## Contents

- [General diagnostic steps](#general-diagnostic-steps)
- [Pre-flight / startup](#pre-flight--startup)
- [Accounts phase (pkgacct)](#accounts-phase-pkgacct)
- [Databases phase (mysqldump)](#databases-phase-mysqldump)
- [System phase (tar)](#system-phase-tar)
- [Upload phase](#upload-phase)
- [Rotation phase](#rotation-phase)
- [Cron runs silently do nothing](#cron-runs-silently-do-nothing)
- [Notifications not firing](#notifications-not-firing)
- [Collecting a support bundle](#collecting-a-support-bundle)

## General diagnostic steps

```bash
# 1. Version and config sanity:
sudo cpanel-auto-backup --version
sudo bash -n /etc/cpanel-auto-backup/backup.conf

# 2. Dry-run: exercises every path without writing:
sudo cpanel-auto-backup --dry-run --verbose 2>&1 | tee /tmp/dry-run.log

# 3. Most recent real-run log:
sudo ls -1tr /var/log/cpanel-auto-backup/ | tail -1
```

## Pre-flight / startup

### `This script must be run as root`

Run with `sudo`. The script needs root to read `/var/cpanel/users`, run `pkgacct`, read SSH keys, and write under `/backup`.

### `Config file not found: /etc/cpanel-auto-backup/backup.conf`

Either copy the template:

```bash
sudo cp /opt/cpanel-auto-backup/config/backup.conf.example /etc/cpanel-auto-backup/backup.conf
sudo chmod 600 /etc/cpanel-auto-backup/backup.conf
```

…or pass your own: `--config /path/to/your.conf`.

### `cPanel not detected at /usr/local/cpanel`

You're on the wrong server, or cPanel is uninstalled/broken. If you only want databases or system config without cPanel:

```bash
sudo cpanel-auto-backup --force --databases-only
sudo cpanel-auto-backup --force --system-only
```

### `Insufficient free space on /backup/cpanel: 512MB free, need 1024MB`

Either make room, move `BACKUP_ROOT` to a bigger volume, or lower retention:

```bash
# Quickest fix: delete a couple of old runs.
sudo rm -rf /backup/cpanel/2026-04-10_021500

# Permanent: mount a bigger volume at /backup.
```

## Accounts phase (pkgacct)

### `pkgacct failed for alice (see …)`

The log usually contains the actual pkgacct error above the summary. Common causes:

- **Disk full in `/home` or `/tmp`** — pkgacct builds the tarball in a temp dir first.
- **Corrupt MySQL grants or dropped user DB** — run `whmapi1 listaccts search=alice` and confirm the user still exists.
- **A hook script failing** — cPanel's `scripts/prepkgacct`/`postpkgacct` custom hooks can abort the run. Check `/usr/local/cpanel/3rdparty/mailman/post-pkgacct` and similar.

Retry just that user:

```bash
sudo /usr/local/cpanel/scripts/pkgacct alice /tmp
```

### `No cPanel accounts found at /var/cpanel/users`

The server has no cPanel accounts. If that's intentional, set `MODE` to `databases` or `system` (via CLI flag).

### `pkgacct exited 0 but cpmove-alice.tar.gz not found`

pkgacct wrote the tarball to a different path than we expect. Check where it actually went:

```bash
sudo find / -name 'cpmove-alice.tar.gz' -mmin -60 2>/dev/null
```

Most common cause: a `/etc/cpupdate.conf` tweak that changes the default pkgacct working directory. File an issue with the output of `cat /etc/cpupdate.conf`.

## Databases phase (mysqldump)

### `Cannot connect to MySQL`

Create `/root/.my.cnf`:

```ini
[client]
user=root
password=your-secure-password
```

```bash
sudo chmod 600 /root/.my.cnf
```

Test:

```bash
sudo mysql -e 'SELECT 1'
```

### `mysqldump: Error: Access denied … SHOW VIEW`

The MySQL root user lacks `SHOW VIEW` or `LOCK TABLES` on one of the schemas — rare, but happens after cPanel version upgrades. Run:

```bash
sudo mysql -e "GRANT ALL ON *.* TO 'root'@'localhost' WITH GRANT OPTION; FLUSH PRIVILEGES;"
```

### `mysqldump … Got error: 1556: You can't use locks with log tables`

One or more `mysql.*` internal tables are in the dump list. Add them to the skip filter in `lib/databases.sh` `list_databases`, or exclude at the mysqldump level with `--ignore-table=schema.table`.

### Dump is empty (0 bytes) and removed

`mysqldump` ran but emitted nothing. Verify the database actually has tables:

```bash
sudo mysql -e 'SHOW TABLES' alice_wp
```

If the schema is empty, that's working as designed — empty dumps are deleted.

## System phase (tar)

### `tar: /etc/shadow.cache: Cannot open: Permission denied`

Running without root (rare but possible via `sudo -u`). Make sure the script is invoked by the real root, not a sudo-to-non-root proxy.

### `tar: file changed as we read it`

Something in `/etc` changed mid-archive. Non-fatal — tar still produced a valid archive, just with a warning. Common for files like `/etc/shadow` being rewritten by `passwd`. Ignore if it only affects non-critical files.

## Upload phase

### `rsync: ssh: Permission denied (publickey)`

The SSH key isn't authorised on the remote:

```bash
sudo ssh -v -i /root/.ssh/id_rsa backup@nas.example.com 'true'
# Look for "Offering public key" / "Authentication succeeded"
sudo ssh-copy-id -i /root/.ssh/id_rsa.pub backup@nas.example.com
```

### `rsync: connection unexpectedly closed`

Usually the remote's `~/.ssh/authorized_keys` has a `command=...` restriction that blocks the destination path. Temporarily remove it to test:

```bash
# On the remote backup user:
# Comment out the command= prefix in authorized_keys and retry.
```

### `aws: command not found`

```bash
sudo dnf install -y python3-pip
sudo pip3 install awscli
```

### `aws s3 sync … An error occurred (AccessDenied)`

The IAM key lacks `s3:PutObject` on that prefix. See [REMOTE.md IAM policy](REMOTE.md#iam-policy-aws).

### `aws s3 sync … SignatureDoesNotMatch`

Clock skew. Check NTP:

```bash
timedatectl status
sudo systemctl status chronyd
```

### `lftp: Login failed`

Wrong password or key. Re-verify manually:

```bash
sudo lftp -u backup sftp://backup.example.com
```

## Rotation phase

### `Refusing to delete non-backup dir: /some/path`

Defensive guard kicked in — the candidate directory isn't under `BACKUP_ROOT` or doesn't match the `YYYY-MM-DD_HHMMSS` pattern. This is **intentional** and means something manual landed in your `BACKUP_ROOT`. Investigate and delete by hand if safe:

```bash
sudo ls -la /backup/cpanel/
sudo rm -rf /backup/cpanel/misc-file-you-left-there
```

### Rotation left more backups than expected

Rotation keeps the **union** of daily + weekly + monthly rules. With `RETENTION_DAYS=7`, `WEEKLY=4`, `MONTHLY=12` you can easily have 15+ kept if the dates don't overlap. That's correct behaviour.

## Cron runs silently do nothing

Check that cron actually fired:

```bash
sudo grep cpanel-auto-backup /var/log/cron | tail
```

If nothing there, the cron file has a syntax error:

```bash
sudo crontab -l -u root
cat /etc/cron.d/cpanel-auto-backup
```

If cron fires but nothing happens:

- The `PATH` in the cron file doesn't include `/usr/local/sbin` — use the default shipped entry verbatim.
- `/usr/local/sbin/cpanel-auto-backup` is a dangling symlink after an upgrade — `ls -l /usr/local/sbin/cpanel-auto-backup`.

## Notifications not firing

```bash
# Is NOTIFY_ON set correctly?
grep NOTIFY_ON /etc/cpanel-auto-backup/backup.conf

# Is an MTA installed?
which mail sendmail

# Can the server actually send mail?
echo 'test' | mail -s 'test' you@example.com
```

For Slack / webhooks, re-run with `--verbose` and look for the `curl` line in the log:

```bash
sudo tail -50 /var/log/cpanel-auto-backup/backup-*.log | grep -i slack
```

## Collecting a support bundle

When filing an issue:

```bash
sudo tar czf /tmp/cpanel-auto-backup-debug.tar.gz \
    /etc/cpanel-auto-backup/backup.conf \
    /etc/cron.d/cpanel-auto-backup \
    /var/log/cpanel-auto-backup/backup-*.log \
    /opt/cpanel-auto-backup/CHANGELOG.md
```

**Redact the credentials** (`REMOTE_*`, `AWS_SECRET_*`, any webhook URLs) from `backup.conf` before attaching.
