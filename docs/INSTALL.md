# Install

This page covers every install path, what it actually changes on disk, and how to upgrade and uninstall. For the 5-minute happy path, see the [Quick start](../README.md#quick-start-5-minutes).

## Contents

- [System layout](#system-layout)
- [Install via installer script](#install-via-installer-script)
- [Install via curl | bash](#install-via-curl--bash)
- [Install manually from a git clone](#install-manually-from-a-git-clone)
- [Install on a non-standard layout](#install-on-a-non-standard-layout)
- [Verify the install](#verify-the-install)
- [Upgrade](#upgrade)
- [Uninstall](#uninstall)

## System layout

After install, these are all the paths the tool owns:

| Path | Purpose | Perms |
|---|---|---|
| `/opt/cpanel-auto-backup/` | The script tree (code) | `0755` |
| `/usr/local/sbin/cpanel-auto-backup` | Symlink to `backup-cpanel.sh` | symlink |
| `/etc/cpanel-auto-backup/backup.conf` | Your configuration | `0600` |
| `/var/log/cpanel-auto-backup/` | Per-run logs | `0700` |
| `/etc/cron.d/cpanel-auto-backup` | Optional nightly cron | `0644` |
| `${BACKUP_ROOT}` (e.g. `/backup/cpanel`) | Where backups land | `0700` |

## Install via installer script

From a local checkout — recommended when you want to review the code first:

```bash
git clone https://github.com/masharif46/cpanel-auto-backup.git
cd cpanel-auto-backup
sudo ./scripts/install.sh           # prompts before installing cron
sudo ./scripts/install.sh --cron    # install nightly cron, no prompt
sudo ./scripts/install.sh --no-cron # never install cron
```

## Install via curl | bash

```bash
curl -fsSL https://raw.githubusercontent.com/masharif46/cpanel-auto-backup/main/scripts/install.sh \
  | sudo bash -s -- --cron
```

The installer will `git clone` the repo into a temp dir, copy it to `/opt/cpanel-auto-backup`, and clean up. You need `git`, `tar`, `gzip`, `bash` present — all standard on AlmaLinux 9.

## Install manually from a git clone

If you'd rather not run the installer at all:

```bash
sudo mkdir -p /opt/cpanel-auto-backup /etc/cpanel-auto-backup /var/log/cpanel-auto-backup
sudo chmod 700 /etc/cpanel-auto-backup /var/log/cpanel-auto-backup

sudo git clone https://github.com/masharif46/cpanel-auto-backup.git /opt/cpanel-auto-backup
sudo chmod +x /opt/cpanel-auto-backup/backup-cpanel.sh /opt/cpanel-auto-backup/scripts/*.sh

sudo ln -s /opt/cpanel-auto-backup/backup-cpanel.sh /usr/local/sbin/cpanel-auto-backup

sudo cp /opt/cpanel-auto-backup/config/backup.conf.example /etc/cpanel-auto-backup/backup.conf
sudo chmod 600 /etc/cpanel-auto-backup/backup.conf
```

Optional cron:

```bash
sudo tee /etc/cron.d/cpanel-auto-backup >/dev/null <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
15 2 * * * root /usr/local/sbin/cpanel-auto-backup --config /etc/cpanel-auto-backup/backup.conf >/dev/null 2>&1
EOF
```

## Install on a non-standard layout

Everything is path-configurable via the single config file. To run from, say, `/srv/tools/backup`:

```bash
sudo mkdir -p /srv/tools /etc/cpanel-auto-backup
sudo git clone https://github.com/masharif46/cpanel-auto-backup.git /srv/tools/backup
sudo cp /srv/tools/backup/config/backup.conf.example /etc/cpanel-auto-backup/backup.conf
sudo ln -s /srv/tools/backup/backup-cpanel.sh /usr/local/sbin/cpanel-auto-backup
```

The script resolves its own `lib/` directory relative to its own location (`$(dirname "${BASH_SOURCE[0]}")/lib`), so symlinks work out of the box.

## Verify the install

```bash
# Version check (no side effects):
sudo cpanel-auto-backup --version

# Full dry-run — exercises every code path, writes nothing:
sudo cpanel-auto-backup --dry-run --verbose

# Cron entry present?
cat /etc/cron.d/cpanel-auto-backup

# Log dir writable?
sudo -u root test -w /var/log/cpanel-auto-backup && echo OK
```

A clean dry-run ends with the green "cPanel Auto Backup Complete" banner — no `[ERROR]` lines.

## Upgrade

If you installed via `git clone` into `/opt/cpanel-auto-backup`:

```bash
cd /opt/cpanel-auto-backup
sudo git pull --ff-only
```

Your `backup.conf` is in `/etc/cpanel-auto-backup/` so it won't be touched. After upgrade:

```bash
# Diff the template against your live config to pick up any new options:
diff -u /etc/cpanel-auto-backup/backup.conf \
        /opt/cpanel-auto-backup/config/backup.conf.example
```

See [CHANGELOG.md](../CHANGELOG.md) for breaking changes between versions.

## Uninstall

Nothing the tool writes lives outside these paths:

```bash
# Stop future runs:
sudo rm -f /etc/cron.d/cpanel-auto-backup

# Remove code + symlink + logs (keeps backups!):
sudo rm -rf /opt/cpanel-auto-backup
sudo rm -f  /usr/local/sbin/cpanel-auto-backup
sudo rm -rf /var/log/cpanel-auto-backup

# Remove config (contains credentials):
sudo rm -rf /etc/cpanel-auto-backup

# Delete the actual backups (only if you're sure):
sudo rm -rf /backup/cpanel
```
