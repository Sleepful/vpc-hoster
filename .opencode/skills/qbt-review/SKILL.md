---
name: qbt-review
description: Review qBittorrent systemd services on the builder machine — check health, logs, timers, and env vars
---

## qBittorrent Service Review

Quick review of the three Python-based qBittorrent companion services running on the builder machine. All commands run over SSH to `builder`.

### 1. Overall health check

```sh
ssh builder "systemctl --failed --no-pager"
ssh builder "systemctl list-timers qbt-* --no-pager"
```

Zero failed units is expected. Two timers should be listed:
- `qbt-upload-b2.timer` — fires every 2 minutes
- `qbt-cleanup.timer` — fires every 10 minutes

### 2. Check recent logs (all three services)

```sh
ssh builder "journalctl -u qbt-categories -u qbt-upload-b2 -u qbt-cleanup --no-pager -n 80 --since '30 minutes ago'"
```

What to look for:
- **qbt-categories**: `Category: radarr -> movies/` and `Category: tv-sonarr -> tv/`. Runs once after qBittorrent starts.
- **qbt-upload-b2**: Should complete quickly when nothing to upload. When uploading, prints `Uploading: <name> -> <dest>` and `Uploaded: <name>`. Errors show as `Upload failed: <path>`.
- **qbt-cleanup**: Reports `Seeding (N days left): <name>`, `Skipping (not yet uploaded): <name>`, or `Removing (Nd seeding, avg N KB/s < 2 KB/s): <name>`. Ends with `Cleanup done: X removed, Y seeding, Z skipped`.

### 3. Check individual service logs (when debugging)

```sh
ssh builder "journalctl -u qbt-categories --no-pager -n 20 --since '1 hour ago'"
ssh builder "journalctl -u qbt-upload-b2 --no-pager -n 50 --since '1 hour ago'"
ssh builder "journalctl -u qbt-cleanup --no-pager -n 50 --since '1 hour ago'"
```

### 4. Verify environment variables

```sh
ssh builder "systemctl show qbt-categories -p Environment --no-pager"
ssh builder "systemctl show qbt-upload-b2 -p Environment -p EnvironmentFiles --no-pager"
ssh builder "systemctl show qbt-cleanup -p Environment --no-pager"
```

Expected env vars per service:
- **qbt-categories**: `QBT_API_URL`, `COMPLETED_DIR`, `CATEGORIES`
- **qbt-upload-b2**: `COMPLETED_DIR`, `EXTRACTED_DIR`, `IMPORT_BASE`, `B2_REMOTE`, `CATEGORIES` + `EnvironmentFiles` pointing to rclone B2 credentials
- **qbt-cleanup**: `QBT_API_URL`, `COMPLETED_DIR`, `IMPORT_BASE`, `MIN_SEEDING_DAYS`, `MIN_AVG_RATE`, `CATEGORIES`

### 5. Manually trigger a service

```sh
ssh builder "systemctl start qbt-categories && journalctl -u qbt-categories --no-pager -n 15 --since '1 minute ago'"
ssh builder "systemctl start qbt-upload-b2 && journalctl -u qbt-upload-b2 --no-pager -n 50 --since '1 minute ago'"
ssh builder "systemctl start qbt-cleanup && journalctl -u qbt-cleanup --no-pager -n 50 --since '1 minute ago'"
```

### 6. Run the test suite (local, no SSH)

```sh
just test
```

Runs pytest against `machines/builder/src/service/qbittorrent/tests/`. All tests should pass.

### 7. Relevant files

| File | Purpose |
|------|---------|
| `machines/builder/src/service/qbittorrent/default.nix` | NixOS module — systemd units, env vars, timers |
| `machines/builder/src/service/qbittorrent/categories.py` | Category registration via qBittorrent API |
| `machines/builder/src/service/qbittorrent/upload.py` | Upload to B2 from import dirs and completed/ |
| `machines/builder/src/service/qbittorrent/cleanup.py` | Seeding lifecycle, hardlink removal, pruning |
| `machines/builder/src/service/qbittorrent/tests/` | pytest suite for all three scripts |
