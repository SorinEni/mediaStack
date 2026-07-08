# media-stack

qBittorrent -> rclone -> Google Drive pipeline for a Plex media server,
running in a Proxmox LXC (Debian/Ubuntu).

## Flow

1. qBittorrent finishes a download in category `Filmy` or `Serialy`.
2. qBittorrent's "run on completion" hook calls `qb_trigger.py`, which
   enqueues a job (category, filepath, name) into a SQLite queue (`queue.db`).
3. `worker.py` polls the queue and uploads each job via
   `rclone copyto` (run as a subprocess, not through the VFS mount) to
   Google Drive.
4. `rclone-mount.service` separately mounts Google Drive at `/mnt/gdrive`
   for Plex to read from directly.

Both stages run as systemd services with `Requires=`/`After=` ordering so
the worker won't start uploading before the mount is ready.

## Why `subprocess.run` + `rclone copyto` instead of `shutil.copy`

Uploads used to go through `/mnt/gdrive` (the VFS mount) using `shutil`.
That caused `worker.py`'s memory usage to balloon to ~8GB, because writes
through the VFS mount get buffered by rclone's own cache on top of
whatever the mount already caches for reads/dir-listings — the mount's
cache settings are tuned for Plex's read patterns, not for one-shot
uploads. Calling `rclone copyto` directly as a subprocess keeps upload
memory bounded by rclone's own process, using explicit flags:

```
--transfers 2 --checkers 4 --drive-chunk-size 256M --tpslimit 8 --drive-stop-on-upload-limit
```

## Repo layout

```
rclone-scripts/
  qb_trigger.py     # invoked by qBittorrent on torrent completion
  worker.py         # polls queue.db, uploads via rclone copyto
systemd/
  rclone-mount.service
  worker.service
scripts/
  setup.sh              # installs deps, copies files, enables services
  backup-configs.sh     # backs up Plex/qBittorrent config into backups/
backups/
  qbittorrent/          # gitignored - contains credentials
  plex/                 # gitignored - contains claim token etc.
```

## Setup on a fresh box

Works whether you're root directly (e.g. Proxmox LXC, no sudo) or a
normal user with sudo:

```bash
git clone <this-repo-url>
cd media-stack
./scripts/setup.sh
```

The script:
- installs rclone (official installer), python3, fuse3, qbittorrent-nox
- copies `qb_trigger.py` / `worker.py` to `/root/rclone-scripts/`
- installs and enables `rclone-mount.service` + `worker.service`
- does **not** touch or overwrite an existing `rclone.conf`

### Manual steps after `setup.sh` (not automated, on purpose)

1. **rclone remote**: run `rclone config` and create a remote named
   `googledrive` (or update `REMOTE` in `worker.py` and the remote name
   in `rclone-mount.service` if you use a different name).
2. **qBittorrent hook**: WebUI -> Options -> Downloads -> "Run external
   program on torrent completion":
   ```
   python3 /root/rclone-scripts/qb_trigger.py "%L" "%F" "%N"
   ```
   Category names must be exactly `Filmy` and `Serialy` (case-sensitive).

## Backing up Plex/qBittorrent config

```bash
./scripts/backup-configs.sh
```

Copies qBittorrent's config dir and Plex's `Preferences.xml` into
`backups/`, timestamped, plus a `latest` copy for easy diffing. This
directory is **gitignored by default** because both files contain
credentials (qBittorrent WebUI auth) or tokens (Plex claim token). If you
want them in git history, you'll need to `git add -f` deliberately and
understand what you're pushing — this repo does not encrypt anything for
you.

## Secrets

Nothing under `backups/` or any `rclone.conf` / `qBittorrent.ini` is
committed — see `.gitignore`. Handle those files yourself outside of git,
or push them somewhere you're comfortable with (private repo, encrypted
vault, etc.).

## Logs

```bash
journalctl -u rclone-mount.service -f
journalctl -u worker.service -f
tail -f /var/log/rclone/mount.log
tail -f /var/log/rclone/worker.log
```
