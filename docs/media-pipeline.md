# Media Pipeline

How media files flow from torrent download to playback in Jellyfin.

All services run on the **builder** machine as the shared `media` user.

## Flow

```
Sonarr/Radarr/Prowlarr  qBittorrent          Sonarr/Radarr import     Upload + B2
----------------------  -----------          --------------------     ----------

 Search series/movies
     |
     | finds episodes/movies via indexers (Prowlarr)
     | sends torrent to qBittorrent
     v
                     Add torrent
                         |
                         v
                     downloading/        (in-progress pieces)
                         |
                         | completion (sorted by category)
                         v
                     completed/tv/       (Sonarr → tv-sonarr)
                     completed/movies/   (Radarr → radarr)
                     completed/          (uncategorized)
                         |
                         | Sonarr/Radarr detect completion
                         | hard link + rename to import dirs
                         v
                     /media/arr/tv/Show Name/Season 1/S01E01.mkv
                     /media/arr/movies/Movie Name (2024)/movie.mkv
                         |
                         +---> Jellyfin (local, fast playback)
                         |
                         +---> qbt-upload-b2.service
                         |       uploads to B2 with nice names:
                         |         tv/Show Name/Season 1/S01E01.mkv
                         |         movies/Movie Name (2024)/movie.mkv
                         |       uncategorized → downloads/ on B2
                         v
                     b2:entertainment-netmount/tv/...
                     b2:entertainment-netmount/movies/...
                         |
                         | rclone FUSE mount
                         v
                     /media/b2/tv/...
                     /media/b2/movies/...
                         |
                         +---> Jellyfin (B2 fallback after cleanup)
                         +---> Copyparty (browse/WebDAV)

After 7 days seeding:
    qbt-cleanup.service
        removes torrent from qBittorrent
        deletes files from completed/
        deletes hard links from /media/arr/tv/ and /media/arr/movies/
        Jellyfin falls back to B2 copies
```

## Services

All services run as the `media` user and are accessible from the nginx dashboard at `http://builder/` (port 80), which redirects to each service's native port. See `web.nix` for the dashboard and redirect configuration.

| Service | Port | Dashboard path | Purpose |
|---------|------|----------------|---------|
| qBittorrent WebUI | 8080 | `/qbt/` | Torrent management |
| qBittorrent peer | 6881 | — | BitTorrent incoming connections |
| Jellyfin | 8096 | `/jellyfin/` | Media streaming |
| Copyparty | 3923 | `/files/` | File browser / WebDAV |
| rclone RC / Web GUI | 5572 | `/rclone/` | B2 mount cache stats, prefetch, transfer monitoring |
| Sonarr | 8989 | `/sonarr/` | TV series search and download manager |
| Radarr | 7878 | `/radarr/` | Movie search and download manager |
| Prowlarr | 9696 | `/prowlarr/` | Indexer manager for Sonarr/Radarr |

## Directories on builder

| Path | Purpose |
|------|---------|
| `/var/lib/qBittorrent/downloading` | In-progress downloads (TempPath) |
| `/var/lib/qBittorrent/completed` | Finished downloads, seeding here (uncategorized) |
| `/var/lib/qBittorrent/completed/tv` | TV series from Sonarr (`tv-sonarr` category) |
| `/var/lib/qBittorrent/completed/movies` | Movies from Radarr (`radarr` category) |
| `/var/lib/qBittorrent/extracted` | Temporary archive extraction (ephemeral) |
| `/media/arr/tv` | Sonarr root folder — hard links from completed/tv/ with clean names |
| `/media/arr/movies` | Radarr root folder — hard links from completed/movies/ with clean names |
| `/media/b2` | rclone FUSE mount of `b2:entertainment-netmount` |
| `/media/b2/tv` | TV uploads on B2 (clean names) |
| `/media/b2/movies` | Movie uploads on B2 (clean names) |
| `/media/b2/downloads` | Uncategorized uploads on B2 (torrent names) |

## Hard links

All media pipeline services run as the `media` user. This allows Sonarr/Radarr to
create hard links (not copies) when importing completed downloads:

```
completed/tv/Parks...x265-SiQ/episode.mkv  (inode 12345, link count = 2)
    |
    hard link → /media/arr/tv/Parks and Recreation/Season 1/S01E01.mkv  (same inode)
```

Hard links cost zero extra disk — both paths point to the same data on disk.
When cleanup deletes the `completed/` copy after 7 days, it also removes the
hard link from `/media/arr/` and prunes empty directories.

Requirements for hard links to work:
- Same user owns both source and destination (all services run as `media`)
- Same filesystem (`/dev/sda1` for both `/var/lib/qBittorrent/` and `/media/`)
- Hard links cannot cross to B2 — the rclone FUSE mount is a separate filesystem

## Systemd units

| Unit | Type | Trigger | What it does |
|------|------|---------|--------------|
| `qbt-upload-b2.timer` | timer | Every 2 min (1 min after boot) | Starts the upload service |
| `qbt-upload-b2.service` | oneshot | Timer | Scans /media/arr/tv/, /media/arr/movies/ (nice names), then completed/ (uncategorized). Extracts archives, uploads to B2, marks `.uploaded` |
| `qbt-categories.service` | oneshot | Boot (after qBittorrent) | Creates download categories via API |
| `qbt-cleanup.timer` | timer | Every 10 min (5 min after boot) | Starts the cleanup service |
| `qbt-cleanup.service` | oneshot | Timer | Removes torrents after seeding period, deletes from completed/ and /media/arr/, prunes empty dirs |
| `rclone-b2-mount.service` | notify | Boot | Mounts B2 bucket at `/media/b2` |

## Upload details

- Primary scan: `/media/arr/tv/` → B2 `tv/`, `/media/arr/movies/` → B2 `movies/` (files with nice names from Sonarr/Radarr)
- Fallback scan: `completed/` → B2 `downloads/` (uncategorized downloads with torrent names)
- Archives (`.zip`, `.rar`) are extracted using `unar` to a temporary directory, uploaded, then the extracted copy is deleted immediately. The original archive stays for seeding.
- `rclone copy` uses `--checksum` to verify integrity and `--stats 30s` for progress logging.
- A `.uploaded` marker file is created next to each item after a successful upload. Subsequent runs skip marked items.
- On failure, the service logs the error and skips to the next item. The timer retries in 2 minutes.

## Cleanup details

- Queries qBittorrent's API (`/api/v2/torrents/info`) for active torrent content paths.
- Only deletes files that have a `.uploaded` marker (confirmed uploaded to B2).
- For seeded torrents past the seeding period: removes the torrent from qBittorrent, deletes files from `completed/`, finds and removes hard links in `/media/arr/tv/` and `/media/arr/movies/` by inode, prunes empty directories.
- Orphaned files (torrent manually removed from qBittorrent UI, but `.uploaded` marker exists): deletes immediately, including hard links.
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
cat /media/b2/tv/some-show/Season\ 1/episode.mkv > /dev/null

# Or from your Mac:
just b2-warm 'tv/Some Show/Season 1/episode.mkv'
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
| Check B2 contents | `just b2-ls tv/` or `just b2-ls movies/` |
| Browse B2 mount | `just b2-ls` (root) or `just b2-ls tv/Some Show/` (subdirectory) |
| Warm file before playback | `just b2-warm 'tv/Some Show/Season 1/episode.mkv'` |
| Check VFS cache stats | `just b2-cache` |
| Open rclone web GUI | `http://builder:5572` or dashboard link at `/rclone/` |

## Disk usage during seeding

During the 7-day seeding window, a file exists on disk once (hard link count = 2):
once in `completed/` (for seeding) and once in `/media/arr/tv/` or `/media/arr/movies/`
(for Jellyfin). These are hard links — same inode, zero extra disk usage. The file
also exists on B2 as a separate copy.

After cleanup (day 7), both local paths are deleted. Jellyfin falls back to the
B2 copy via the rclone FUSE mount at `/media/b2/`.

The rclone VFS cache only loads a file when something reads it through the mount:

- **Jellyfin library scan** — reads directory listings and metadata only. Does not cache file contents.
- **Jellyfin playback** — streams the file through the FUSE mount, pulling it into the VFS cache.
- **Copyparty browsing** — directory listings only. No file caching unless you download or preview a file.

The VFS cache is capped at 150 GB with a 7-day max age and self-manages.

## NixOS modules

- `machines/builder/src/service/qbittorrent.nix` — download, upload, extraction, cleanup
- `machines/builder/src/service/rclone-b2.nix` — FUSE mount of B2
- `machines/builder/src/service/jellyfin.nix` — media server (defines `media` user/group)
- `machines/builder/src/service/copyparty.nix` — file browser / WebDAV
- `machines/builder/src/service/secrets.nix` — B2 credentials (SOPS/age)
- `machines/builder/src/service/sonarr.nix` — TV series search and download
- `machines/builder/src/service/radarr.nix` — movie search and download
- `machines/builder/src/service/prowlarr.nix` — indexer manager

## Setup Sonarr/Prowlarr

Sonarr finds TV episodes on torrent indexers and sends them to qBittorrent for
download. Prowlarr manages indexer credentials and syncs them to Sonarr so you
only configure each indexer once. Sonarr hard links completed downloads into
`/media/arr/tv/` with clean names. The upload script reads from there to upload to B2.

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
4. Add Radarr as an application: Settings > Apps > Add > Radarr.
   - Prowlarr Server: `http://localhost:9696`
   - Radarr Server: `http://localhost:7878`
   - API Key: copy from Radarr (Settings > General > API Key)
   - Sync Level: Full Sync
   - Test and save.

### 2. Sonarr (`http://builder:8989`)

1. Set an authentication method (Settings > General > Authentication).
2. Add qBittorrent as a download client: Settings > Download Clients > Add > qBittorrent.
   - Host: `localhost`
   - Port: `8080`
   - Category: `tv-sonarr` (downloads will land in `completed/tv/`)
   - Leave username/password blank if qBittorrent doesn't require auth from localhost.
   - Test and save.
3. Set root folder to `/media/arr/tv`. Sonarr will hard link completed downloads
   here with clean names (e.g., `Parks and Recreation/Season 1/S01E01.mkv`).

### 3. Radarr (`http://builder:7878`)

1. Set an authentication method (Settings > General > Authentication).
2. Add qBittorrent as a download client: Settings > Download Clients > Add > qBittorrent.
   - Host: `localhost`
   - Port: `8080`
   - Category: `radarr` (downloads will land in `completed/movies/`)
   - Leave username/password blank if qBittorrent doesn't require auth from localhost.
   - Test and save.
3. Set root folder to `/media/arr/movies`. Radarr will hard link completed downloads
   here with clean names (e.g., `Movie Name (2024)/movie.mkv`).

### 4. Jellyfin (`http://builder:8096`)

Set up media libraries with multiple paths per type for local + B2 fallback:
- TV Shows library: `/media/arr/tv` (local, fast) + `/media/b2/tv` (B2, cold)
- Movies library: `/media/arr/movies` (local) + `/media/b2/movies` (B2)

Jellyfin merges multiple paths in one library. During the 7-day seeding window,
local copies serve fast playback. After cleanup, Jellyfin falls back to B2 copies.

### 5. Download a series (Sonarr)

1. Series > Add New > search by name.
2. Select the series, pick a quality profile, and set the root folder to `/media/arr/tv`.
3. On the series page, select the episodes or seasons you want.
4. Click "Search Selected" — Sonarr queries your indexers via Prowlarr, picks the
   best match, and sends the torrent to qBittorrent.
5. qBittorrent downloads to `downloading/`, moves to `completed/tv/` on finish
   (because of the `tv-sonarr` category).
6. Sonarr hard links the files to `/media/arr/tv/Show Name/Season X/` with clean names.
7. The upload script uploads from `/media/arr/tv/` to B2 `tv/`.

### 6. Download a movie (Radarr)

1. Movies > Add New > search by name.
2. Select the movie, pick a quality profile, and set the root folder to `/media/arr/movies`.
3. Click "Add Movie" then search for it, or toggle "Start search for missing movie"
   when adding.
4. Radarr queries your indexers via Prowlarr, picks the best match, and sends the
   torrent to qBittorrent.
5. qBittorrent downloads to `downloading/`, moves to `completed/movies/` on finish
   (because of the `radarr` category).
6. Radarr hard links the files to `/media/arr/movies/Movie Name (Year)/` with clean names.
7. The upload script uploads from `/media/arr/movies/` to B2 `movies/`.
