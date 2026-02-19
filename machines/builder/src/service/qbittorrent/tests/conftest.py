"""Shared test configuration for qBittorrent scripts."""

import sys
from pathlib import Path

# Add the parent directory (qbittorrent/) to sys.path so tests can
# import the scripts directly: `from upload import process_item`
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
