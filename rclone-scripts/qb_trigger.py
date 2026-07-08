#!/usr/bin/env python3
"""
Called by qBittorrent's "Run external program on torrent completion" hook.

qBittorrent WebUI -> Options -> Downloads -> "Run external program on torrent completion":
    python3 /root/rclone-scripts/qb_trigger.py "%L" "%F" "%N"

%L = category, %F = content path (file or folder), %N = torrent name
"""
import sys
import sqlite3

DB_PATH = "/root/rclone-scripts/queue.db"
ALLOWED_CATEGORIES = ("Filmy", "Serialy")


def main():
    if len(sys.argv) < 4:
        sys.exit(1)

    category = sys.argv[1]
    filepath = sys.argv[2]
    name = sys.argv[3]

    if category not in ALLOWED_CATEGORIES:
        sys.exit(0)

    conn = sqlite3.connect(DB_PATH, timeout=10.0)
    c = conn.cursor()
    c.execute("""
        CREATE TABLE IF NOT EXISTS jobs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            category TEXT,
            filepath TEXT,
            name TEXT,
            status TEXT DEFAULT 'pending',
            timestamp DATETIME DEFAULT CURRENT_TIMESTAMP
        )
    """)
    c.execute(
        "INSERT INTO jobs (category, filepath, name) VALUES (?, ?, ?)",
        (category, filepath, name),
    )
    conn.commit()
    conn.close()


if __name__ == "__main__":
    main()
