#!/usr/bin/env bash
#
# setup.sh - installs and enables the qBittorrent -> rclone -> Google Drive
# media pipeline (rclone-mount.service + worker.service).
#
# Works two ways:
#   1. Run directly as root (e.g. inside a Proxmox LXC with no sudo):
#        ./setup.sh
#   2. Run as a normal user with sudo available:
#        sudo ./setup.sh
#
# Safe to re-run: it will not clobber an existing rclone remote config,
# and re-copies scripts/units idempotently.

set -euo pipefail

# ---------------------------------------------------------------------------
# 0. Resolve how we run privileged commands (raw root vs sudo)
# ---------------------------------------------------------------------------
if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
    echo "==> Running as root directly (no sudo needed)."
elif command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
    echo "==> Not root, will use sudo for privileged steps."
else
    echo "ERROR: not running as root and 'sudo' is not installed/available." >&2
    echo "Install sudo first, or re-run this script as root." >&2
    exit 1
fi

run() {
    # helper: run a command with sudo prefix if needed
    if [ -n "$SUDO" ]; then
        $SUDO "$@"
    else
        "$@"
    fi
}

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_DIR="/root/rclone-scripts"
SYSTEMD_DIR="/etc/systemd/system"
LOG_DIR="/var/log/rclone"
MOUNT_POINT="/mnt/gdrive"

echo "==> Repo directory detected as: ${REPO_DIR}"

# ---------------------------------------------------------------------------
# 1. Install dependencies
# ---------------------------------------------------------------------------
echo "==> Installing dependencies (rclone, python3, fuse3, qbittorrent-nox)..."

run apt-get update -y

# rclone: use official install script (keeps it current; apt's rclone is often stale)
if ! command -v rclone >/dev/null 2>&1; then
    echo "==> Installing rclone via official script..."
    curl -fsSL https://rclone.org/install.sh | run bash
else
    echo "==> rclone already installed ($(rclone version | head -1))."
fi

run apt-get install -y \
    python3 \
    python3-sqlite \
    fuse3 \
    qbittorrent-nox \
    curl

# ---------------------------------------------------------------------------
# 2. Create directories
# ---------------------------------------------------------------------------
echo "==> Creating directories..."
run mkdir -p "$INSTALL_DIR"
run mkdir -p "$LOG_DIR"
run mkdir -p "$MOUNT_POINT"

# ---------------------------------------------------------------------------
# 3. Copy scripts into place
# ---------------------------------------------------------------------------
echo "==> Copying worker scripts to ${INSTALL_DIR}..."
run cp "${REPO_DIR}/rclone-scripts/qb_trigger.py" "${INSTALL_DIR}/qb_trigger.py"
run cp "${REPO_DIR}/rclone-scripts/worker.py" "${INSTALL_DIR}/worker.py"
run chmod +x "${INSTALL_DIR}/qb_trigger.py" "${INSTALL_DIR}/worker.py"

# ---------------------------------------------------------------------------
# 4. rclone remote check (does NOT overwrite existing config/secrets)
# ---------------------------------------------------------------------------
RCLONE_CONF="$([ -n "$SUDO" ] && echo "/root/.config/rclone/rclone.conf" || echo "$HOME/.config/rclone/rclone.conf")"

if run test -f "$RCLONE_CONF"; then
    echo "==> Existing rclone.conf found at ${RCLONE_CONF} — leaving it untouched."
    if run rclone listremotes | grep -q "^googledrive:"; then
        echo "    Remote 'googledrive:' is configured."
    else
        echo "    WARNING: 'googledrive:' remote not found in existing config."
        echo "    Run: rclone config   (to add it, name it 'googledrive')"
    fi
else
    echo "==> No rclone.conf found."
    echo "    You need to configure the 'googledrive' remote manually:"
    echo "      rclone config"
    echo "    (create a remote literally named 'googledrive' to match the units/scripts,"
    echo "     or edit REMOTE in worker.py and the mount unit if you use a different name)"
fi

# ---------------------------------------------------------------------------
# 5. Install systemd units
# ---------------------------------------------------------------------------
echo "==> Installing systemd unit files..."
run cp "${REPO_DIR}/systemd/rclone-mount.service" "${SYSTEMD_DIR}/rclone-mount.service"
run cp "${REPO_DIR}/systemd/worker.service" "${SYSTEMD_DIR}/worker.service"

echo "==> Reloading systemd daemon..."
run systemctl daemon-reload

echo "==> Enabling services (start on boot)..."
run systemctl enable rclone-mount.service
run systemctl enable worker.service

# ---------------------------------------------------------------------------
# 6. Start services (mount first, then worker)
# ---------------------------------------------------------------------------
echo "==> Starting rclone-mount.service..."
run systemctl restart rclone-mount.service
sleep 3

if run systemctl is-active --quiet rclone-mount.service; then
    echo "    rclone-mount.service is active."
else
    echo "    WARNING: rclone-mount.service did not start cleanly. Check:"
    echo "      journalctl -u rclone-mount.service -n 50 --no-pager"
fi

echo "==> Starting worker.service..."
run systemctl restart worker.service
sleep 2

if run systemctl is-active --quiet worker.service; then
    echo "    worker.service is active."
else
    echo "    WARNING: worker.service did not start cleanly. Check:"
    echo "      journalctl -u worker.service -n 50 --no-pager"
fi

# ---------------------------------------------------------------------------
# 7. Reminders
# ---------------------------------------------------------------------------
cat <<'EOF'

==> Setup complete. Manual steps still required:

1. Configure the rclone remote if not already done:
     rclone config
   Name it "googledrive" (or update REMOTE in worker.py + the mount unit
   to match whatever name you used).

2. Point qBittorrent at the trigger script:
   WebUI -> Options -> Downloads -> "Run external program on torrent completion":
     python3 /root/rclone-scripts/qb_trigger.py "%L" "%F" "%N"
   Make sure your categories are named exactly "Filmy" and "Serialy"
   (case-sensitive, matches qb_trigger.py).

3. Check logs:
     journalctl -u rclone-mount.service -f
     journalctl -u worker.service -f
     tail -f /var/log/rclone/mount.log
     tail -f /var/log/rclone/worker.log

EOF

echo "==> Done."
