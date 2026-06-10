#!/bin/bash
# =============================================================================
#  MOUNT EXTERNAL DRIVE — mount-drive.sh
# =============================================================================
#  Run once as root to detect, optionally format, and permanently mount
#  your external drive. Creates a sensible directory layout and adds the
#  drive to /etc/fstab so it remounts automatically on reboot.
#
#    sudo bash mount-drive.sh
# =============================================================================

set -euo pipefail

MOUNT_POINT="/mnt/data"
DRIVE_LABEL="server-data"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }
ask()  { echo -e "${BLUE}[?]${NC} $1"; }

[[ "$EUID" -ne 0 ]] && err "Please run as root:  sudo bash mount-drive.sh"

echo ""
echo "============================================================="
echo "   External Drive Setup"
echo "============================================================="

# ---------------------------------------------------------------------------
# Show all block devices
# ---------------------------------------------------------------------------
echo ""
echo "  Detected block devices:"
echo ""
lsblk -d -o NAME,SIZE,TYPE,TRAN,MOUNTPOINT,FSTYPE,VENDOR,MODEL \
    | grep -v "^loop" \
    | column -t
echo ""

ask "Enter the device name of your external drive (e.g. sdb, not sdb1):"
read -r RAW_DEVICE
DEVICE="/dev/${RAW_DEVICE#/dev/}"

[[ -b "$DEVICE" ]] || err "Device $DEVICE not found."

# Show what's currently on it
echo ""
echo "  Current partition table on $DEVICE:"
lsblk "$DEVICE"
echo ""

# ---------------------------------------------------------------------------
# Partition check — does it have partitions already?
# ---------------------------------------------------------------------------
EXISTING_PARTS=$(lsblk -lno NAME "$DEVICE" | tail -n +2 | head -1)
NEEDS_FORMAT=false

if [[ -n "$EXISTING_PARTS" ]]; then
    PART_DEVICE="/dev/$EXISTING_PARTS"
    EXISTING_FS=$(blkid -o value -s TYPE "$PART_DEVICE" 2>/dev/null || echo "none")

    if [[ "$EXISTING_FS" == "ext4" ]]; then
        warn "Found existing ext4 partition at $PART_DEVICE — will mount as-is."
        TARGET_PARTITION="$PART_DEVICE"
    else
        warn "Found partition at $PART_DEVICE with filesystem: ${EXISTING_FS:-none}"
        ask "Format it as ext4? ALL DATA WILL BE LOST. (type YES to confirm):"
        read -r CONFIRM_FORMAT
        if [[ "$CONFIRM_FORMAT" == "YES" ]]; then
            TARGET_PARTITION="$PART_DEVICE"
            NEEDS_FORMAT=true
        else
            warn "Aborted. No changes made."
            exit 0
        fi
    fi
else
    warn "No partitions found on $DEVICE."
    ask "Create a new partition and format as ext4? (type YES to confirm):"
    read -r CONFIRM_NEW
    if [[ "$CONFIRM_NEW" == "YES" ]]; then
        echo ""
        log "Creating partition table and partition..."
        parted "$DEVICE" --script mklabel gpt mkpart primary ext4 0% 100%
        # Give the kernel a moment to see the new partition
        partprobe "$DEVICE"
        sleep 2
        TARGET_PARTITION="${DEVICE}1"
        NEEDS_FORMAT=true
    else
        warn "Aborted. No changes made."
        exit 0
    fi
fi

# ---------------------------------------------------------------------------
# Format
# ---------------------------------------------------------------------------
if [[ "$NEEDS_FORMAT" == true ]]; then
    echo ""
    log "Formatting $TARGET_PARTITION as ext4 (label: $DRIVE_LABEL) ..."
    mkfs.ext4 -L "$DRIVE_LABEL" "$TARGET_PARTITION"
    log "Format complete."
fi

# ---------------------------------------------------------------------------
# Get UUID
# ---------------------------------------------------------------------------
UUID=$(blkid -o value -s UUID "$TARGET_PARTITION")
[[ -z "$UUID" ]] && err "Could not read UUID from $TARGET_PARTITION"
log "Drive UUID: $UUID"

# ---------------------------------------------------------------------------
# Mount point
# ---------------------------------------------------------------------------
echo ""
ask "Mount point (default: $MOUNT_POINT):"
read -r CUSTOM_MOUNT
MOUNT_POINT="${CUSTOM_MOUNT:-$MOUNT_POINT}"

mkdir -p "$MOUNT_POINT"

# ---------------------------------------------------------------------------
# Add to /etc/fstab (if not already present)
# ---------------------------------------------------------------------------
if grep -q "$UUID" /etc/fstab; then
    warn "UUID $UUID already in /etc/fstab — skipping fstab update."
else
    # Backup fstab first
    cp /etc/fstab /etc/fstab.bak.$(date +%Y%m%d_%H%M%S)
    echo "" >> /etc/fstab
    echo "# External 8TB drive — added by mount-drive.sh $(date)" >> /etc/fstab
    echo "UUID=${UUID}  ${MOUNT_POINT}  ext4  defaults,nofail,x-systemd.device-timeout=10  0  2" >> /etc/fstab
    log "Added to /etc/fstab (original backed up)"
fi

# ---------------------------------------------------------------------------
# Mount it
# ---------------------------------------------------------------------------
mount "$MOUNT_POINT" 2>/dev/null || mount "$TARGET_PARTITION" "$MOUNT_POINT"
log "Mounted at $MOUNT_POINT"

# Test write
touch "$MOUNT_POINT/.mount-test" && rm "$MOUNT_POINT/.mount-test"
log "Write test passed."

# ---------------------------------------------------------------------------
# Create directory structure
# ---------------------------------------------------------------------------
echo ""
log "Creating directory structure under $MOUNT_POINT ..."

mkdir -p \
    "$MOUNT_POINT/media" \
    "$MOUNT_POINT/uploads" \
    "$MOUNT_POINT/databases" \
    "$MOUNT_POINT/archives" \
    "$MOUNT_POINT/downloads" \
    "$MOUNT_POINT/app-data"

# Make it accessible to the main user
MAIN_USER=$(getent passwd 1000 | cut -d: -f1 2>/dev/null || echo "")
if [[ -n "$MAIN_USER" ]]; then
    chown -R "$MAIN_USER:$MAIN_USER" "$MOUNT_POINT"
    log "Ownership set to $MAIN_USER"
fi

chmod 755 "$MOUNT_POINT"

# ---------------------------------------------------------------------------
# Show result
# ---------------------------------------------------------------------------
echo ""
echo "============================================================="
echo "  Drive ready!"
echo "============================================================="
echo ""
df -h "$MOUNT_POINT"
echo ""
echo "  Directory layout:"
ls -la "$MOUNT_POINT/"
echo ""
echo "  Use these paths for large files:"
echo "    $MOUNT_POINT/media/        — photos, videos, audio"
echo "    $MOUNT_POINT/uploads/      — web app file uploads"
echo "    $MOUNT_POINT/databases/    — database dumps/exports"
echo "    $MOUNT_POINT/app-data/     — app-specific large data"
echo "    $MOUNT_POINT/archives/     — old/archival files"
echo "    $MOUNT_POINT/downloads/    — misc downloads"
echo ""
echo "  The drive will automount at boot via /etc/fstab."
echo "  If the drive is disconnected, the server will still boot (nofail)."
echo ""
echo "  Next: run  sudo bash backup-data.sh  (or let cron run it)"
echo "        or add the cron entry from install-data-backup section"
echo "        of the README."
echo ""
