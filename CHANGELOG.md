# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0] - 2026-04-17

### Added
- Initial public release.
- Main orchestrator `backup-cpanel.sh` with a 6-phase run:
  pre-flight → accounts → databases → system → upload → rotation.
- Library modules: `common.sh`, `accounts.sh`, `databases.sh`,
  `system.sh`, `rotation.sh`, `remote.sh`, `notify.sh`.
- Per-account backups via cPanel's official `pkgacct` producing
  `cpmove-<user>.tar.gz` that restores cleanly on any cPanel server.
- Full MySQL / MariaDB dumps with `--single-transaction --routines
  --triggers --events`, plus a users + grants snapshot for fresh-box
  restores.
- System config tarball: `/etc`, `/root`, `/var/cpanel`,
  `/var/spool/cron` with ACLs + xattrs preserved.
- System manifest: installed packages, enabled services, kernel and
  OS release, cPanel version.
- Manifest TSV listing every artifact, driving the verify and restore
  tooling.
- Retention with daily + weekly (ISO) + monthly rules. Safeguard that
  refuses to delete anything not under `BACKUP_ROOT` matching the
  timestamp pattern.
- Remote upload drivers: `rsync`, `s3` (AWS + any S3-compatible via
  `REMOTE_S3_ENDPOINT`), `sftp` (via lftp), `none`.
- Notifications: email (`mail`/`sendmail`), Slack webhook, generic
  JSON webhook. Configurable via `NOTIFY_ON=success|failure|always`.
- Installer `scripts/install.sh` supporting both local-checkout and
  `curl | bash`, with optional nightly cron (`--cron` / `--no-cron`).
- Verifier `scripts/verify.sh` that walks the manifest and gunzip/tar
  tests every artifact.
- Restorer `scripts/restore-account.sh` wrapping cPanel's `restorepkg`.
- Fully commented `config/backup.conf.example`.
- Documentation: `README.md`, `INSTALL.md`, `USAGE.md`, `CONFIG.md`,
  `CRON.md`, `REMOTE.md`, `RESTORE.md`, `TROUBLESHOOTING.md`, `FAQ.md`,
  `CONTRIBUTING.md`, `SECURITY.md`.
- ShellCheck GitHub Actions workflow.
- MIT license.

### Known issues
- Client-side encryption not yet supported. Use encrypted volumes or
  server-side bucket encryption for now.
- `pkgacct` is single-threaded per account. Large servers with many
  heavy accounts may want to run with a narrower `INCLUDE_ACCOUNTS`
  filter in separate cron entries for parallelism.
