#!/usr/bin/env python3
"""List active torrents with seeding stats from qBittorrent API."""

import json
import subprocess
import sys
import time


def fetch_torrents(target):
    result = subprocess.run(
        ["ssh", target, "curl -sf http://localhost:8080/api/v2/torrents/info"],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0 or not result.stdout.strip():
        print("Failed to fetch torrents from qBittorrent API", file=sys.stderr)
        sys.exit(1)
    return json.loads(result.stdout)


def format_size(bytes_val):
    if bytes_val >= 1073741824:
        return f"{bytes_val / 1073741824:.1f}G"
    elif bytes_val >= 1048576:
        return f"{bytes_val / 1048576:.0f}M"
    else:
        return f"{bytes_val / 1024:.0f}K"


def main():
    target = sys.argv[1] if len(sys.argv) > 1 else "builder"
    now = int(time.time())
    torrents = fetch_torrents(target)

    # Filter to completed torrents
    completed = [t for t in torrents if t.get("completion_on", 0) > 0]

    if not completed:
        print("No active torrents")
        return

    rows = []
    for t in completed:
        name = t["name"][:60]
        size = format_size(t["size"])
        uploaded = format_size(t["uploaded"])

        seeding_secs = now - t["completion_on"]
        days = seeding_secs // 86400
        hours = (seeding_secs % 86400) // 3600

        if days > 0:
            seeding = f"{days}d"
        else:
            seeding = f"{hours}h"

        if seeding_secs > 0:
            avg_rate = t["uploaded"] / seeding_secs / 1024
        else:
            avg_rate = 0

        rows.append((name, size, seeding, f"{avg_rate:.1f} KB/s", uploaded))

    # Sort by avg rate ascending (slowest first, most likely to be removed)
    rows.sort(key=lambda r: float(r[3].split()[0]))

    # Calculate column widths
    headers = ("NAME", "SIZE", "SEEDING", "AVG RATE", "UPLOADED")
    widths = [max(len(h), max(len(r[i]) for r in rows)) for i, h in enumerate(headers)]

    # Print table
    header_line = "  ".join(h.ljust(w) for h, w in zip(headers, widths))
    print(header_line)
    for row in rows:
        print("  ".join(val.ljust(w) for val, w in zip(row, widths)))


if __name__ == "__main__":
    main()
