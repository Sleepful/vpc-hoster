"""Upload completed qBittorrent downloads to Backblaze B2.

Primary: scans import directories (/media/arr/tv/, /media/arr/movies/) for
files with nice names from Sonarr/Radarr.
Fallback: scans completed/ for uncategorized downloads (torrent names).

Triggered by qbt-upload-b2.timer every 2 minutes.

Environment variables:
  COMPLETED_DIR  - base directory for completed downloads
  EXTRACTED_DIR  - temporary directory for archive extraction
  IMPORT_BASE    - base path for import directories (e.g. /media/arr)
  B2_REMOTE      - rclone remote with bucket (e.g. b2:entertainment-netmount)
  CATEGORIES     - comma-separated name:subdir pairs (e.g. tv-sonarr:tv,radarr:movies)
  RCLONE_CONFIG_B2_*  - rclone B2 credentials (via EnvironmentFile)
"""

import os
import shutil
import subprocess
import sys
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


def rclone_copy(src, dest):
    """Upload src to dest via rclone copy.

    Returns True on success, False on failure.
    """
    result = subprocess.run(
        [
            "rclone",
            "copy",
            str(src),
            dest,
            "--transfers",
            "4",
            "--checksum",
            "--stats",
            "30s",
            "--stats-log-level",
            "NOTICE",
        ],
    )
    if result.returncode != 0:
        print(f"Upload failed: {src}")
        return False
    return True


def rclone_check(src, dest):
    """Check if src already exists at dest with correct checksum.

    Uses rclone check --one-way so only src→dest is verified.
    Returns True if the file exists with matching checksum.
    """
    result = subprocess.run(
        ["rclone", "check", str(src), dest, "--checksum", "--one-way"],
        capture_output=True,
    )
    return result.returncode == 0


def extract_archive(archive, extract_to):
    """Extract a single archive (zip/rar) into extract_to via unar."""
    print(f"Extracting: {archive.name}")
    subprocess.run(
        ["unar", "-f", "-o", str(extract_to), str(archive)],
        check=True,
    )


def mark_uploaded(item):
    """Create .uploaded marker file next to item.

    Returns True on success. Warns and returns False on permission error.
    """
    marker = Path(f"{item}.uploaded")
    try:
        marker.touch()
        return True
    except PermissionError:
        print(f"WARNING: Cannot create upload marker: {marker} (permission denied)")
        print(f'Fix ownership: chown -R media:media "{item.parent}"')
        return False


def process_item(item, b2_base, b2_remote, extracted_dir):
    """Process a single item (file or directory) for upload.

    Checks if already on B2, extracts archives if present, uploads
    the original item and any extracted contents, then creates an
    .uploaded marker.

    Returns True on success, False on failure.
    """
    item = Path(item)
    name = item.name

    # Compute B2 destination: directories get a named subfolder,
    # files go directly into the base path
    if item.is_dir():
        dest = f"{b2_remote}/{b2_base}{name}"
    else:
        dest = f"{b2_remote}/{b2_base}"

    # Check if already on B2 with correct checksum — avoids re-uploading
    # when a previous upload succeeded but the marker was not created
    if rclone_check(item, dest):
        print(f"Already on B2 (checksum match): {name}")
        mark_uploaded(item)
        return True

    work_dir = Path(extracted_dir) / name
    has_archives = False

    # Clean up any previous extraction attempt
    if work_dir.exists():
        shutil.rmtree(work_dir)
    work_dir.mkdir(parents=True)

    # Single file archive
    if item.is_file() and item.suffix.lower() in (".zip", ".rar"):
        extract_archive(item, work_dir)
        has_archives = True

    # Directory containing archives (top-level only)
    if item.is_dir():
        for child in item.iterdir():
            if child.is_file() and child.suffix.lower() in (".zip", ".rar"):
                extract_archive(child, work_dir)
                has_archives = True

    # Upload extracted contents then clean up
    if has_archives:
        print(f"Uploading extracted: {name}")
        rclone_copy(work_dir, f"{b2_remote}/{b2_base}{name}")
    shutil.rmtree(work_dir, ignore_errors=True)

    # Upload the original item
    print(f"Uploading: {name} -> {dest}")
    if not rclone_copy(item, dest):
        return False

    mark_uploaded(item)
    print(f"Uploaded: {name}")
    return True


def scan_import_dir(directory, b2_base, b2_remote, extracted_dir):
    """Scan an import directory for items to upload.

    Recurses into subdirectories to handle show/season structure
    (e.g. /media/arr/tv/Show Name/Season 1/episode.mkv).
    """
    directory = Path(directory)
    if not directory.exists():
        return

    for item in sorted(directory.iterdir()):
        if item.name.endswith(".uploaded"):
            continue
        if Path(f"{item}.uploaded").exists():
            continue

        if item.is_dir():
            scan_import_dir(item, f"{b2_base}{item.name}/", b2_remote, extracted_dir)
        else:
            process_item(item, b2_base, b2_remote, extracted_dir)


def scan_completed_dir(directory, b2_base, b2_remote, extracted_dir, category_dirs):
    """Scan completed/ for uncategorized downloads.

    Skips category subdirectories (those are handled via import dirs).
    """
    directory = Path(directory)
    if not directory.exists():
        return

    for item in sorted(directory.iterdir()):
        if item.name.endswith(".uploaded"):
            continue
        if Path(f"{item}.uploaded").exists():
            continue
        if item.is_dir() and str(item) in category_dirs:
            continue

        process_item(item, b2_base, b2_remote, extracted_dir)


def main():
    completed_dir = os.environ["COMPLETED_DIR"]
    extracted_dir = os.environ["EXTRACTED_DIR"]
    import_base = os.environ["IMPORT_BASE"]
    b2_remote = os.environ["B2_REMOTE"]
    categories = parse_categories(os.environ["CATEGORIES"])

    category_dirs = {f"{completed_dir}/{subdir}" for subdir in categories.values()}

    # Primary: scan import directories (nice names from Sonarr/Radarr)
    for subdir in categories.values():
        scan_import_dir(
            f"{import_base}/{subdir}",
            f"{subdir}/",
            b2_remote,
            extracted_dir,
        )

    # Fallback: scan uncategorized downloads (torrent names)
    scan_completed_dir(
        completed_dir,
        "downloads/",
        b2_remote,
        extracted_dir,
        category_dirs,
    )


if __name__ == "__main__":
    main()
