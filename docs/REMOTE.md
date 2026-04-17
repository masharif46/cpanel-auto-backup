# Remote storage

Detailed setup for each of the three upload drivers plus design notes.

## Contents

- [Choosing a driver](#choosing-a-driver)
- [rsync over SSH](#rsync-over-ssh)
- [S3 / S3-compatible](#s3--s3-compatible)
- [SFTP](#sftp)
- [Two-site replication](#two-site-replication)
- [Bandwidth throttling](#bandwidth-throttling)
- [Testing a target](#testing-a-target)

## Choosing a driver

| Driver | Pick it if… | Avoid if… |
|---|---|---|
| `rsync` | You have a dedicated backup server or NAS with SSH access. | Your only remote is an S3 bucket or SFTP-only account. |
| `s3` | You want off-site durable cloud storage, lifecycle policies, and near-infinite scale. | You're on a tight budget and only have one other on-prem box. |
| `sftp` | Your managed hosting plan only offers SFTP. | You have rsync access — `rsync` is always faster and more restartable than SFTP. |
| `none` | You're mirroring `${BACKUP_ROOT}` via some other mechanism (block-level snapshots, ZFS send, etc.). | — |

All three drivers operate on the current run's timestamped directory **after** it's fully written locally. If upload fails, the local copy stays put and the next nightly will try again on the new directory.

## rsync over SSH

### Config

```bash
REMOTE_DRIVER="rsync"
REMOTE_RSYNC_TARGET="backup@nas.example.com:/srv/backups/cpanel"
REMOTE_RSYNC_SSH_KEY="/root/.ssh/id_rsa"
# Optional extra options:
REMOTE_RSYNC_OPTS="--bwlimit=20000"
```

### Key-based auth

On the cPanel server:

```bash
# Create a dedicated key, no passphrase (cron-safe).
sudo ssh-keygen -t ed25519 -f /root/.ssh/cpanel-backup -N ''
sudo chmod 600 /root/.ssh/cpanel-backup

# Push it to the remote:
sudo ssh-copy-id -i /root/.ssh/cpanel-backup.pub backup@nas.example.com

# Verify:
sudo ssh -i /root/.ssh/cpanel-backup backup@nas.example.com 'echo ok'
```

Point `REMOTE_RSYNC_SSH_KEY` at `/root/.ssh/cpanel-backup`.

### Locking down the remote account

On the NAS / backup server, restrict the `backup` user to rsync-into-one-dir:

```bash
# /home/backup/.ssh/authorized_keys
command="rsync --server -vlogDtpre.iLsfxC . /srv/backups/cpanel/",no-agent-forwarding,no-port-forwarding,no-pty,no-user-rc,no-X11-forwarding ssh-ed25519 AAAA...
```

Or put the user in a chroot with an `rrsync` wrapper — see `man rrsync`.

### Tuning

```bash
# Saturate a gigabit link:
REMOTE_RSYNC_OPTS="--compress-choice=none"

# Rate-limit to 20 MB/s:
REMOTE_RSYNC_OPTS="--bwlimit=20000"

# Resume better on flaky links:
REMOTE_RSYNC_OPTS="--partial --append-verify"
```

## S3 / S3-compatible

### Install the AWS CLI

```bash
sudo dnf install -y python3-pip
sudo pip3 install awscli
aws --version
```

### Credentials

Preferred: root-only `~/.aws/credentials`:

```ini
[default]
aws_access_key_id = AKIA...
aws_secret_access_key = ...
region = us-east-1
```

```bash
sudo chmod 600 /root/.aws/credentials
```

Alternative: put them directly in `backup.conf` (exported before the `aws` invocation):

```bash
export AWS_ACCESS_KEY_ID="AKIA..."
export AWS_SECRET_ACCESS_KEY="..."
export AWS_DEFAULT_REGION="us-east-1"
```

### Config

```bash
REMOTE_DRIVER="s3"
REMOTE_S3_BUCKET="my-backup-bucket"
REMOTE_S3_PREFIX="cpanel-backups/web01"
REMOTE_S3_SC="STANDARD_IA"            # STANDARD, STANDARD_IA, GLACIER, DEEP_ARCHIVE
# Non-AWS providers:
# REMOTE_S3_ENDPOINT="https://s3.us-west-1.wasabisys.com"
```

### IAM policy (AWS)

Minimum permissions the access key needs on the bucket:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:GetObject", "s3:DeleteObject", "s3:AbortMultipartUpload"],
      "Resource": "arn:aws:s3:::my-backup-bucket/cpanel-backups/*"
    },
    {
      "Effect": "Allow",
      "Action": ["s3:ListBucket"],
      "Resource": "arn:aws:s3:::my-backup-bucket"
    }
  ]
}
```

### Lifecycle rules (recommended)

In the S3 console, add a lifecycle rule on the `cpanel-backups/` prefix:

- Transition to `STANDARD_IA` after 0 days
- Transition to `GLACIER` after 30 days
- Expire after 365 days

This replaces the tool's own rotation for the S3 side — let AWS do it cheaper.

### Provider-specific endpoints

| Provider | `REMOTE_S3_ENDPOINT` |
|---|---|
| AWS | *(leave empty)* |
| Wasabi (us-west-1) | `https://s3.us-west-1.wasabisys.com` |
| Backblaze B2 (S3 gateway) | `https://s3.us-east-005.backblazeb2.com` |
| DigitalOcean Spaces | `https://nyc3.digitaloceanspaces.com` |
| MinIO (self-hosted) | `https://minio.internal:9000` |

## SFTP

### Install lftp

```bash
sudo dnf install -y lftp
```

### Config — key auth

```bash
REMOTE_DRIVER="sftp"
REMOTE_SFTP_HOST="backup.example.com"
REMOTE_SFTP_PORT=22
REMOTE_SFTP_USER="backup"
REMOTE_SFTP_SSH_KEY="/root/.ssh/id_rsa"
REMOTE_SFTP_PATH="/srv/backups/cpanel"
```

### Config — password auth (not recommended)

```bash
REMOTE_DRIVER="sftp"
REMOTE_SFTP_HOST="backup.example.com"
REMOTE_SFTP_PORT=22
REMOTE_SFTP_USER="backup"
REMOTE_SFTP_PASS="replace-with-real-password"
REMOTE_SFTP_PATH="/srv/backups/cpanel"
```

Prefer keys. If you must use a password, make sure `backup.conf` is `chmod 600` and `chown root:root`.

## Two-site replication

Run two nightlies, one per destination. Point each at its own config:

```cron
# 02:15 — primary off-site (rsync to NAS)
15 2 * * * root /usr/local/sbin/cpanel-auto-backup --config /etc/cpanel-auto-backup/backup.conf

# 03:30 — secondary to S3 (system-only, no pkgacct re-run)
30 3 * * * root /usr/local/sbin/cpanel-auto-backup \
    --config /etc/cpanel-auto-backup/backup-s3.conf \
    --system-only --no-upload
```

Or more commonly: one local + remote run, then a secondary `aws s3 sync` / `rsync` step that copies the newest `BACKUP_ROOT` directory to the second destination.

## Bandwidth throttling

| Driver | Throttle |
|---|---|
| rsync | `REMOTE_RSYNC_OPTS="--bwlimit=20000"`  (KB/s) |
| aws s3 | No native throttle. Put the backup server on a shaped network interface or use [trickle](https://github.com/mariusae/trickle). |
| lftp (sftp) | Add `set net:limit-rate 20M` to lftp config, e.g. `/root/.lftprc` |

## Testing a target

Before enabling nightlies, prove the upload path works on a tiny run:

```bash
# Generate a minimal backup (system manifest is ~1MB):
sudo cpanel-auto-backup --system-only

# Then inspect the log for the PHASE 5/6 block and confirm it reports:
#   "rsync upload complete" / "S3 upload complete" / "SFTP upload complete"
sudo tail -80 /var/log/cpanel-auto-backup/backup-*.log
```

If it fails, temporarily re-run with `--verbose` to see the exact shell command.
