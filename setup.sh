#!/bin/bash
# =============================================================================
#  SERVER BACKUP SETUP — Backblaze B2 + Restic
# =============================================================================
#  Run once as root to configure encrypted daily backups:
#    sudo bash setup.sh
#
#  This script will:
#    1. Install restic (the backup engine)
#    2. Prompt for your B2 credentials and an encryption password
#    3. Initialize an encrypted restic repository in your B2 bucket
#    4. Install backup.sh and restore.sh to /opt/server-backup/
#    5. Schedule a daily cron job at 2:00 AM
# =============================================================================

set -euo pipefail

INSTALL_DIR="/opt/server-backup"
CRON_FILE="/etc/cron.d/server-backup"
LOG_FILE="/var/log/server-backup.log"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()    { echo -e "${GREEN}[✓]${NC} $1"; }
warn()   { echo -e "${YELLOW}[!]${NC} $1"; }
error()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }
ask()    { echo -e "${BLUE}[?]${NC} $1"; }

# ---------------------------------------------------------------------------
# Root check
# ---------------------------------------------------------------------------
[[ "$EUID" -ne 0 ]] && error "Please run as root:  sudo bash setup.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for f in backup.sh restore.sh; do
    [[ -f "$SCRIPT_DIR/$f" ]] || error "Missing $f — make sure all files are in the same directory as setup.sh"
done

echo ""
echo "============================================================="
echo "   Server Backup Setup  —  Backblaze B2 + Restic"
echo "============================================================="
echo ""

# ---------------------------------------------------------------------------
# Install restic
# ---------------------------------------------------------------------------
if command -v restic &>/dev/null; then
    log "Restic already installed: $(restic version | head -1)"
else
    log "Installing restic..."
    if command -v apt-get &>/dev/null; then
        apt-get update -qq && apt-get install -y restic
    elif command -v dnf &>/dev/null; then
        dnf install -y restic
    elif command -v yum &>/dev/null; then
        yum install -y restic
    else
        # Direct download from GitHub releases
        warn "Package manager not found — downloading restic binary directly..."
        ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
        RESTIC_VER=$(curl -fsSL https://api.github.com/repos/restic/restic/releases/latest \
                     | grep -oP '"tag_name":\s*"v\K[^"]+' | head -1)
        RESTIC_URL="https://github.com/restic/restic/releases/download/v${RESTIC_VER}/restic_${RESTIC_VER}_linux_${ARCH}.bz2"
        curl -fsSL "$RESTIC_URL" | bunzip2 > /usr/local/bin/restic
        chmod +x /usr/local/bin/restic
    fi
    restic self-update 2>/dev/null || true
    log "Restic installed: $(restic version | head -1)"
fi

# ---------------------------------------------------------------------------
# Gather credentials
# ---------------------------------------------------------------------------
echo ""
echo "  You'll need the following from Backblaze B2:"
echo "    • An Application Key ID  (Settings → App Keys)"
echo "    • An Application Key     (shown once at creation)"
echo "    • A bucket name          (create a private bucket first)"
echo ""
echo "  You'll also choose an encryption password. This password is the ONLY"
echo "  way to decrypt your backups — store it somewhere safe (password manager,"
echo "  printed copy, etc.). Losing it means losing access to your backups."
echo ""

ask "B2 Application Key ID:"
read -r B2_ACCOUNT_ID

ask "B2 Application Key:"
read -rs B2_ACCOUNT_KEY; echo ""

ask "B2 bucket name:"
read -r B2_BUCKET

# Optional: subdirectory within the bucket (useful if sharing bucket)
ask "Path prefix inside bucket (press Enter to use bucket root):"
read -r B2_PATH
if [[ -n "$B2_PATH" ]]; then
    RESTIC_REPO="b2:${B2_BUCKET}:/${B2_PATH#/}"
else
    RESTIC_REPO="b2:${B2_BUCKET}"
fi

echo ""
ask "Choose an encryption password for your backups:"
read -rs RESTIC_PASSWORD; echo ""
ask "Confirm password:"
read -rs RESTIC_PASSWORD2; echo ""
[[ "$RESTIC_PASSWORD" != "$RESTIC_PASSWORD2" ]] && error "Passwords do not match."
[[ -z "$RESTIC_PASSWORD" ]] && error "Password cannot be empty."

# ---------------------------------------------------------------------------
# Optional: backup time (default 2:00 AM)
# ---------------------------------------------------------------------------
echo ""
ask "What time should backups run? (24h format HH:MM, default: 02:00):"
read -r BACKUP_TIME
if [[ -z "$BACKUP_TIME" ]]; then
    CRON_HOUR=2; CRON_MIN=0
else
    CRON_HOUR=$(echo "$BACKUP_TIME" | cut -d: -f1)
    CRON_MIN=$(echo "$BACKUP_TIME"  | cut -d: -f2)
fi

# ---------------------------------------------------------------------------
# Create install directory and .env
# ---------------------------------------------------------------------------
mkdir -p "$INSTALL_DIR"
chmod 700 "$INSTALL_DIR"

cat > "$INSTALL_DIR/.env" <<EOF
# -------------------------------------------------------
# Backblaze B2 + Restic credentials
# This file is root-read-only (chmod 600). Guard it well.
# -------------------------------------------------------

export B2_ACCOUNT_ID="${B2_ACCOUNT_ID}"
export B2_ACCOUNT_KEY="${B2_ACCOUNT_KEY}"

# Restic repository location
export RESTIC_REPOSITORY="${RESTIC_REPO}"

# Encryption password — BACK THIS UP SEPARATELY
export RESTIC_PASSWORD="${RESTIC_PASSWORD}"
EOF
chmod 600 "$INSTALL_DIR/.env"
log "Credentials saved to $INSTALL_DIR/.env"

# ---------------------------------------------------------------------------
# Copy scripts
# ---------------------------------------------------------------------------
cp "$SCRIPT_DIR/backup.sh"  "$INSTALL_DIR/backup.sh"
cp "$SCRIPT_DIR/restore.sh" "$INSTALL_DIR/restore.sh"
chmod 700 "$INSTALL_DIR/backup.sh" "$INSTALL_DIR/restore.sh"
log "Scripts installed to $INSTALL_DIR/"

# ---------------------------------------------------------------------------
# Initialize restic repository
# ---------------------------------------------------------------------------
echo ""
log "Initializing restic repository in B2 (this may take a moment)..."
export B2_ACCOUNT_ID B2_ACCOUNT_KEY RESTIC_REPOSITORY="$RESTIC_REPO" RESTIC_PASSWORD
if restic init 2>&1; then
    log "Repository initialized successfully."
else
    # If it already exists, that's fine
    warn "Repository may already exist — attempting to verify..."
    restic snapshots &>/dev/null && log "Existing repository verified." \
        || error "Could not initialize or access the repository. Check your credentials."
fi

# ---------------------------------------------------------------------------
# Set up cron job
# ---------------------------------------------------------------------------
cat > "$CRON_FILE" <<EOF
# Daily server backup to Backblaze B2
# Generated by setup.sh on $(date)
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

${CRON_MIN} ${CRON_HOUR} * * * root ${INSTALL_DIR}/backup.sh >> ${LOG_FILE} 2>&1
EOF
chmod 644 "$CRON_FILE"
log "Cron job scheduled: daily at $(printf '%02d:%02d' "$CRON_HOUR" "$CRON_MIN") → $CRON_FILE"

# Touch log file with correct perms
touch "$LOG_FILE"
chmod 640 "$LOG_FILE"

# ---------------------------------------------------------------------------
# Run an initial backup?
# ---------------------------------------------------------------------------
echo ""
ask "Run an initial backup right now? (y/N):"
read -r RUN_NOW
if [[ "$RUN_NOW" =~ ^[Yy]$ ]]; then
    log "Starting initial backup — this will take a while on first run..."
    "$INSTALL_DIR/backup.sh"
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo ""
echo "============================================================="
echo "  Setup complete!"
echo "============================================================="
echo ""
echo "  Backups run automatically: $(printf '%02d:%02d' "$CRON_HOUR" "$CRON_MIN") every night"
echo "  Installed to:              $INSTALL_DIR/"
echo "  Credentials:               $INSTALL_DIR/.env  (root only)"
echo "  Cron job:                  $CRON_FILE"
echo "  Log file:                  $LOG_FILE"
echo ""
echo "  Useful commands:"
echo "    sudo $INSTALL_DIR/backup.sh       # run a backup manually"
echo "    sudo $INSTALL_DIR/restore.sh      # interactive restore"
echo "    sudo tail -f $LOG_FILE   # watch backup progress"
echo ""
echo "  ⚠  IMPORTANT: Make sure your encryption password is backed"
echo "     up somewhere outside this server!"
echo ""
