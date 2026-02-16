# Media Pipeline

How media files flow from torrent download to playback in Jellyfin.

All services run on the **builder** machine.

## Flow

```
Sonarr/Prowlarr      qBittorrent          rclone FUSE mount        Jellyfin / Copyparty
---------------      -----------          ----------------         --------------------

 Search series
     |
     | finds episodes via indexers (Prowlarr)
     | sends torrent to qBittorrent
     v
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
| rclone RC / Web GUI | 5572 | `/rclone/` | B2 mount cache stats, prefetch, transfer monitoring |
| Sonarr | 8989 | `/sonarr/` | TV series search and download manager |
| Prowlarr | 9696 | `/prowlarr/` | Indexer manager for Sonarr |

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

Core settings:
- Cache mode: `full` (files cached to local disk on access)
- Cache size: 150 GB max, 7 day max age
- Directory cache: 1 minute (controls how quickly new B2 content appears)
- `--allow-other` lets Jellyfin and Copyparty (running as `media` user) access the root-owned mount

### VFS cache tuning

Without read-ahead tuning, rclone only fetches bytes from B2 on demand — the player
requests a chunk, rclone fetches it from B2, delivers it, then waits for the next
request. For high-bitrate files this causes Jellyfin buffering on cold (uncached) files
because B2 can't deliver bytes fast enough for real-time playback.

The fix is proactive prefetching:

| Flag | Default | Ours | Why |
|------|---------|------|-----|
| `--buffer-size` | 16M | 512M | Per-file in-memory read buffer. Larger buffer = fewer round-trips to B2. |
| `--vfs-read-ahead` | 0 | 1G | Background prefetch beyond current read position. When Jellyfin starts playing, rclone pre-fetches the next 1G from B2 so data is ready before the player needs it. Key flag for smooth streaming. |
| `--vfs-read-chunk-streams` | 0 | 4 | Download 4 chunks in parallel instead of sequentially. Speeds up initial fill of the read-ahead buffer. |
| `--vfs-fast-fingerprint` | off | on | Cache validation uses size+modtime instead of hash. Avoids re-downloading files just to check if a cache entry is valid. |

Once a file is fully in VFS cache, all reads are local disk — no B2 latency.

### RC API and web GUI

The rclone mount exposes an HTTP API (RC) at port 5572 for cache observability.
The web GUI provides a visual dashboard for monitoring active transfers and bandwidth.
Accessible at `http://builder:5572` or via the nginx dashboard at `/rclone/`.

All RC endpoints require POST. Useful ones:
```sh
# VFS cache stats (size, open files, items cached)
curl -X POST http://localhost:5572/vfs/stats

# Active transfers (what's downloading right now, bandwidth)
curl -X POST http://localhost:5572/core/stats
```

To prefetch a file into VFS cache before playback, read it through the FUSE mount:
```sh
# Warm a single file (streams to /dev/null, VFS cache keeps the data)
cat /media/b2/downloads/Movies/some-movie.mkv > /dev/null

# Or from your Mac:
just b2-warm 'downloads/Movies/some-movie.mkv'
```

## Monitoring

```sh
just qbt-logs                                    # follow all qbt service logs
ssh builder 'systemctl status qbt-upload-b2'     # check upload service status
ssh builder 'systemctl status qbt-cleanup'       # check cleanup service status
ssh builder 'systemctl list-timers qbt-*'        # check timer schedule
just b2-cache                                    # VFS cache stats (size, items)
ssh builder 'journalctl -u rclone-b2-mount -f'   # rclone transfer logs (every 30s)
```

## Manual operations

| Action | Command |
|--------|---------|
| Free disk early | Remove torrent in WebUI, then `ssh builder 'systemctl start qbt-cleanup'` |
| Retry failed upload | `ssh builder 'systemctl start qbt-upload-b2'` |
| Force Jellyfin rescan | Jellyfin dashboard > Scheduled Tasks > Scan Media Library > Run |
| Check B2 contents | `just b2-ls downloads/` or `ssh builder 'set -a; . /run/secrets/rendered/rclone_b2_env; set +a; rclone ls b2:entertainment-netmount/downloads/'` |
| Browse B2 mount | `just b2-ls` (root) or `just b2-ls downloads/Movies/` (subdirectory) |
| Warm file before playback | `just b2-warm 'downloads/Movies/Some Movie (2024)/movie.mkv'` |
| Check VFS cache stats | `just b2-cache` |
| Open rclone web GUI | `http://builder:5572` or dashboard link at `/rclone/` |

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
- `machines/builder/src/service/sonarr.nix` — TV series search and download
- `machines/builder/src/service/prowlarr.nix` — indexer manager

## Setup Sonarr/Prowlarr

Sonarr finds TV episodes on torrent indexers and sends them to qBittorrent for
download. Prowlarr manages indexer credentials and syncs them to Sonarr so you
only configure each indexer once. Sonarr runs in search-only mode — it does not
move or rename downloaded files, leaving the existing B2 upload pipeline untouched.

After deploying, configure both services through their web UIs:

### 1. Prowlarr (`http://builder:9696`)

1. Set an authentication method (Settings > General > Authentication).
2. Add your torrent indexer(s): Indexers > Add Indexer. Search by name, fill in
   your credentials/API key, and test the connection.
3. Add Sonarr as an application: Settings > Apps > Add > Sonarr.
   - Prowlarr Server: `http://localhost:9696`
   - Sonarr Server: `http://localhost:8989`
   - API Key: copy from Sonarr (Settings > General > API Key)
   - Sync Level: Full Sync
   - Test and save. Prowlarr will push your indexers to Sonarr automatically.

### 2. Sonarr (`http://builder:8989`)

1. Set an authentication method (Settings > General > Authentication).
2. Add qBittorrent as a download client: Settings > Download Clients > Add > qBittorrent.
   - Host: `localhost`
   - Port: `8080`
   - Leave username/password blank if qBittorrent doesn't require auth from localhost.
   - Test and save.
3. Disable completed download handling so the B2 pipeline manages files:
   Settings > Download Clients > Completed Download Handling > uncheck "Remove".
4. Set a root folder when prompted (e.g. `/var/lib/qBittorrent/completed`). Sonarr
   requires one to track series, but it won't move files there in search-only mode.

### 3. Download a series

1. Series > Add New > search by name.
2. Select the series, pick a quality profile, and set the root folder.
3. On the series page, select the episodes or seasons you want.
4. Click "Search Selected" — Sonarr queries your indexers via Prowlarr, picks the
   best match, and sends the torrent to qBittorrent.
5. qBittorrent downloads to `downloading/`, moves to `completed/` on finish, and
   the existing `qbt-upload-b2` pipeline uploads to B2 as usual.
