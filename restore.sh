#!/bin/bash
# =============================================================================
#  SERVER RESTORE — restore.sh
# =============================================================================
#  Interactive helper for restoring from your Backblaze B2 backup.
#  Run as root:  sudo /opt/server-backup/restore.sh
#
#  On a brand-new server, you'll need to:
#    1. Install restic  (apt install restic)
#    2. Copy your .env file to /opt/server-backup/.env
#    3. Run this script
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; }
hdr()  { echo -e "\n${BOLD}${CYAN}$1${NC}"; }

# ---------------------------------------------------------------------------
# Root check
# ---------------------------------------------------------------------------
[[ "$EUID" -ne 0 ]] && { err "Please run as root:  sudo $0"; exit 1; }

# ---------------------------------------------------------------------------
# Load credentials
# ---------------------------------------------------------------------------
ENV_FILE="$SCRIPT_DIR/.env"
if [[ ! -f "$ENV_FILE" ]]; then
    err ".env file not found at $ENV_FILE"
    echo ""
    echo "  On a fresh server, manually create $ENV_FILE with:"
    echo ""
    echo "    export B2_ACCOUNT_ID=\"your-key-id\""
    echo "    export B2_ACCOUNT_KEY=\"your-app-key\""
    echo "    export RESTIC_REPOSITORY=\"b2:your-bucket-name\""
    echo "    export RESTIC_PASSWORD=\"your-encryption-password\""
    echo ""
    echo "  Then re-run this script."
    exit 1
fi
# shellcheck source=/dev/null
source "$ENV_FILE"

command -v restic &>/dev/null || { err "restic not found. Install it first:  apt install restic"; exit 1; }

# ---------------------------------------------------------------------------
# Helper: pick a snapshot interactively
# ---------------------------------------------------------------------------
pick_snapshot() {
    echo ""
    log "Fetching snapshot list..."
    restic snapshots --tag server-backup
    echo ""
    echo -e "${BLUE}Enter a snapshot ID (or 'latest' for the most recent):${NC}"
    read -r SNAPSHOT_ID
    echo "$SNAPSHOT_ID"
}

# ---------------------------------------------------------------------------
# Menu
# ---------------------------------------------------------------------------
while true; do
    echo ""
    echo "============================================================="
    echo "  Restore Menu  —  Repository: $RESTIC_REPOSITORY"
    echo "============================================================="
    echo ""
    echo "  1)  List all snapshots"
    echo "  2)  Restore a snapshot to /  (full system restore)"
    echo "  3)  Restore a snapshot to a custom directory"
    echo "  4)  Restore a specific file or folder from a snapshot"
    echo "  5)  Mount repository for manual browsing"
    echo "  6)  Show snapshot details"
    echo "  7)  Check repository integrity"
    echo "  q)  Quit"
    echo ""
    echo -n "  Choice: "
    read -r CHOICE

    case "$CHOICE" in

    # -----------------------------------------------------------------------
    1)  hdr "All Snapshots"
        restic snapshots --tag server-backup
        ;;

    # -----------------------------------------------------------------------
    2)  hdr "Full System Restore"
        warn "This will OVERWRITE system files. Only use this on a fresh OS install."
        warn "Your running system will NOT be fully replaced until you reboot."
        echo ""
        SNAP=$(pick_snapshot)
        echo ""
        echo -e "${RED}Confirm full restore of snapshot '${SNAP}' to / ? (type YES to confirm):${NC}"
        read -r CONFIRM
        if [[ "$CONFIRM" == "YES" ]]; then
            log "Starting full restore — this will take a while..."
            restic restore "$SNAP" \
                --target / \
                --exclude /proc \
                --exclude /sys \
                --exclude /dev \
                --exclude /run \
                --verbose
            echo ""
            log "Restore complete."
            echo ""
            echo "  Next steps:"
            echo "    1. Review /tmp/backup-state/packages.txt and reinstall packages:"
            echo "         dpkg --set-selections < /tmp/backup-state/packages.txt"
            echo "         apt-get dselect-upgrade"
            echo "    2. Reboot: sudo reboot"
        else
            warn "Restore cancelled."
        fi
        ;;

    # -----------------------------------------------------------------------
    3)  hdr "Restore Snapshot to Directory"
        SNAP=$(pick_snapshot)
        echo ""
        echo -e "${BLUE}Target directory (e.g. /mnt/restore or /tmp/restore):${NC}"
        read -r TARGET_DIR

        [[ -z "$TARGET_DIR" ]] && { warn "No directory specified."; continue; }

        mkdir -p "$TARGET_DIR"
        log "Restoring snapshot '$SNAP' to $TARGET_DIR ..."
        restic restore "$SNAP" \
            --target "$TARGET_DIR" \
            --verbose
        log "Restore complete → $TARGET_DIR"
        echo ""
        echo "  Your files are at: $TARGET_DIR"
        echo "  The original paths are preserved, e.g.:"
        echo "    $TARGET_DIR/etc/nginx/nginx.conf"
        echo "    $TARGET_DIR/home/youruser/app/"
        ;;

    # -----------------------------------------------------------------------
    4)  hdr "Restore Specific Path"
        SNAP=$(pick_snapshot)
        echo ""
        echo -e "${BLUE}Path to restore (e.g. /home/youruser/app or /etc/nginx):${NC}"
        read -r RESTORE_PATH

        [[ -z "$RESTORE_PATH" ]] && { warn "No path specified."; continue; }

        echo -e "${BLUE}Target directory (default: /tmp/restore):${NC}"
        read -r TARGET_DIR
        TARGET_DIR="${TARGET_DIR:-/tmp/restore}"

        mkdir -p "$TARGET_DIR"
        log "Restoring $RESTORE_PATH from snapshot '$SNAP' to $TARGET_DIR ..."
        restic restore "$SNAP" \
            --target "$TARGET_DIR" \
            --include "$RESTORE_PATH" \
            --verbose
        log "Done → $TARGET_DIR"
        ;;

    # -----------------------------------------------------------------------
    5)  hdr "Mount Repository"
        echo ""
        echo -e "${BLUE}Mount point (default: /mnt/restic-backup):${NC}"
        read -r MOUNT_POINT
        MOUNT_POINT="${MOUNT_POINT:-/mnt/restic-backup}"

        mkdir -p "$MOUNT_POINT"
        log "Mounting repository at $MOUNT_POINT ..."
        log "Browse with:  ls $MOUNT_POINT/snapshots/"
        log "Press Ctrl+C when done to unmount."
        echo ""
        restic mount "$MOUNT_POINT" || true
        ;;

    # -----------------------------------------------------------------------
    6)  hdr "Snapshot Details"
        SNAP=$(pick_snapshot)
        echo ""
        restic snapshots "$SNAP" --verbose
        ;;

    # -----------------------------------------------------------------------
    7)  hdr "Repository Integrity Check"
        warn "This may take several minutes depending on repo size."
        echo ""
        restic check
        log "Check complete."
        ;;

    # -----------------------------------------------------------------------
    q|Q)
        echo ""
        log "Exiting."
        exit 0
        ;;

    *)  warn "Unknown option: '$CHOICE'" ;;

    esac
done
