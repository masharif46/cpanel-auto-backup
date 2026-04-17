# Security Policy

## Reporting a vulnerability

If you believe you've found a security issue in `cpanel-auto-backup` — for example:

- A way to trick the tool into reading or writing outside `BACKUP_ROOT`.
- A path that causes the tool to exfiltrate credentials to an unintended destination.
- A code-injection vector in the config loader, the rsync/S3/SFTP wrappers, or the notification senders.
- Any other issue where an attacker with less-than-root privilege could influence a root-level action the tool performs.

**Please do not open a public GitHub issue.** Instead, email the maintainer privately:

- **masharif46** — via the email address on [github.com/masharif46](https://github.com/masharif46)

Include:

1. A clear description of the issue.
2. The smallest reproducer you can produce (commands, config snippet, sample input).
3. The impact you believe it has (local privilege escalation, data exposure, etc.).

We'll respond within 7 days with an acknowledgement and an initial assessment. Coordinated disclosure: we'll work with you on a fix and a public advisory once a patched release is ready.

## Scope

**In scope**:

- The shell code in this repository.
- The installer script (`scripts/install.sh`).
- The way the tool handles configuration files, log files, and backup directories.

**Out of scope**:

- Vulnerabilities in cPanel itself (report to [cPanel Security](https://cpanel.net/security/)).
- Vulnerabilities in `rsync`, `aws` CLI, `lftp`, `mysqldump`, or other third-party binaries (report to the respective projects).
- Misconfiguration on the operator's side (e.g. running with a weak SSH key, leaving `backup.conf` world-readable).

## Supported versions

| Version | Supported |
|---|---|
| 1.x | ✅ |
| < 1.0 | ❌ (no prior releases) |

## Hardening recommendations for operators

Even without an exploitable bug, you can reduce blast radius:

1. **Run as root, not as an over-privileged service user.** The tool needs root for `pkgacct`; there's no benefit to giving any other account these powers.
2. **Chmod 600 / chown root:root** every file that holds credentials — `backup.conf`, `~/.my.cnf`, `~/.aws/credentials`, SSH private keys.
3. **Lock down the remote backup account.** For rsync/SFTP, restrict the key with `command=` / `rrsync` / a dedicated chroot. For S3, scope the IAM policy to the `cpanel-backups/` prefix only.
4. **Encrypt at rest.** LUKS on the local backup volume; server-side bucket encryption on S3; encrypted volume on the remote rsync target.
5. **Monitor** the log file size and exit codes. A series of zero-byte logs or non-zero exits means something's wrong.
6. **Test restores quarterly.** An un-restored backup is not a backup.
