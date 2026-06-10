#!/bin/bash
# =============================================================================
#  EXTERNAL DRIVE BACKUP — backup-data.sh
# =============================================================================
#  Backs up /mnt/data (your external drive) to Backblaze B2 via restic.
#  Uses the same credentials as backup.sh — drop this file alongside it
#  in /opt/server-backup/ and it will pick up .env automatically.
#
#  Run manually:   sudo /opt/server-backup/backup-data.sh
#  Scheduled via:  /etc/cron.d/server-backup (added by install below)
#
#  Retention is intentionally lighter than the system backup since
#  the external drive can hold terabytes and B2 storage adds up:
#    3 daily  |  2 weekly  |  2 monthly
#  Adjust KEEP_* below to taste.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="/var/log/server-backup-data.log"
LOCK_FILE="/tmp/server-backup-data.lock"
DATA_MOUNT="/mnt/data"

# ---------------------------------------------------------------------------
# Retention — lighter than system backup due to potential data volume
# ---------------------------------------------------------------------------
KEEP_DAILY=3
KEEP_WEEKLY=2
KEEP_MONTHLY=2

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

# ---------------------------------------------------------------------------
# Root check
# ---------------------------------------------------------------------------
[[ "$EUID" -ne 0 ]] && { echo "Please run as root."; exit 1; }

# ---------------------------------------------------------------------------
# Prevent concurrent runs (also checks against system backup lock)
# ---------------------------------------------------------------------------
exec 201>"$LOCK_FILE"
flock -n 201 || { log "ERROR: Another data backup is already running."; exit 1; }

# Also check if system backup.sh is running — restic can't share a repo simultaneously
if [[ -f /tmp/server-backup.lock ]]; then
    flock -n 200 /tmp/server-backup.lock 2>/dev/null || {
        log "System backup is currently running — waiting up to 2 hours..."
        WAIT=0
        while [[ -f /tmp/server-backup.lock ]] && flock -n 200 /tmp/server-backup.lock 2>/dev/null; [ $? -ne 0 ]; do
            sleep 60
            WAIT=$((WAIT + 1))
            [[ "$WAIT" -ge 120 ]] && { log "ERROR: System backup still running after 2h. Aborting."; exit 1; }
        done
    }
fi

# ---------------------------------------------------------------------------
# Load credentials (shared with backup.sh)
# ---------------------------------------------------------------------------
[[ -f "$SCRIPT_DIR/.env" ]] || { log "ERROR: $SCRIPT_DIR/.env not found. Run setup.sh first."; exit 1; }
# shellcheck source=/dev/null
source "$SCRIPT_DIR/.env"

# ---------------------------------------------------------------------------
# Verify external drive is actually mounted
# ---------------------------------------------------------------------------
if ! mountpoint -q "$DATA_MOUNT"; then
    log "WARNING: $DATA_MOUNT is not mounted. Skipping data backup."
    log "  To debug: run  lsblk  and  cat /etc/fstab"
    exit 0   # exit 0 so cron doesn't spam failure emails
fi

DRIVE_USED=$(df -h "$DATA_MOUNT" | awk 'NR==2 {print $3 " used of " $2}')
log "========================================="
log "  Data backup started"
log "  Source:     $DATA_MOUNT  ($DRIVE_USED)"
log "  Repository: $RESTIC_REPOSITORY"
log "========================================="

START_TIME=$(date +%s)

# ---------------------------------------------------------------------------
# Run the backup
# ---------------------------------------------------------------------------
log "Starting restic backup of $DATA_MOUNT ..."

restic backup \
    "$DATA_MOUNT" \
    \
    --exclude="$DATA_MOUNT/local-restic-cache" \
    --exclude="$DATA_MOUNT/**/.cache" \
    --exclude="$DATA_MOUNT/**/.Trash" \
    --exclude="$DATA_MOUNT/**/Thumbs.db" \
    --exclude="$DATA_MOUNT/**/.DS_Store" \
    --exclude="*.part" \
    --exclude="*.crdownload" \
    --exclude="*.tmp" \
    \
    --tag "data-backup" \
    --tag "$(hostname)" \
    --tag "external-drive" \
    --compression max \
    2>&1 | tee -a "$LOG_FILE"

BACKUP_EXIT=${PIPESTATUS[0]}

if [[ "$BACKUP_EXIT" -ne 0 ]]; then
    log "ERROR: restic backup exited with code $BACKUP_EXIT"
    exit "$BACKUP_EXIT"
fi
log "Backup completed successfully."

# ---------------------------------------------------------------------------
# Prune — only touches snapshots tagged data-backup
# ---------------------------------------------------------------------------
log "Pruning old data snapshots (daily=$KEEP_DAILY weekly=$KEEP_WEEKLY monthly=$KEEP_MONTHLY)..."

restic forget \
    --keep-daily   "$KEEP_DAILY" \
    --keep-weekly  "$KEEP_WEEKLY" \
    --keep-monthly "$KEEP_MONTHLY" \
    --tag "data-backup" \
    --prune \
    2>&1 | tee -a "$LOG_FILE"

# ---------------------------------------------------------------------------
# Integrity check — monthly only (too slow/expensive to run weekly on TBs)
# ---------------------------------------------------------------------------
DAY_OF_MONTH=$(date +%d)
if [[ "$DAY_OF_MONTH" == "01" ]]; then
    log "Running monthly integrity check (first of month)..."
    restic check 2>&1 | tee -a "$LOG_FILE"
    log "Check complete."
fi

# ---------------------------------------------------------------------------
# Stats
# ---------------------------------------------------------------------------
END_TIME=$(date +%s)
ELAPSED=$(( END_TIME - START_TIME ))
log "Total time: $(printf '%dh %dm %ds' $((ELAPSED/3600)) $(( (ELAPSED%3600)/60 )) $((ELAPSED%60)))"

# Show restic stats for this repo (all snapshots)
log "Repository stats:"
restic stats 2>&1 | tee -a "$LOG_FILE" || true

log "========================================="
log "  Data backup finished"
log "========================================="
