#!/usr/bin/env python3
"""
Upload worker: polls queue.db for pending jobs enqueued by qb_trigger.py and
uploads them to Google Drive using `rclone copyto` via subprocess.

IMPORTANT: uploads are done with subprocess.run() calling the rclone binary
directly (NOT shutil.copy against the /mnt/gdrive VFS mount). Going through
the VFS mount for writes caused uncapped cache growth (~8GB+ RSS) because
every write got buffered through the mount's own VFS cache on top of
whatever the mount service was already caching for reads. copyto talks to
the remote directly and keeps memory flat.
"""
import os
import shutil
import sqlite3
import subprocess
import time
import logging

DB_PATH = "/root/rclone-scripts/queue.db"
REMOTE = "googledrive:mediaPlex"  # adjust to match your rclone remote name/path
POLL_INTERVAL = 15  # seconds
RCLONE_LOG = "/var/log/rclone/worker.log"

RCLONE_FLAGS = [
    "--transfers", "2",
    "--checkers", "4",
    "--drive-chunk-size", "256M",
    "--tpslimit", "8",
    "--drive-stop-on-upload-limit",
    "--log-level", "INFO",
    "--log-file", RCLONE_LOG,
]

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
log = logging.getLogger("worker")


def get_connection():
    return sqlite3.connect(DB_PATH, timeout=10.0)


def fetch_next_job(conn):
    c = conn.cursor()
    c.execute(
        "SELECT id, category, filepath, name FROM jobs "
        "WHERE status = 'pending' ORDER BY id ASC LIMIT 1"
    )
    return c.fetchone()


def mark_status(conn, job_id, status):
    c = conn.cursor()
    c.execute("UPDATE jobs SET status = ? WHERE id = ?", (status, job_id))
    conn.commit()


def upload(category, filepath, name):
    """
    Uploads filepath (file or directory) to REMOTE/<category>/<name> using
    `rclone copyto`, run as a subprocess so memory is owned and released by
    the rclone process itself rather than accumulating in this script.
    """
    dest = f"{REMOTE}/{category}/{name}"

    cmd = ["rclone", "copyto", filepath, dest] + RCLONE_FLAGS
    log.info("Uploading: %s -> %s", filepath, dest)

    result = subprocess.run(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )

    if result.returncode != 0:
        log.error("rclone copyto failed (exit %s): %s", result.returncode, result.stdout)
        return False

    log.info("Upload succeeded: %s", name)
    return True


def cleanup_source(filepath):
    """Remove the local file/dir after a successful upload."""
    try:
        if os.path.isdir(filepath):
            shutil.rmtree(filepath)
        elif os.path.exists(filepath):
            os.remove(filepath)
    except OSError as e:
        log.warning("Could not remove source %s: %s", filepath, e)


def main():
    log.info("Worker started, polling %s every %ss", DB_PATH, POLL_INTERVAL)
    while True:
        conn = get_connection()
        try:
            job = fetch_next_job(conn)
            if job:
                job_id, category, filepath, name = job
                mark_status(conn, job_id, "processing")

                if not os.path.exists(filepath):
                    log.error("Source path missing, skipping: %s", filepath)
                    mark_status(conn, job_id, "error_missing_source")
                else:
                    ok = upload(category, filepath, name)
                    if ok:
                        mark_status(conn, job_id, "done")
                        # Uncomment to delete local copy after successful upload:
                        # cleanup_source(filepath)
                    else:
                        mark_status(conn, job_id, "error")
        finally:
            conn.close()

        time.sleep(POLL_INTERVAL)


if __name__ == "__main__":
    main()
