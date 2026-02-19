"""Upload completed qBittorrent downloads to Backblaze B2.

1. Link: hard links manual category items from completed/<subdir>/ to
   /media/arr/<subdir>/ (items where all files have st_nlink == 1, meaning
   Sonarr/Radarr haven't touched them).
2. Upload: scans import directories (/media/arr/tv/, /media/arr/movies/) for
   files to upload. Falls back to completed/ for uncategorized downloads.
3. Propagate: copies .uploaded markers from import dirs back to completed/
   items (by inode match), so the cleanup timer can eventually remove them.

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


def needs_linking(item):
    """Check if a completed item needs hard linking to import dir.

    Returns True if all files have link count 1 (no hard links exist).
    Sonarr/Radarr-managed items will have link count > 1 because they
    create hard links into the import directory.
    """
    item = Path(item)
    if item.is_file():
        return os.stat(item).st_nlink == 1
    for f in item.rglob("*"):
        if f.is_file() and os.stat(f).st_nlink > 1:
            return False
    return True


def link_to_import_dir(completed_dir, import_base, subdirs):
    """Hard link manual category items to import directories.

    Scans completed/<subdir>/ for items where all files have st_nlink == 1
    (manual downloads, not yet linked by Sonarr/Radarr). Creates hard links
    in /media/arr/<subdir>/ preserving directory structure.
    """
    for subdir in subdirs:
        src_dir = Path(completed_dir) / subdir
        dst_dir = Path(import_base) / subdir
        if not src_dir.exists():
            continue

        for item in sorted(src_dir.iterdir()):
            if item.name.endswith(".uploaded"):
                continue
            if Path(f"{item}.uploaded").exists():
                continue
            if not needs_linking(item):
                continue

            if item.is_file():
                dst = dst_dir / item.name
                if not dst.exists():
                    os.link(item, dst)
                    print(f"Linked: {item.name} -> {dst}")
            elif item.is_dir():
                for f in item.rglob("*"):
                    if not f.is_file():
                        continue
                    rel = f.relative_to(item)
                    dst = dst_dir / item.name / rel
                    if not dst.exists():
                        dst.parent.mkdir(parents=True, exist_ok=True)
                        os.link(f, dst)
                print(f"Linked: {item.name}/ -> {dst_dir / item.name}/")


def propagate_markers(completed_dir, import_base, subdirs):
    """Propagate .uploaded markers from import dirs to completed/ items.

    For each item in completed/<subdir>/ without an .uploaded marker,
    collects file inodes and checks if those inodes have .uploaded markers
    in the import dir. If all do, marks the completed item as uploaded.

    This works for both arr-managed items (different names in import dir,
    same inodes) and manual items (same names, same inodes).
    """
    for subdir in subdirs:
        src_dir = Path(completed_dir) / subdir
        import_dir = Path(import_base) / subdir
        if not src_dir.exists() or not import_dir.exists():
            continue

        # Build a set of inodes that have .uploaded markers in the import dir
        uploaded_inodes = set()
        for marker in import_dir.rglob("*.uploaded"):
            source = marker.with_suffix("")
            if source.exists() and source.is_file():
                try:
                    uploaded_inodes.add(os.stat(source).st_ino)
                except OSError:
                    continue

        if not uploaded_inodes:
            continue

        for item in sorted(src_dir.iterdir()):
            if item.name.endswith(".uploaded"):
                continue
            if Path(f"{item}.uploaded").exists():
                continue

            # Collect inodes for this completed item
            item_inodes = set()
            if item.is_file():
                try:
                    item_inodes.add(os.stat(item).st_ino)
                except OSError:
                    continue
            elif item.is_dir():
                for f in item.rglob("*"):
                    if f.is_file():
                        try:
                            item_inodes.add(os.stat(f).st_ino)
                        except OSError:
                            continue

            if not item_inodes:
                continue

            # All file inodes must have .uploaded markers in import dir
            if item_inodes.issubset(uploaded_inodes):
                mark_uploaded(item)
                print(f"Propagated marker: {item.name}")


def main():
    completed_dir = os.environ["COMPLETED_DIR"]
    extracted_dir = os.environ["EXTRACTED_DIR"]
    import_base = os.environ["IMPORT_BASE"]
    b2_remote = os.environ["B2_REMOTE"]
    categories = parse_categories(os.environ["CATEGORIES"])

    # Deduplicate subdirs — multiple categories can map to the same subdir
    # (e.g. tv-sonarr and tv both map to "tv")
    subdirs = sorted(set(categories.values()))
    category_dirs = {f"{completed_dir}/{subdir}" for subdir in subdirs}

    # Step 1: hard link manual category items to import dirs
    link_to_import_dir(completed_dir, import_base, subdirs)

    # Step 2: upload from import directories (nice names from *arr + manual links)
    for subdir in subdirs:
        scan_import_dir(
            f"{import_base}/{subdir}",
            f"{subdir}/",
            b2_remote,
            extracted_dir,
        )

    # Step 3: upload uncategorized downloads (torrent names)
    scan_completed_dir(
        completed_dir,
        "downloads/",
        b2_remote,
        extracted_dir,
        category_dirs,
    )

    # Step 4: propagate .uploaded markers from import dirs to completed/ items
    propagate_markers(completed_dir, import_base, subdirs)


if __name__ == "__main__":
    main()
