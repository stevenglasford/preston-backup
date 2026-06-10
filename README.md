# Server Backup — Backblaze B2 + Restic

Encrypted, incremental, daily backups of your Linux server to Backblaze B2.

## How it works

- **[Restic](https://restic.net/)** handles backup, encryption, and deduplication
- **Backblaze B2** stores the data cheaply (~$6/TB/month)
- Everything is encrypted client-side with AES-256 before it leaves your server
- Backups are incremental — only changed data is uploaded after the first run
- Old snapshots are pruned automatically: **7 daily, 4 weekly, 3 monthly**
- A full integrity check runs automatically every Sunday

-----

## Setup

### 1. Prerequisites — Backblaze B2

1. Create a free account at [backblaze.com](https://www.backblaze.com/b2/cloud-storage.html)
1. Create a **private** B2 bucket (e.g. `my-server-backup`)
1. Go to **App Keys** → create a new Application Key with:
- Access: Read & Write
- Bucket: your backup bucket (restrict to that bucket for safety)
1. Note your **Application Key ID** and **Application Key** (shown once)

### 2. Install

```bash
# Download all three scripts to the same directory, then:
sudo bash setup.sh
```

`setup.sh` will:

- Install restic (via apt, dnf, or direct download)
- Prompt for your B2 credentials and an encryption password
- Initialize the encrypted repository in B2
- Install scripts to `/opt/server-backup/`
- Schedule a daily cron job

### 3. ⚠ Back up your encryption password

Your backups are useless without the encryption password. Store it in:

- A password manager (Bitwarden, 1Password, etc.)
- A printed copy somewhere safe
- Anywhere that isn’t only on this server

-----

## Daily operations

|Task                      |Command                                  |
|--------------------------|-----------------------------------------|
|Run a backup manually     |`sudo /opt/server-backup/backup.sh`      |
|Watch a backup in progress|`sudo tail -f /var/log/server-backup.log`|
|List all snapshots        |`sudo restic -r b2:YOUR-BUCKET snapshots`|
|Interactive restore       |`sudo /opt/server-backup/restore.sh`     |
|Check B2 storage used     |Backblaze dashboard → your bucket        |

-----

## What’s backed up

|Included                                  |Excluded                                             |
|------------------------------------------|-----------------------------------------------------|
|`/etc` — all system config                |`/proc`, `/sys`, `/dev`, `/run` — virtual filesystems|
|`/home` — all user files                  |`/tmp`, `/var/tmp` — temp files                      |
|`/root` — root home dir                   |`/var/cache` — package cache                         |
|`/var` — app data, databases, logs        |`/mnt`, `/media` — mount points                      |
|`/srv`, `/opt`, `/usr/local`              |`node_modules`, `.npm`, `.yarn`                      |
|`/app` or wherever your server lives      |Docker overlay2, LXD storage                         |
|System state snapshot (packages, services)|`.cache` and trash dirs                              |

### SQLite note

Your SQLite database files are backed up as regular files. This is safe when:

- Your app is in [WAL mode](https://www.sqlite.org/wal.html) (recommended — most apps use this)
- You’re okay with a backup that’s at most a few seconds behind

For absolute consistency, you can add a pre-backup hook to `backup.sh`:

```bash
# Add before the restic backup command:
sqlite3 /path/to/your/app.db ".backup /tmp/app-backup.db"
```

-----

## Restoring a server

### Scenario A: Restore to a new server (most common)

1. Provision a fresh Ubuntu/Debian server
1. Install restic: `apt install restic`
1. Create `/opt/server-backup/.env` with your credentials:
   
   ```bash
   export B2_ACCOUNT_ID="your-key-id"
   export B2_ACCOUNT_KEY="your-app-key"
   export RESTIC_REPOSITORY="b2:your-bucket-name"
   export RESTIC_PASSWORD="your-encryption-password"
   chmod 600 /opt/server-backup/.env
   ```
1. Run the restore helper: `sudo /opt/server-backup/restore.sh`
1. Choose option **2** (full restore) or **3** (restore to a directory)
1. Reinstall packages:
   
   ```bash
   dpkg --set-selections < /tmp/backup-state/packages.txt
   apt-get dselect-upgrade
   ```
1. Reboot

### Scenario B: Recover a specific file

```bash
sudo /opt/server-backup/restore.sh
# Choose option 4 — enter the path and a target directory
```

### Scenario C: Browse snapshots manually

```bash
sudo restic -r b2:YOUR-BUCKET mount /mnt/restore
# Now browse /mnt/restore/snapshots/
ls /mnt/restore/snapshots/latest/home/youruser/
# Ctrl+C to unmount when done
```

-----

## Storage & cost estimate

|Server size|First backup|Daily incremental|Monthly cost|
|-----------|------------|-----------------|------------|
|~20 GB     |~20 GB      |~100–500 MB      |~$0.12      |
|~100 GB    |~100 GB     |~500 MB–2 GB     |~$0.60      |
|~500 GB    |~500 GB     |~1–5 GB          |~$3.00      |

With 7 daily + 4 weekly + 3 monthly retention, you’ll store roughly 14 snapshots worth of deduplicated data.

-----

## Troubleshooting

**“No such file or directory: .env”**
→ Run `setup.sh` first, or manually create `.env` as shown above.

**“Wrong password for repository”**
→ Double-check `RESTIC_PASSWORD` in your `.env` file.

**“b2: 401 Unauthorized”**
→ Check `B2_ACCOUNT_ID` and `B2_ACCOUNT_KEY`. Keys can expire or be revoked.

**Backup stuck or very slow on first run**
→ Normal. Restic uploads everything on the first run. Let it finish.

**“repository is already locked”**
→ A previous backup crashed. Run: `restic unlock`

**Check the log**

```bash
sudo tail -100 /var/log/server-backup.log
```

-----

## Files

```
/opt/server-backup/
├── .env          # B2 credentials + encryption password (chmod 600)
├── backup.sh     # Run by cron nightly
└── restore.sh    # Interactive restore helper

/etc/cron.d/server-backup   # Cron schedule
/var/log/server-backup.log  # Backup log
```