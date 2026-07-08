#!/usr/bin/env bash
#
# backup-configs.sh - copies qBittorrent and Plex config into this repo's
# backups/ folder so they get versioned in git alongside the rest of the
# stack. Secrets (WebUI password hash, tokens) are NOT stripped here —
# .gitignore is responsible for keeping the sensitive bits out of the repo.
# Review backups/ before committing if you're unsure what's in these files.
#
# Usage: ./backup-configs.sh
#
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKUP_DIR="${REPO_DIR}/backups"
TIMESTAMP="$(date +%Y-%m-%d_%H%M%S)"

QBT_CONFIG_CANDIDATES=(
    "/root/.config/qBittorrent"
    "$HOME/.config/qBittorrent"
)

PLEX_CONFIG_CANDIDATES=(
    "/var/lib/plexmediaserver/Library/Application Support/Plex Media Server/Preferences.xml"
    "/root/.local/share/plexmediaserver/Library/Application Support/Plex Media Server/Preferences.xml"
)

mkdir -p "${BACKUP_DIR}/qbittorrent" "${BACKUP_DIR}/plex"

echo "==> Backing up qBittorrent config..."
found_qbt=0
for path in "${QBT_CONFIG_CANDIDATES[@]}"; do
    if [ -d "$path" ]; then
        dest="${BACKUP_DIR}/qbittorrent/config_${TIMESTAMP}"
        mkdir -p "$dest"
        cp -a "$path"/. "$dest"/
        echo "    Copied ${path} -> ${dest}"
        # also keep a "latest" copy that's easy to diff in git history
        rm -rf "${BACKUP_DIR}/qbittorrent/latest"
        cp -a "$path" "${BACKUP_DIR}/qbittorrent/latest"
        found_qbt=1
        break
    fi
done
if [ "$found_qbt" -eq 0 ]; then
    echo "    WARNING: no qBittorrent config directory found in known locations."
    echo "    Edit QBT_CONFIG_CANDIDATES in this script if yours lives elsewhere."
fi

echo "==> Backing up Plex Preferences.xml..."
found_plex=0
for path in "${PLEX_CONFIG_CANDIDATES[@]}"; do
    if [ -f "$path" ]; then
        dest="${BACKUP_DIR}/plex/Preferences_${TIMESTAMP}.xml"
        cp -a "$path" "$dest"
        cp -a "$path" "${BACKUP_DIR}/plex/Preferences_latest.xml"
        echo "    Copied ${path} -> ${dest}"
        found_plex=1
        break
    fi
done
if [ "$found_plex" -eq 0 ]; then
    echo "    WARNING: Plex Preferences.xml not found in known locations."
    echo "    Edit PLEX_CONFIG_CANDIDATES in this script if yours lives elsewhere."
    echo "    (Full Plex library metadata/DB is intentionally NOT backed up here —"
    echo "     it's large and not suited to git. This only grabs Preferences.xml,"
    echo "     which has server settings like claim token, library paths, transcoder"
    echo "     settings, etc.)"
fi

echo "==> Done. Review ${BACKUP_DIR} before committing:"
echo "      git status"
echo "    Preferences.xml and qBittorrent's config contain tokens/credentials —"
echo "    make sure .gitignore covers what you don't want pushed to GitHub."
