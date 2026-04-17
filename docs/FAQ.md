# FAQ

## Contents

- [General](#general)
- [Scope & design](#scope--design)
- [Operations](#operations)
- [Security](#security)
- [Comparison to other tools](#comparison-to-other-tools)

## General

### Is this incremental or differential?

Neither — every run is a **full** dump. This is a deliberate choice: each timestamped directory under `BACKUP_ROOT` is completely self-contained, so restoring one night's data never depends on another night's data being intact. If you need block-level / incremental, use JetBackup, R1Soft, or restic **in addition** to this.

### Does it run on the cPanel server itself, or a separate box?

**On the cPanel server itself.** It needs root access to `/var/cpanel`, `/usr/local/cpanel/scripts/pkgacct`, the MySQL socket, and SSH keys in `/root/.ssh`. A remote puller wouldn't work without making those accessible anyway.

### Is this official from cPanel?

No — this is a community tool. We use cPanel's official `pkgacct` and `restorepkg` under the hood, but the orchestrator / rotation / remote upload glue is ours.

### Which cPanel versions are supported?

Anything that ships `pkgacct` in the standard location — cPanel 11.x through current (~134.x at time of writing). `pkgacct`'s CLI flags have been stable for years.

### What OSes are supported?

Primary: AlmaLinux 9. Should work unchanged on RHEL 9, Rocky 9, and the CloudLinux 9 family. AlmaLinux 8 / CentOS 7 need no code changes but are not CI-tested.

## Scope & design

### Why not Python / Go?

Because:

- It's a system-admin script that runs as root on a production cPanel box. Bash is the lowest-friction install — no runtime, no venv, no `pip`.
- Every piece of heavy lifting (`pkgacct`, `mysqldump`, `tar`, `rsync`, `aws`) is an external binary we shell out to. A higher-level language would just wrap the same calls with more moving parts.
- It's ~1,500 lines of shell. If it were 15,000, Go would win.

### Why not use WHM's "Backup Configuration"?

WHM's built-in backup is excellent but:

- The UI-driven config is harder to version-control than a single `backup.conf`.
- Restore flexibility is more limited (the backups aren't plain `cpmove-*.tar.gz`).
- No first-class S3-compatible endpoint support (Wasabi, MinIO, B2 S3 gateway).
- Notifications are email-only.

If WHM's native backup meets your needs, use it. This tool exists for operators who want a simpler, more transparent, script-driven alternative.

### Can I run this from a cron on a non-cPanel box?

No — pkgacct only runs on the cPanel server. If you want a "pull" model, set up passwordless SSH from your backup box and either:

1. Run this tool on the cPanel server and use `REMOTE_DRIVER=rsync` with your backup box as the target; or
2. Write your own puller that `ssh`s in and runs `cpanel-auto-backup --no-upload`, then `rsync`s the resulting directory back.

## Operations

### How long does a run take?

Dominated by the accounts phase. Rough guide on modern NVMe:

- **5–10 minutes** per 100 GB of account data (pkgacct is single-threaded per account).
- **~30 seconds** per GB for MySQL dumps.
- **seconds** for the system tarball.
- **Upload** is whatever your link can push.

A server with 300 GB across 20 accounts typically takes 30–60 minutes end-to-end.

### How much disk does one backup take?

Typically 40–60% of the raw data size after gzip. A server with 200 GB of files usually ends up with a ~100 GB backup directory.

### Does it lock databases during dumps?

No — `mysqldump --single-transaction --quick` takes a consistent snapshot via InnoDB's MVCC. Writers keep going. The only tables that get briefly locked are MyISAM, which is rare on modern cPanel installs.

### Can I back up only accounts under a specific reseller?

Not via `INCLUDE_ACCOUNTS` directly, but easy to script:

```bash
INCLUDE_ACCOUNTS=$(whmapi1 listaccts searchtype=owner search=acme \
                    | grep -oP '(?<=user: )\S+' | xargs)
sudo cpanel-auto-backup --config <(sed "s|^INCLUDE_ACCOUNTS=.*|INCLUDE_ACCOUNTS=\"${INCLUDE_ACCOUNTS}\"|" \
                                   /etc/cpanel-auto-backup/backup.conf)
```

### How do I test a restore without touching production?

Spin up a VM with the same cPanel version, copy the backup directory to it, and run the restore. This is the only reliable way to confirm your backups work — test it quarterly.

### What happens if the script is killed mid-run?

The current `YYYY-MM-DD_HHMMSS` directory is left partial, with whatever was written up to the kill point. The next nightly run starts fresh in a new directory, and rotation eventually cleans the partial one up (or you can `rm -rf` it immediately).

## Security

### Who can read the backups?

By default, only root. `BACKUP_ROOT`, `LOG_DIR`, and `backup.conf` are all `0700` / `0600`. Backups do **not** go to world-readable paths.

### The tarballs contain customer emails / password hashes. Is that a problem?

The per-account tarballs contain everything in the user's `$HOME`, their Maildir, their database contents, and cPanel's copy of their account metadata (which does not include the login password in plaintext, but does include password hashes that could be cracked). Treat the backup directory and any remote copy as **as sensitive as the server itself**:

- Store on encrypted media.
- Restrict SSH / S3 IAM access to backup users to the backup prefix only.
- If using cloud storage, require bucket-level encryption + MFA-delete.

### Can I encrypt the backups at rest before upload?

Not built-in today. Workarounds:

- **S3**: enable server-side encryption (SSE-S3 or SSE-KMS) on the bucket — transparent.
- **rsync target**: put the backup directory on a LUKS-encrypted volume on the remote.
- **End-to-end**: pipe through `gpg` or `age` by wrapping each artifact — needs code changes; PR welcome.

Client-side encryption is on the roadmap (see [CHANGELOG.md](../CHANGELOG.md)).

### What about prompt-for-password secrets?

Everything is designed to run non-interactively from cron. Put credentials in:

- `/root/.my.cnf` — MySQL
- `/root/.aws/credentials` — AWS
- `/root/.ssh/id_rsa` — SSH (rsync, SFTP)

Those files are root-owned `0600` and not stored in the tool's config.

## Comparison to other tools

| Feature | this tool | WHM native | JetBackup | restic |
|---|---|---|---|---|
| cPanel-native restore format (cpmove) | ✅ | ✅ | ✅ | ❌ (blob-level only) |
| Incremental | ❌ | ❌ | ✅ | ✅ |
| S3 / Wasabi / B2 | ✅ | partial | ✅ | ✅ |
| SFTP | ✅ | ✅ | ✅ | ❌ |
| Client-side encryption | roadmap | ❌ | ✅ | ✅ |
| License cost | free (MIT) | free | paid | free |
| Scriptability | 100% — single config file + git-version'able | UI-centric | paid plugin | 100% |
| Complexity | one bash script tree | part of WHM | agent + UI + cron | specialised tool |

Use this tool when:

- You want clear, auditable Bash instead of a plugin ecosystem.
- You're comfortable with "one night = one full copy" in exchange for simplicity.
- You want the backups to be **bit-identical** to what `cPanel Transfer Tool` produces, so restores to another server are trivial.
