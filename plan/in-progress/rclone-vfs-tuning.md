# rclone VFS tuning, RC API, and B2 cache observability

## Problem

Jellyfin streaming from B2 via the rclone FUSE mount buffers on cold
(uncached) files. Confirmed by warming a file via `cp` to local disk
then playing through the mount — playback was smooth, proving the
bottleneck is B2 download speed on first play, not the builder-to-Xbox
WiFi link.

Root cause: rclone's default VFS behavior fetches bytes on demand — the
player requests a chunk, rclone fetches it from B2, delivers it, waits.
For high-bitrate files B2 can't deliver fast enough for real-time.

## Solution

Proactive prefetching + parallel chunk downloads + cache observability.

## Changes made

### 1. VFS streaming performance (rclone-b2.nix)

| Flag | Default | Ours | Why |
|------|---------|------|-----|
| `--buffer-size` | 16M | 512M | Per-file in-memory read buffer. Fewer round-trips to B2. |
| `--vfs-read-ahead` | 0 | 1G | Background prefetch beyond read position. Key flag — rclone pre-fetches 1G from B2 so data is ready before Jellyfin needs it. |
| `--vfs-read-chunk-streams` | 0 (sequential) | 4 | Download 4 chunks in parallel. Speeds up initial fill of the read-ahead buffer. |
| `--vfs-fast-fingerprint` | off | on | Cache validation uses size+modtime instead of hash. Avoids re-downloading to verify cache entries. |

### 2. RC API + web GUI (rclone-b2.nix)

Added `--rc --rc-addr 0.0.0.0:5572 --rc-no-auth --rc-web-gui --rc-web-gui-no-open-browser`.

- Web GUI at `http://builder:5572` — visual dashboard for transfers and bandwidth.
- JSON API for scripting — all endpoints require POST.
- No auth — access restricted by firewall (LAN/Tailscale only).
- Nginx dashboard link at `/rclone/` redirects to `:5572`.

### 3. Transfer logging (rclone-b2.nix)

Added `--stats 30s --log-level INFO`. Transfer activity logged to
journald every 30s, visible via `journalctl -u rclone-b2-mount -f`.

### 4. Justfile recipes

- `just b2-ls [path]` — browse B2 mount contents from macOS.
- `just b2-cache` — show VFS cache stats via RC API (POST to `/vfs/stats`).
- `just b2-warm <path>` — prefetch file into VFS cache by reading through
  the FUSE mount (`cat ... > /dev/null`). VFS cache keeps the data.

### 5. Nginx dashboard (web.nix)

Added rclone link and redirect: `/rclone/` -> `http://$host:5572/`.

### 6. Shared packages (shared/base.nix)

Added `jq` to all machines (needed by `b2-cache` recipe).

### 7. Documentation (docs/media-pipeline.md)

- Added rclone RC to services table (port 5572).
- New "VFS cache tuning" section with flag comparison table.
- New "RC API and web GUI" section with endpoint examples.
- Updated Monitoring and Manual operations sections with new recipes.

## Bugs fixed during implementation

### Backtick comments in ExecStart (broke service startup)

Used `` `# comment` `` syntax inside the Nix heredoc string for ExecStart,
expecting shell-style inline comments. But systemd's ExecStart doesn't
go through a shell — the backtick strings were passed as literal arguments
to rclone, including `-X` from a curl example, causing
`Error: unknown shorthand flag: 'X' in -X`.

Fix: moved all comments to Nix-level (`#`) above the ExecStart attribute.

### RC API endpoints require POST, not GET

The `b2-cache` recipe used `curl -s` (GET) which returned 404. All rclone
RC endpoints require POST. Fixed by adding `-X POST` to the curl call.

### `vfs/read` endpoint doesn't exist

The `b2-warm` recipe called `vfs/read` which doesn't exist in rclone's RC
API. The available VFS endpoints are `vfs/stats`, `vfs/refresh`,
`vfs/forget`, and `vfs/list` — none of them prefetch file content.

Fix: replaced with `cat /media/b2/<path> > /dev/null` which reads through
the FUSE mount, pulling the file into VFS cache. Simpler and correct.

### RC API bound to localhost only

Originally bound to `127.0.0.1:5572` which meant the web GUI was
inaccessible from the browser. Changed to `0.0.0.0:5572`. No auth needed
since the firewall restricts access to LAN/Tailscale.

## Verification steps

1. **Service running with new flags:**
   `ssh builder 'systemctl status rclone-b2-mount --no-pager | head -15'`
   Confirm: command line shows `--buffer-size 512M --vfs-read-ahead 1G
   --vfs-read-chunk-streams 4 --rc-addr 0.0.0.0:5572`

2. **RC API responds:**
   `just b2-cache`
   Confirm: JSON with `ReadAhead: 1073741824`, `ChunkStreams: 4`

3. **Web GUI accessible:**
   Open `http://nixos-builder:5572` — should load with no password.

4. **Nginx redirect works:**
   Open `http://nixos-builder/rclone/` — should redirect to `:5572`.

5. **b2-ls works:**
   `just b2-ls` and `just b2-ls downloads/`

6. **b2-warm works:**
   `just b2-warm 'downloads/<some-small-file>'`
   Confirm: prints `Cached: downloads/<file>`

7. **Streaming improvement:**
   Play a cold file on Jellyfin. Watch transfers:
   `ssh builder 'journalctl -u rclone-b2-mount -f --no-pager'`

## Files changed

- `machines/builder/src/service/rclone-b2.nix` — VFS tuning + RC API + logging
- `machines/builder/src/service/web.nix` — rclone dashboard link + redirect
- `justfile` — b2-ls, b2-cache, b2-warm recipes
- `shared/base.nix` — added jq
- `docs/media-pipeline.md` — VFS tuning docs, RC API docs, updated recipes
