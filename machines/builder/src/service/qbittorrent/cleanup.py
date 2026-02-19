"""Clean up completed qBittorrent downloads after seeding.

Manages torrent seeding lifetime. For items that have been uploaded to B2
and seeded for >= MIN_SEEDING_DAYS with avg upload rate < MIN_AVG_RATE:
  - Removes the torrent from qBittorrent via API
  - Deletes files from completed/ (the seeding copy)
  - Finds and deletes hard links from import directories by inode
  - Prunes empty directories left behind
  - Cleans up orphaned .uploaded markers

Triggered by qbt-cleanup.timer every 10 minutes.

Environment variables:
  QBT_API_URL        - qBittorrent API base URL
  COMPLETED_DIR      - base directory for completed downloads
  IMPORT_BASE        - base path for import directories (e.g. /media/arr)
  MIN_SEEDING_DAYS   - minimum days to seed before considering removal
  MIN_AVG_RATE       - minimum avg upload rate in bytes/sec to keep seeding
  CATEGORIES         - comma-separated name:subdir pairs
"""

import json
import os
import shutil
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path


def parse_categories(env_value):
    """Parse CATEGORIES env var into a dict.

    Format: "tv-sonarr:tv,radarr:movies"
    Returns: {"tv-sonarr": "tv", "radarr": "movies"}
    """
    result = {}
    for pair in env_value.split(","):
        pair = pair.strip()
        if not pair:
            continue
        name, subdir = pair.split(":", 1)
        result[name.strip()] = subdir.strip()
    return result


def fetch_torrents(api_url):
    """Fetch all torrents from qBittorrent API.

    Returns a list of dicts with hash, content_path, completion_on,
    uploaded, and size. Returns None on failure.
    """
    try:
        resp = urllib.request.urlopen(f"{api_url}/torrents/info", timeout=10)
        data = json.loads(resp.read())
        return [
            {
                "hash": t["hash"],
                "content_path": t["content_path"],
                "completion_on": t["completion_on"],
                "uploaded": t["uploaded"],
                "size": t["size"],
            }
            for t in data
        ]
    except (urllib.error.URLError, OSError, json.JSONDecodeError, KeyError) as e:
        print(f"Failed to query qBittorrent API: {e}", file=sys.stderr)
        return None


def find_torrent_by_path(torrents, content_path):
    """Find a torrent entry matching the given content_path."""
    for t in torrents:
        if t["content_path"] == str(content_path):
            return t
    return None


def remove_torrent(api_url, torrent_hash):
    """Remove a torrent from qBittorrent (keeps files on disk).

    Returns True on success, False on failure.
    """
    try:
        data = urllib.parse.urlencode(
            {
                "hashes": torrent_hash,
                "deleteFiles": "false",
            }
        ).encode()
        req = urllib.request.Request(
            f"{api_url}/torrents/delete",
            data=data,
            method="POST",
        )
        urllib.request.urlopen(req, timeout=10)
        return True
    except (urllib.error.URLError, OSError):
        return False


def collect_inodes(item):
    """Collect inode numbers for all files in item (file or directory)."""
    item = Path(item)
    inodes = set()
    if item.is_file():
        try:
            inodes.add(os.stat(item).st_ino)
        except OSError:
            pass
    elif item.is_dir():
        for f in item.rglob("*"):
            if f.is_file():
                try:
                    inodes.add(os.stat(f).st_ino)
                except OSError:
                    continue
    return inodes


def remove_hardlinks(item, import_dirs):
    """Remove hard links in import directories that share inodes with item.

    When we delete from completed/, hard links in import dirs would keep
    the data alive (link count drops from 2 to 1). We explicitly find
    and delete them by inode number.
    """
    inodes = collect_inodes(item)
    if not inodes:
        return

    for import_dir in import_dirs:
        import_path = Path(import_dir)
        if not import_path.exists():
            continue
        for f in import_path.rglob("*"):
            if f.is_file():
                try:
                    if os.stat(f).st_ino in inodes:
                        f.unlink()
                except OSError:
                    continue

    prune_empty_dirs(import_dirs)


def prune_empty_dirs(directories):
    """Remove empty directories bottom-up in the given directories."""
    for d in directories:
        path = Path(d)
        if not path.exists():
            continue
        # Walk bottom-up so child dirs are removed before parents
        for dirpath in sorted(path.rglob("*"), reverse=True):
            if dirpath.is_dir():
                try:
                    dirpath.rmdir()  # Only succeeds if empty
                except OSError:
                    pass


def should_keep_seeding(torrent, now, min_age, min_avg_rate):
    """Determine if a torrent should keep seeding.

    Returns (keep_seeding: bool, reason: str or None).
    """
    age = now - torrent["completion_on"]

    if age < min_age:
        days_left = (min_age - age) // 86400
        return True, f"Seeding ({days_left} days left)"

    avg_rate = torrent["uploaded"] // age if age > 0 else 0

    if avg_rate >= min_avg_rate:
        avg_kbs = avg_rate // 1024
        return True, f"Seeding (active, avg {avg_kbs} KB/s)"

    return False, None


def cleanup_orphaned_markers(import_dirs):
    """Remove .uploaded markers in import dirs with no corresponding file."""
    for import_dir in import_dirs:
        path = Path(import_dir)
        if not path.exists():
            continue
        for marker in path.rglob("*.uploaded"):
            source = marker.with_suffix("")
            if not source.exists():
                marker.unlink(missing_ok=True)


def scan_dir(
    directory,
    torrents,
    api_url,
    now,
    min_age,
    min_avg_rate,
    import_dirs,
    category_dirs,
    stats,
):
    """Process items in a directory for cleanup.

    Checks each item's upload status and seeding metrics, removes
    torrents and files when ready, and cleans up hard links.
    """
    directory = Path(directory)
    if not directory.exists():
        return

    for item in sorted(directory.iterdir()):
        if item.name.endswith(".uploaded"):
            continue

        # Skip category subdirectories when scanning top-level completed/
        if item.is_dir() and str(item) in category_dirs:
            continue

        # Never delete files that haven't been uploaded to B2 yet
        if not Path(f"{item}.uploaded").exists():
            print(f"Skipping (not yet uploaded): {item.name}")
            stats["skipped"] += 1
            continue

        # Look up this item in qBittorrent's active torrents
        torrent = find_torrent_by_path(torrents, item)

        if torrent is not None:
            keep, reason = should_keep_seeding(torrent, now, min_age, min_avg_rate)
            if keep:
                print(f"{reason}: {item.name}")
                stats["seeding"] += 1
                continue

            # Stale torrent — log stats and remove from qBittorrent
            age = now - torrent["completion_on"]
            avg_rate = torrent["uploaded"] // age if age > 0 else 0
            avg_kbs = avg_rate // 1024
            days = age // 86400
            print(
                f"Removing ({days}d seeding, avg {avg_kbs} KB/s < 2 KB/s): {item.name}"
            )
            remove_torrent(api_url, torrent["hash"])
        else:
            print(f"Cleaning orphan: {item.name}")

        # Remove hard links in import directories before deleting source
        remove_hardlinks(item, import_dirs)

        # Delete the item and its upload marker
        if item.is_dir():
            shutil.rmtree(item, ignore_errors=True)
        else:
            item.unlink(missing_ok=True)
        Path(f"{item}.uploaded").unlink(missing_ok=True)
        stats["cleaned"] += 1


def main():
    api_url = os.environ["QBT_API_URL"]
    completed_dir = os.environ["COMPLETED_DIR"]
    import_base = os.environ["IMPORT_BASE"]
    min_seeding_days = int(os.environ["MIN_SEEDING_DAYS"])
    min_avg_rate = int(os.environ["MIN_AVG_RATE"])
    categories = parse_categories(os.environ["CATEGORIES"])

    min_age = min_seeding_days * 86400
    now = int(time.time())

    torrents = fetch_torrents(api_url)
    if torrents is None:
        print("Skipping cleanup")
        sys.exit(0)

    category_dirs = {f"{completed_dir}/{subdir}" for subdir in categories.values()}
    import_dirs = [f"{import_base}/{subdir}" for subdir in categories.values()]

    stats = {"cleaned": 0, "seeding": 0, "skipped": 0}

    # Scan uncategorized downloads and each category subdirectory
    scan_dir(
        completed_dir,
        torrents,
        api_url,
        now,
        min_age,
        min_avg_rate,
        import_dirs,
        category_dirs,
        stats,
    )
    for subdir in categories.values():
        scan_dir(
            f"{completed_dir}/{subdir}",
            torrents,
            api_url,
            now,
            min_age,
            min_avg_rate,
            import_dirs,
            set(),
            stats,  # No category dirs to skip inside subdirs
        )

    cleanup_orphaned_markers(import_dirs)

    print(
        f"Cleanup done: {stats['cleaned']} removed, {stats['seeding']} seeding, {stats['skipped']} skipped"
    )


if __name__ == "__main__":
    main()
