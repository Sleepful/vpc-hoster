# Media Pipeline

How media files flow from torrent download to playback in Jellyfin.

All services run on the **builder** machine.

## Flow

```
qBittorrent          rclone FUSE mount        Jellyfin / Copyparty
-----------          ----------------         --------------------

 Add torrent
     |
     v
 downloading/        (in-progress pieces)
     |
     | completion
     v
 completed/  ------> qbt-upload-b2.service
     |                    |
     | seeding            | extract archives (zip/rar)
     | (7 days)           | upload extracted to B2
     |                    | upload original to B2
     |                    | mark .uploaded
     |                    v
     |               b2:entertainment-netmount/downloads/
     |                    |
     |                    | rclone FUSE mount
     |                    v
     |               /media/b2/downloads/
     |                    |
     |                    +---> Jellyfin (scans every 15 min)
     |                    +---> Copyparty (browse/WebDAV)
     |
     | torrent removed after 7 days
     v
 qbt-cleanup.service
     |
     | deletes local files + .uploaded markers
     v
 (disk freed)
```

## Services

All services are accessible from the nginx dashboard at `http://builder/` (port 80), which redirects to each service's native port. See `web.nix` for the dashboard and redirect configuration.

| Service | Port | Dashboard path | Purpose |
|---------|------|----------------|---------|
| qBittorrent WebUI | 8080 | `/qbt/` | Torrent management |
| qBittorrent peer | 6881 | — | BitTorrent incoming connections |
| Jellyfin | 8096 | `/jellyfin/` | Media streaming |
| Copyparty | 3923 | `/files/` | File browser / WebDAV |

## Directories on builder

| Path | Purpose |
|------|---------|
| `/var/lib/qBittorrent/downloading` | In-progress downloads (TempPath) |
| `/var/lib/qBittorrent/completed` | Finished downloads, seeding here |
| `/var/lib/qBittorrent/extracted` | Temporary archive extraction (ephemeral) |
| `/media/b2` | rclone FUSE mount of `b2:entertainment-netmount` |
| `/media/b2/downloads` | Where uploaded media lands on B2 |

## Systemd units

| Unit | Type | Trigger | What it does |
|------|------|---------|--------------|
| `qbt-upload-b2.path` | path | `completed/` becomes non-empty | Starts the upload service |
| `qbt-upload-b2.service` | oneshot | Path unit or boot | Extracts archives, uploads to B2, marks `.uploaded` |
| `qbt-cleanup.timer` | timer | Every 10 min (5 min after boot) | Starts the cleanup service |
| `qbt-cleanup.service` | oneshot | Timer | Deletes orphaned files no longer tracked by qBittorrent |
| `rclone-b2-mount.service` | notify | Boot | Mounts B2 bucket at `/media/b2` |

## Upload details

- Archives (`.zip`, `.rar`) are extracted using `unar` to a temporary directory, uploaded, then the extracted copy is deleted immediately. The original archive stays for seeding.
- `rclone copy` uses `--checksum` to verify integrity and `--stats 30s` for progress logging.
- A `.uploaded` marker file is created next to each item after a successful upload. Subsequent runs skip marked items.
- On failure, the service logs the error, skips to the next item, and retries after 30 seconds (`Restart=on-failure`).

## Cleanup details

- Queries qBittorrent's API (`/api/v2/torrents/info`) for active torrent content paths.
- Only deletes files that have **both**: a `.uploaded` marker (confirmed uploaded to B2) **and** are no longer tracked by qBittorrent (seeding complete).
- Never deletes files that haven't been uploaded yet.

## rclone mount

- Cache mode: `full` (files cached to local disk on access)
- Cache size: 150 GB max, 7 day max age
- Directory cache: 1 minute (controls how quickly new B2 content appears)
- `--allow-other` lets Jellyfin and Copyparty (running as `media` user) access the root-owned mount.

## Monitoring

```sh
just qbt-logs                                    # follow all qbt service logs
ssh builder 'systemctl status qbt-upload-b2'     # check upload service status
ssh builder 'systemctl status qbt-cleanup'       # check cleanup service status
ssh builder 'systemctl list-timers qbt-*'        # check timer schedule
```

## Manual operations

| Action | Command |
|--------|---------|
| Free disk early | Remove torrent in WebUI, then `ssh builder 'systemctl start qbt-cleanup'` |
| Retry failed upload | `ssh builder 'systemctl start qbt-upload-b2'` |
| Force Jellyfin rescan | Jellyfin dashboard > Scheduled Tasks > Scan Media Library > Run |
| Check B2 contents | `ssh builder 'set -a; . /run/secrets/rendered/rclone_b2_env; set +a; rclone ls b2:entertainment-netmount/downloads/'` |

## Disk usage during seeding

During the 7-day seeding window, a file exists in two places: once locally in `completed/` (for seeding) and once on B2 (the uploaded copy). The upload to B2 goes directly through the API — it does **not** pass through the rclone FUSE mount at `/media/b2`, so it does not trigger VFS caching.

The rclone VFS cache only loads a file when something reads it through the mount:

- **Jellyfin library scan** — reads directory listings and metadata only. Does not cache file contents.
- **Jellyfin playback** — streams the file through the FUSE mount, pulling it into the VFS cache. This creates a second local copy (seeding copy + cache copy).
- **Copyparty browsing** — directory listings only. No file caching unless you download or preview a file.

In the worst case (playing a file while it's still seeding), the same file exists on disk twice: once in `completed/` and once in the VFS cache. This resolves after the 7-day seeding window when cleanup deletes the `completed/` copy. The VFS cache is capped at 150 GB with a 7-day max age and self-manages.

## NixOS modules

- `machines/builder/src/service/qbittorrent.nix` — download, upload, extraction, cleanup
- `machines/builder/src/service/rclone-b2.nix` — FUSE mount of B2
- `machines/builder/src/service/jellyfin.nix` — media server
- `machines/builder/src/service/copyparty.nix` — file browser / WebDAV
- `machines/builder/src/service/secrets.nix` — B2 credentials (SOPS/age)
