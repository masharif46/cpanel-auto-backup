# Scheduling

Patterns for running the backup from cron on a live server.

## Contents

- [Default: nightly 02:15](#default-nightly-0215)
- [Custom times](#custom-times)
- [Twice daily: dbs at 01:00, full at 02:30](#twice-daily-dbs-at-0100-full-at-0230)
- [Off-peak only](#off-peak-only)
- [Skip-if-already-running (concurrency guard)](#skip-if-already-running-concurrency-guard)
- [Load-aware scheduling](#load-aware-scheduling)
- [Disabling the nightly](#disabling-the-nightly)
- [Systemd timers instead of cron](#systemd-timers-instead-of-cron)

## Default: nightly 02:15

The installer drops this file:

```bash
# /etc/cron.d/cpanel-auto-backup
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
15 2 * * * root /usr/local/sbin/cpanel-auto-backup --config /etc/cpanel-auto-backup/backup.conf >/dev/null 2>&1
```

Two reasons the PATH is set explicitly:

1. cron's default `PATH=/usr/bin:/bin` omits `/usr/local/sbin`.
2. `pkgacct` lives at `/usr/local/cpanel/scripts/pkgacct`, so cron can only find it via PATH.

## Custom times

Edit `/etc/cron.d/cpanel-auto-backup`:

```cron
# Every night at 03:30
30 3 * * * root /usr/local/sbin/cpanel-auto-backup

# Weekdays only, 04:00
0 4 * * 1-5 root /usr/local/sbin/cpanel-auto-backup

# Sundays at 01:00 (weekly-only policy)
0 1 * * 0 root /usr/local/sbin/cpanel-auto-backup
```

## Twice daily: dbs at 01:00, full at 02:30

Useful when the application writes a lot and an extra 12-hour-old DB copy matters:

```cron
# Databases only at 01:00 — quick, small, non-blocking.
0  1 * * * root /usr/local/sbin/cpanel-auto-backup --databases-only --no-upload

# Full account + system + upload at 02:30.
30 2 * * * root /usr/local/sbin/cpanel-auto-backup
```

Both runs share the same `BACKUP_ROOT`; the DB-only snapshot just gets its own timestamped directory.

## Off-peak only

For international traffic with no single quiet window, stagger per server:

```cron
# Server in UTC+0:  01:15 UTC (peak is 14:00 UTC)
15 1 * * * root /usr/local/sbin/cpanel-auto-backup

# Server in UTC+8:  17:15 UTC = 01:15 local
15 17 * * * root /usr/local/sbin/cpanel-auto-backup
```

Note that `pkgacct` reads `/home/<user>` serially, so the backup's real cost is **disk IO** during the accounts phase. Schedule it when your disk is idle, not when your network is idle.

## Skip-if-already-running (concurrency guard)

The script does not take its own lock. Wrap with `flock` if you're worried about one run spilling into the next:

```cron
15 2 * * * root /usr/bin/flock -n /var/run/cpanel-auto-backup.lock \
    /usr/local/sbin/cpanel-auto-backup >/dev/null 2>&1
```

`-n` = non-blocking; a second invocation exits immediately if the first is still running.

## Load-aware scheduling

Use `nice` + `ionice` to make the backup yield to real traffic:

```cron
15 2 * * * root /usr/bin/nice -n 19 /usr/bin/ionice -c3 \
    /usr/local/sbin/cpanel-auto-backup >/dev/null 2>&1
```

- `nice -n 19` — lowest CPU priority
- `ionice -c3` — idle-class disk scheduling: only runs when nothing else wants the disk

Takes ~2× longer but won't hurt production latency.

## Disabling the nightly

```bash
sudo rm /etc/cron.d/cpanel-auto-backup
```

Or comment out the line. Cron picks up the change immediately — no reload required.

## Systemd timers instead of cron

Some operators prefer timers. The equivalent of the default cron entry:

```ini
# /etc/systemd/system/cpanel-auto-backup.service
[Unit]
Description=cPanel Auto Backup
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
Nice=19
IOSchedulingClass=idle
ExecStart=/usr/local/sbin/cpanel-auto-backup --config /etc/cpanel-auto-backup/backup.conf
```

```ini
# /etc/systemd/system/cpanel-auto-backup.timer
[Unit]
Description=cPanel Auto Backup — nightly

[Timer]
OnCalendar=*-*-* 02:15:00
Persistent=true      # run a missed backup after boot
RandomizedDelaySec=5m

[Install]
WantedBy=timers.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now cpanel-auto-backup.timer
sudo systemctl list-timers cpanel-auto-backup.timer
```

Remove the cron entry if you switch:

```bash
sudo rm /etc/cron.d/cpanel-auto-backup
```
