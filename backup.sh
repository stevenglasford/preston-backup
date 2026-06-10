#!/bin/bash
# =============================================================================
#  SERVER BACKUP — backup.sh
# =============================================================================
#  Runs automatically via cron. Can also be run manually:
#    sudo /opt/server-backup/backup.sh
#
#  Retention policy (configurable below):
#    7 daily snapshots, 4 weekly, 3 monthly
#
#  A full integrity check runs automatically every Sunday.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="/var/log/server-backup.log"
LOCK_FILE="/tmp/server-backup.lock"

# ---------------------------------------------------------------------------
# Retention policy — adjust to taste
# ---------------------------------------------------------------------------
KEEP_DAILY=7
KEEP_WEEKLY=4
KEEP_MONTHLY=3

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

# ---------------------------------------------------------------------------
# Root check
# ---------------------------------------------------------------------------
[[ "$EUID" -ne 0 ]] && { echo "Please run as root."; exit 1; }

# ---------------------------------------------------------------------------
# Prevent concurrent runs
# ---------------------------------------------------------------------------
exec 200>"$LOCK_FILE"
flock -n 200 || { log "ERROR: Another backup is already running. Exiting."; exit 1; }

# ---------------------------------------------------------------------------
# Load credentials
# ---------------------------------------------------------------------------
[[ -f "$SCRIPT_DIR/.env" ]] || { log "ERROR: $SCRIPT_DIR/.env not found. Run setup.sh first."; exit 1; }
# shellcheck source=/dev/null
source "$SCRIPT_DIR/.env"

log "========================================="
log "  Backup started"
log "  Repository: $RESTIC_REPOSITORY"
log "========================================="

START_TIME=$(date +%s)

# ---------------------------------------------------------------------------
# Pre-backup: snapshot system state to temp files
# These are included in the backup as /tmp/backup-state/
# ---------------------------------------------------------------------------
STATE_DIR="/tmp/backup-state"
mkdir -p "$STATE_DIR"

log "Capturing system state..."
dpkg --get-selections        2>/dev/null > "$STATE_DIR/packages.txt"    || true
apt-mark showmanual          2>/dev/null > "$STATE_DIR/packages-manual.txt" || true
crontab -l                   2>/dev/null > "$STATE_DIR/crontab-root.txt" || true
systemctl list-unit-files --type=service --state=enabled --no-legend \
                             2>/dev/null | awk '{print $1}' > "$STATE_DIR/services-enabled.txt" || true
ip addr show                 2>/dev/null > "$STATE_DIR/network.txt"      || true
df -h                        2>/dev/null > "$STATE_DIR/disk-usage.txt"   || true
uname -a                     2>/dev/null > "$STATE_DIR/kernel.txt"       || true
cat /etc/os-release          2>/dev/null > "$STATE_DIR/os-release.txt"   || true

# ---------------------------------------------------------------------------
# Run the backup
# ---------------------------------------------------------------------------
log "Starting restic backup..."

restic backup \
    / \
    "$STATE_DIR" \
    \
    --exclude=/proc \
    --exclude=/sys \
    --exclude=/dev \
    --exclude=/run \
    --exclude=/tmp \
    --exclude=/var/tmp \
    --exclude=/var/cache \
    --exclude=/lost+found \
    --exclude=/mnt \
    --exclude=/media \
    --exclude=/swapfile \
    --exclude=/swap.img \
    \
    --exclude="*.sock" \
    --exclude="*.pid" \
    --exclude="/home/*/.cache" \
    --exclude="/root/.cache" \
    --exclude="/home/*/.local/share/Trash" \
    --exclude="/home/*/.thumbnails" \
    \
    --exclude="node_modules" \
    --exclude=".npm" \
    --exclude=".yarn/cache" \
    --exclude=".pnpm-store" \
    \
    --exclude="/var/lib/docker/overlay2" \
    --exclude="/var/lib/lxd/storage-pools" \
    --exclude="/var/lib/snapd/snaps" \
    \
    --tag "server-backup" \
    --tag "$(hostname)" \
    --compression max \
    2>&1 | tee -a "$LOG_FILE"

BACKUP_EXIT=${PIPESTATUS[0]}

# Clean up state dir
rm -rf "$STATE_DIR"

if [[ "$BACKUP_EXIT" -ne 0 ]]; then
    log "ERROR: restic backup exited with code $BACKUP_EXIT"
    exit "$BACKUP_EXIT"
fi
log "Backup completed successfully."

# ---------------------------------------------------------------------------
# Prune old snapshots
# ---------------------------------------------------------------------------
log "Pruning old snapshots (daily=$KEEP_DAILY weekly=$KEEP_WEEKLY monthly=$KEEP_MONTHLY)..."

restic forget \
    --keep-daily   "$KEEP_DAILY" \
    --keep-weekly  "$KEEP_WEEKLY" \
    --keep-monthly "$KEEP_MONTHLY" \
    --tag "server-backup" \
    --prune \
    2>&1 | tee -a "$LOG_FILE"

# ---------------------------------------------------------------------------
# Weekly integrity check (Sundays only — can take several minutes)
# ---------------------------------------------------------------------------
if [[ "$(date +%u)" == "7" ]]; then
    log "Running weekly integrity check..."
    restic check 2>&1 | tee -a "$LOG_FILE"
    log "Integrity check complete."
fi

# ---------------------------------------------------------------------------
# Log stats
# ---------------------------------------------------------------------------
END_TIME=$(date +%s)
ELAPSED=$(( END_TIME - START_TIME ))
log "Total time: $(printf '%dm %ds' $((ELAPSED/60)) $((ELAPSED%60)))"
log "========================================="
log "  Backup finished"
log "========================================="
