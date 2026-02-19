"""Register qBittorrent download categories via API.

Runs once after qBittorrent starts. Creates or updates categories
with their save paths so downloads are organized into subdirectories.
Categories persist in qBittorrent's database, so this is idempotent.

Environment variables:
  QBT_API_URL    - qBittorrent API base URL (e.g. http://localhost:8080/api/v2)
  COMPLETED_DIR  - base directory for completed downloads
  CATEGORIES     - comma-separated name:subdir pairs (e.g. tv-sonarr:tv,radarr:movies)
"""

import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request


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


def wait_for_api(api_url, timeout=30):
    """Wait for qBittorrent API to become ready.

    Polls /app/version once per second up to timeout.
    Returns True if the API responded, False on timeout.
    """
    for _ in range(timeout):
        try:
            urllib.request.urlopen(f"{api_url}/app/version", timeout=2)
            return True
        except (urllib.error.URLError, OSError):
            time.sleep(1)
    return False


def create_or_update_category(api_url, name, save_path):
    """Create a qBittorrent category, or update it if it already exists.

    Returns True if the category is correctly configured (created, updated,
    or already exists with the correct save path).
    """
    seen_conflict = False
    for endpoint in ("createCategory", "editCategory"):
        try:
            data = urllib.parse.urlencode(
                {
                    "category": name,
                    "savePath": save_path,
                }
            ).encode()
            req = urllib.request.Request(
                f"{api_url}/torrents/{endpoint}",
                data=data,
                method="POST",
            )
            urllib.request.urlopen(req, timeout=10)
            return True
        except urllib.error.HTTPError as e:
            # 409: category already exists (create) or save path unchanged (edit).
            # Both are expected when the category is already correctly configured.
            if e.code == 409:
                seen_conflict = True
                continue
            return False
        except (urllib.error.URLError, OSError):
            continue
    return seen_conflict


def main():
    api_url = os.environ["QBT_API_URL"]
    completed_dir = os.environ["COMPLETED_DIR"]
    categories = parse_categories(os.environ["CATEGORIES"])

    if not wait_for_api(api_url):
        print("qBittorrent API not ready after 30 seconds", file=sys.stderr)
        sys.exit(1)

    for name, subdir in categories.items():
        save_path = f"{completed_dir}/{subdir}"
        if create_or_update_category(api_url, name, save_path):
            print(f"Category: {name} -> {subdir}/")
        else:
            print(f"Failed to create/update category: {name}", file=sys.stderr)


if __name__ == "__main__":
    main()
