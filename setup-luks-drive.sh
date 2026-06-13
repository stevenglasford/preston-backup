#!/bin/bash
# =============================================================================
#  LUKS DRIVE SETUP — setup-luks-drive.sh
# =============================================================================
#  Merges all partitions on an external drive into one, encrypts it with
#  LUKS2, formats ext4 inside the container, and mounts it at /mnt/data.
#
#  Supports two unlock modes:
#    • Keyfile  — stored on your SSD, auto-unlocks on boot (recommended
#                  for a server you don't type into every reboot)
#    • Password — prompted at every boot (more secure if the SSD could
#                  also be stolen)
#
#  Run as root:  sudo bash setup-luks-drive.sh
#
#  ⚠  ALL DATA ON THE TARGET DRIVE WILL BE ERASED. ⚠
#     Back up anything on it to B2 first.
# =============================================================================

set -euo pipefail

MOUNT_POINT="/mnt/data"
LUKS_NAME="data-drive"           # becomes /dev/mapper/data-drive
LUKS_KEYFILE="/etc/luks/${LUKS_NAME}.key"
DRIVE_LABEL="server-data"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }
ask()  { echo -e "${BLUE}[?]${NC} $1"; }

[[ "$EUID" -ne 0 ]] && err "Please run as root:  sudo bash setup-luks-drive.sh"

# Require cryptsetup
if ! command -v cryptsetup &>/dev/null; then
    log "Installing cryptsetup..."
    apt-get update -qq && apt-get install -y cryptsetup cryptsetup-initramfs
fi

echo ""
echo "============================================================="
echo "   LUKS Encrypted Drive Setup"
echo "============================================================="
echo ""

# ---------------------------------------------------------------------------
# Show all block devices
# ---------------------------------------------------------------------------
echo "  Detected block devices:"
echo ""
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,LABEL | grep -v "^loop"
echo ""

ask "Device to encrypt (e.g. sda — the whole disk, NOT a partition):"
read -r RAW_DEVICE
DEVICE="/dev/${RAW_DEVICE#/dev/}"

[[ -b "$DEVICE" ]] || err "Device $DEVICE not found."

# ---------------------------------------------------------------------------
# Safety: refuse if this device holds the root filesystem
# ---------------------------------------------------------------------------
ROOT_DEV=$(df / | awk 'NR==2 {print $1}')
if echo "$ROOT_DEV" | grep -q "^${DEVICE}"; then
    err "⚠  $DEVICE appears to contain your root filesystem ($ROOT_DEV). Aborting."
fi
if lsblk -lno MOUNTPOINT "$DEVICE" 2>/dev/null | grep -qE "^/$|^/boot|^/usr"; then
    err "⚠  $DEVICE contains a system mount point. Aborting."
fi

# ---------------------------------------------------------------------------
# Show what's on it and unmount any partitions
# ---------------------------------------------------------------------------
echo ""
echo "  Current layout of $DEVICE:"
lsblk "$DEVICE"
echo ""

MOUNTED_PARTS=$(lsblk -lno NAME,MOUNTPOINT "$DEVICE" | awk '$2!="" {print "/dev/"$1}')
if [[ -n "$MOUNTED_PARTS" ]]; then
    warn "The following partitions are currently mounted and will be unmounted:"
    echo "$MOUNTED_PARTS"
    echo ""
    ask "Proceed with unmounting? (y/N):"
    read -r CONFIRM_UMOUNT
    [[ "$CONFIRM_UMOUNT" =~ ^[Yy]$ ]] || { warn "Aborted."; exit 0; }
    for PART in $MOUNTED_PARTS; do
        umount "$PART" && log "Unmounted $PART"
    done
    # Remove old fstab entries for this device
    DEVICE_UUID_OLD=$(blkid -o value -s UUID "$DEVICE"* 2>/dev/null || true)
fi

# ---------------------------------------------------------------------------
# Final warning
# ---------------------------------------------------------------------------
DRIVE_SIZE=$(lsblk -dno SIZE "$DEVICE")
echo ""
echo -e "${RED}${BOLD}  ══════════════════════════════════════════════"
echo -e "  ⚠  WARNING — DESTRUCTIVE OPERATION"
echo -e "  ══════════════════════════════════════════════${NC}"
echo ""
echo "  Device : $DEVICE  ($DRIVE_SIZE)"
echo "  Action : Wipe all partitions, create one encrypted LUKS2 partition"
echo ""
echo "  ALL DATA ON $DEVICE WILL BE PERMANENTLY ERASED."
echo ""
echo -e "${RED}  Type the device name  ${BOLD}${DEVICE}${NC}${RED}  to confirm:${NC}"
read -r CONFIRM_DEVICE
[[ "$CONFIRM_DEVICE" == "$DEVICE" ]] || { warn "Confirmation didn't match. Aborted."; exit 0; }

# ---------------------------------------------------------------------------
# Choose unlock method
# ---------------------------------------------------------------------------
echo ""
echo "  Unlock method:"
echo "    1) Keyfile  — stored at $LUKS_KEYFILE on this server's SSD."
echo "                  Drive auto-unlocks on reboot. No typing required."
echo "                  Best for a headless server."
echo "    2) Password — prompted at every boot."
echo "                  Best if physical SSD theft is also a concern."
echo "    3) Both     — password as primary, keyfile for auto-unlock."
echo "                  Most flexible."
echo ""
ask "Choice (1/2/3, default: 3):"
read -r UNLOCK_MODE
UNLOCK_MODE="${UNLOCK_MODE:-3}"

[[ "$UNLOCK_MODE" =~ ^[123]$ ]] || err "Invalid choice."

USE_KEYFILE=false
USE_PASSWORD=false
case "$UNLOCK_MODE" in
    1) USE_KEYFILE=true ;;
    2) USE_PASSWORD=true ;;
    3) USE_KEYFILE=true; USE_PASSWORD=true ;;
esac

if [[ "$USE_PASSWORD" == true ]]; then
    echo ""
    ask "Enter LUKS passphrase (used to unlock the drive):"
    read -rs LUKS_PASS; echo ""
    ask "Confirm passphrase:"
    read -rs LUKS_PASS2; echo ""
    [[ "$LUKS_PASS" == "$LUKS_PASS2" ]] || err "Passphrases don't match."
    [[ -z "$LUKS_PASS" ]] && err "Passphrase cannot be empty."
fi

# ---------------------------------------------------------------------------
# Wipe and repartition
# ---------------------------------------------------------------------------
echo ""
log "Wiping partition table on $DEVICE ..."
wipefs -a "$DEVICE"
sleep 1

log "Creating new GPT partition table with single partition ..."
parted "$DEVICE" --script mklabel gpt mkpart primary ext4 0% 100%
partprobe "$DEVICE"
sleep 2

# Determine partition name (sda→sda1, nvme0n1→nvme0n1p1, etc.)
if [[ "$DEVICE" =~ nvme ]]; then
    PARTITION="${DEVICE}p1"
else
    PARTITION="${DEVICE}1"
fi

[[ -b "$PARTITION" ]] || err "Partition $PARTITION not found after partitioning."
log "Partition created: $PARTITION"

# ---------------------------------------------------------------------------
# LUKS2 format
# ---------------------------------------------------------------------------
echo ""
log "Formatting LUKS2 container on $PARTITION ..."

if [[ "$USE_PASSWORD" == true ]]; then
    echo -n "$LUKS_PASS" | cryptsetup luksFormat \
        --type luks2 \
        --cipher aes-xts-plain64 \
        --key-size 512 \
        --hash sha256 \
        --label "$LUKS_NAME" \
        "$PARTITION" -
else
    # Will add keyfile as the sole key below
    # Need a temporary passphrase to bootstrap, replaced by keyfile
    TMP_PASS=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 64)
    echo -n "$TMP_PASS" | cryptsetup luksFormat \
        --type luks2 \
        --cipher aes-xts-plain64 \
        --key-size 512 \
        --hash sha256 \
        --label "$LUKS_NAME" \
        "$PARTITION" -
fi

log "LUKS2 container created."

# ---------------------------------------------------------------------------
# Generate and add keyfile
# ---------------------------------------------------------------------------
if [[ "$USE_KEYFILE" == true ]]; then
    log "Generating keyfile at $LUKS_KEYFILE ..."
    mkdir -p "$(dirname "$LUKS_KEYFILE")"
    dd if=/dev/urandom of="$LUKS_KEYFILE" bs=4096 count=1 status=none
    chmod 400 "$LUKS_KEYFILE"
    chown root:root "$LUKS_KEYFILE"

    if [[ "$USE_PASSWORD" == true ]]; then
        # Add keyfile as a second slot (password stays as slot 0)
        echo -n "$LUKS_PASS" | cryptsetup luksAddKey "$PARTITION" "$LUKS_KEYFILE" -
        log "Keyfile added as LUKS key slot 1 (password remains in slot 0)."
    else
        # Add keyfile, then remove temp password
        echo -n "$TMP_PASS" | cryptsetup luksAddKey "$PARTITION" "$LUKS_KEYFILE" -
        echo -n "$TMP_PASS" | cryptsetup luksRemoveKey "$PARTITION" -
        log "Keyfile is the sole key (no passphrase set)."
    fi
fi

# ---------------------------------------------------------------------------
# Open the LUKS container and format filesystem
# ---------------------------------------------------------------------------
log "Opening LUKS container as /dev/mapper/$LUKS_NAME ..."
if [[ "$USE_KEYFILE" == true ]]; then
    cryptsetup open --key-file "$LUKS_KEYFILE" "$PARTITION" "$LUKS_NAME"
else
    echo -n "$LUKS_PASS" | cryptsetup open "$PARTITION" "$LUKS_NAME" -
fi

log "Formatting ext4 filesystem inside LUKS container ..."
mkfs.ext4 -L "$DRIVE_LABEL" "/dev/mapper/$LUKS_NAME"
log "Filesystem created."

# ---------------------------------------------------------------------------
# Mount
# ---------------------------------------------------------------------------
mkdir -p "$MOUNT_POINT"
mount "/dev/mapper/$LUKS_NAME" "$MOUNT_POINT"
log "Mounted at $MOUNT_POINT"

# ---------------------------------------------------------------------------
# Update /etc/crypttab
# ---------------------------------------------------------------------------
PARTITION_UUID=$(blkid -o value -s UUID "$PARTITION")
[[ -z "$PARTITION_UUID" ]] && err "Could not read UUID from $PARTITION"

# Remove old entry if it exists
sed -i "/^${LUKS_NAME}\s/d" /etc/crypttab 2>/dev/null || true

if [[ "$USE_KEYFILE" == true ]]; then
    echo "${LUKS_NAME}  UUID=${PARTITION_UUID}  ${LUKS_KEYFILE}  luks" >> /etc/crypttab
else
    echo "${LUKS_NAME}  UUID=${PARTITION_UUID}  none  luks" >> /etc/crypttab
fi
log "Added entry to /etc/crypttab"

# ---------------------------------------------------------------------------
# Update /etc/fstab
# ---------------------------------------------------------------------------
# Remove old entries for this mount point or old UUIDs
cp /etc/fstab /etc/fstab.bak.$(date +%Y%m%d_%H%M%S)
sed -i "\|${MOUNT_POINT}|d" /etc/fstab 2>/dev/null || true

echo "" >> /etc/fstab
echo "# Encrypted external drive — setup-luks-drive.sh $(date)" >> /etc/fstab
echo "/dev/mapper/${LUKS_NAME}  ${MOUNT_POINT}  ext4  defaults,nofail,x-systemd.device-timeout=30  0  2" >> /etc/fstab
log "Added entry to /etc/fstab"

# ---------------------------------------------------------------------------
# Rebuild initramfs so boot process knows about crypttab
# ---------------------------------------------------------------------------
log "Updating initramfs (this takes a moment) ..."
update-initramfs -u -k all 2>&1 | tail -5
log "Initramfs updated."

# ---------------------------------------------------------------------------
# Recreate directory structure
# ---------------------------------------------------------------------------
MAIN_USER=$(getent passwd 1000 | cut -d: -f1 2>/dev/null || echo "")
log "Creating directory structure ..."
mkdir -p \
    "$MOUNT_POINT/media" \
    "$MOUNT_POINT/uploads" \
    "$MOUNT_POINT/databases" \
    "$MOUNT_POINT/archives" \
    "$MOUNT_POINT/downloads" \
    "$MOUNT_POINT/app-data"

if [[ -n "$MAIN_USER" ]]; then
    chown -R "$MAIN_USER:$MAIN_USER" "$MOUNT_POINT"
    log "Ownership set to $MAIN_USER"
fi

# ---------------------------------------------------------------------------
# Print LUKS key slot summary
# ---------------------------------------------------------------------------
echo ""
echo "  LUKS key slots:"
cryptsetup luksDump "$PARTITION" | grep -A2 "Keyslots" || cryptsetup luksDump "$PARTITION" | grep -i "key slot"

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
PARTITION_UUID=$(blkid -o value -s UUID "$PARTITION")
echo ""
echo "============================================================="
echo "  Setup complete!"
echo "============================================================="
echo ""
df -h "$MOUNT_POINT"
echo ""
echo "  LUKS device  : $PARTITION  →  /dev/mapper/$LUKS_NAME"
echo "  UUID         : $PARTITION_UUID"
echo "  Mount point  : $MOUNT_POINT"
if [[ "$USE_KEYFILE" == true ]]; then
echo "  Keyfile      : $LUKS_KEYFILE  (root read-only)"
echo ""
echo "  The drive will auto-unlock and mount on reboot via:"
echo "    /etc/crypttab  →  unlocked with keyfile"
echo "    /etc/fstab     →  mounted at $MOUNT_POINT"
fi
if [[ "$USE_PASSWORD" == true ]]; then
echo ""
echo "  ⚠  IMPORTANT: your LUKS passphrase is the only other way to"
echo "     recover the drive if the keyfile is lost. Back it up in"
echo "     your password manager NOW."
fi
echo ""
echo "  Manual commands:"
echo "    Unlock:  cryptsetup open --key-file $LUKS_KEYFILE $PARTITION $LUKS_NAME"
echo "    Lock:    umount $MOUNT_POINT && cryptsetup close $LUKS_NAME"
echo "    Status:  cryptsetup status $LUKS_NAME"
echo ""
echo "  Reboot to verify auto-unlock works before trusting this setup."
echo ""
