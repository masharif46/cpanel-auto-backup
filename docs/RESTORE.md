# Restoring a backup

Three scenarios: **one account**, **one database**, or **the whole server (disaster recovery)**.

Every artifact produced by this tool is in a standard format — `tar.gz`, `sql.gz`, or plain text — so you can always restore by hand even if the helper scripts are gone.

## Contents

- [Before you start](#before-you-start)
- [Scenario 1: restore one cPanel account](#scenario-1-restore-one-cpanel-account)
- [Scenario 2: restore one database](#scenario-2-restore-one-database)
- [Scenario 3: disaster recovery (bare-metal rebuild)](#scenario-3-disaster-recovery-bare-metal-rebuild)
- [Partial restores](#partial-restores)
- [Verifying a restore](#verifying-a-restore)
- [Rollback](#rollback)

## Before you start

1. **Pick the correct backup directory.** Each has a full, self-contained run:
   ```bash
   ls -1tr /backup/cpanel
   # 2026-04-15_021500
   # 2026-04-16_021500
   # 2026-04-17_021500   ← most recent
   ```
2. **Verify it first:**
   ```bash
   sudo /opt/cpanel-auto-backup/scripts/verify.sh /backup/cpanel/2026-04-17_021500
   ```
   All `[ OK ]`? Proceed. Any `[FAIL]`? Pick the previous night and re-verify.
3. **Snapshot before you restore.** A restore is a write; take a fresh `cpanel-auto-backup --system-only` so you can undo if needed.

## Scenario 1: restore one cPanel account

This is the common case — someone deleted a site, a migration broke, or an account got hacked.

### Using the helper (recommended)

```bash
sudo /opt/cpanel-auto-backup/scripts/restore-account.sh \
    /backup/cpanel/2026-04-17_021500/accounts/cpmove-alice.tar.gz
```

The helper wraps cPanel's `/usr/local/cpanel/scripts/restorepkg`, which safely recreates the account + home + DBs + DNS + mail + SSL + subdomains.

If the account still exists, cPanel will prompt you to confirm overwrite.

### By hand (no helper)

```bash
# 1. Copy tarball to /home — restorepkg expects it there.
sudo cp /backup/cpanel/2026-04-17_021500/accounts/cpmove-alice.tar.gz /home/

# 2. Run cPanel's official restore.
sudo /usr/local/cpanel/scripts/restorepkg alice

# 3. Remove the staging copy.
sudo rm /home/cpmove-alice.tar.gz

# 4. Verify.
sudo /usr/local/cpanel/bin/whmapi1 listaccts search=alice
ls /home/alice
```

## Scenario 2: restore one database

If only a single database needs rollback:

```bash
# Drop the current (broken) database if desired — dangerous!
mysql -e 'DROP DATABASE alice_wp'

# Restore from dump.
gunzip -c /backup/cpanel/2026-04-17_021500/databases/alice_wp.sql.gz \
    | mysql --defaults-file=/root/.my.cnf
```

The `--add-drop-database` flag is baked into the dump, so restoring into an existing DB cleanly drops+recreates.

If you also need the user/grant:

```bash
grep -A1 "'alice'@" /backup/cpanel/2026-04-17_021500/databases/grants.sql | mysql
```

## Scenario 3: disaster recovery (bare-metal rebuild)

Your server is gone. You have a clean box with the same OS version and the backup directory downloaded to `/root/restore/`.

### 1. Install cPanel

```bash
cd /home
curl -o latest -L https://securedownloads.cpanel.net/latest
sh latest
# ~45 minutes
```

### 2. Apply system config

Do NOT blindly untar the system tarball over the new install. Extract it to a staging directory and cherry-pick:

```bash
mkdir -p /root/staged-restore
tar -xzf /root/restore/2026-04-17_021500/system/system-config.tar.gz \
    -C /root/staged-restore

# Review what's there:
ls /root/staged-restore/etc
ls /root/staged-restore/var/cpanel
```

Typical things worth copying back:

```bash
# /etc/hosts
sudo cp /root/staged-restore/etc/hosts /etc/hosts

# /etc/my.cnf + cPanel DB config
sudo cp /root/staged-restore/etc/my.cnf /etc/my.cnf

# SSH keys + root dotfiles
sudo cp -a /root/staged-restore/root/.ssh /root/
sudo cp /root/staged-restore/root/.my.cnf /root/

# yum/dnf repos (so custom packages come back on next dnf update)
sudo cp -a /root/staged-restore/etc/yum.repos.d/. /etc/yum.repos.d/

# Custom cPanel config
sudo cp -a /root/staged-restore/var/cpanel/. /var/cpanel/
```

Restart cPanel services after `/var/cpanel` changes:

```bash
sudo systemctl restart cpanel
```

### 3. Restore accounts

```bash
for tarball in /root/restore/2026-04-17_021500/accounts/cpmove-*.tar.gz; do
    sudo cp "${tarball}" /home/
    user=$(basename "${tarball}" .tar.gz); user="${user#cpmove-}"
    sudo /usr/local/cpanel/scripts/restorepkg "${user}"
    sudo rm "/home/$(basename "${tarball}")"
done
```

This restores home dirs, databases, DNS, mail, SSL, sub/addon/parked domains — in one shot per account.

### 4. Restore standalone databases (if any not inside an account)

System-level databases (Roundcube, modsec, etc.) are captured separately:

```bash
for dump in /root/restore/2026-04-17_021500/databases/*.sql.gz; do
    db=$(basename "${dump}" .sql.gz)
    [[ "${db}" == alice* || "${db}" == bob* ]] && continue  # already in pkgacct
    gunzip -c "${dump}" | mysql --defaults-file=/root/.my.cnf
done
```

### 5. Rebuild package state (optional)

If you installed extra RPMs on the old box:

```bash
# Diff the old package list against the new install:
comm -23 \
    <(sort /root/restore/2026-04-17_021500/system/packages.txt) \
    <(rpm -qa | sort) \
    > /tmp/missing-packages.txt

# Review and install the safe ones:
less /tmp/missing-packages.txt
sudo dnf install -y $(cat /tmp/missing-packages.txt)
```

### 6. Re-enable cron / re-install this backup tool

```bash
cd /root
git clone https://github.com/masharif46/cpanel-auto-backup.git
sudo /root/cpanel-auto-backup/scripts/install.sh --cron
sudo cp /root/restore/2026-04-17_021500/etc/cpanel-auto-backup/backup.conf \
    /etc/cpanel-auto-backup/backup.conf 2>/dev/null || true
```

## Partial restores

**Restore just mail for one user** — the maildir is inside the account tarball:

```bash
mkdir /tmp/restore && cd /tmp/restore
tar -xzf /backup/cpanel/2026-04-17_021500/accounts/cpmove-alice.tar.gz \
    homedir/mail/
# Then rsync into the live user's mail dir:
rsync -a homedir/mail/ /home/alice/mail/
chown -R alice:alice /home/alice/mail
```

**Restore just one subdomain's DNS zone:**

```bash
tar -xzf /backup/cpanel/2026-04-17_021500/system/system-config.tar.gz \
    var/named/example.com.db
sudo cp var/named/example.com.db /var/named/
sudo rndc reload
```

## Verifying a restore

Always check the basics before considering the restore complete:

```bash
# Account back?
sudo /usr/local/cpanel/bin/whmapi1 listaccts search=alice

# Files present?
sudo ls -la /home/alice/public_html | head

# DB reachable?
sudo mysql -e "SHOW TABLES" alice_wp

# Mail?
sudo ls /home/alice/mail/example.com/alice/

# Website loads?
curl -I https://alice.example.com
```

## Rollback

Because restorepkg is not transactional, roll back with the snapshot you took before the restore:

```bash
sudo /opt/cpanel-auto-backup/scripts/restore-account.sh \
    /backup/cpanel/<pre-restore-snapshot>/accounts/cpmove-alice.tar.gz
```

If the restore corrupted the MySQL DB and you kept a pre-restore dump, re-apply it the same way as [Scenario 2](#scenario-2-restore-one-database).
