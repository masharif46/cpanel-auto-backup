---
name: Bug report
about: Something isn't working
title: "bug: "
labels: bug
---

## Summary

One-sentence description of what's wrong.

## Environment

- `cpanel-auto-backup --version`:
- OS / release (e.g. AlmaLinux 9.7):
- cPanel version (`/usr/local/cpanel/cpanel -V`):
- Invocation (cron / manual / flags used):

## What you did

Exact commands, in order:

```bash
sudo cpanel-auto-backup --dry-run
```

## What you expected

## What actually happened

## Relevant log excerpt

The last ~50 lines of `/var/log/cpanel-auto-backup/backup-<latest>.log`:

```
paste here
```

## Redacted backup.conf

Paste your `/etc/cpanel-auto-backup/backup.conf` with credentials removed
(anything starting with `REMOTE_*`, `AWS_*`, `*PASS*`, webhook URLs):

```bash
```

## Anything else?

Workarounds you tried, related upstream issues, etc.
