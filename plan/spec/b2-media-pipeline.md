# B2 Media Pipeline: rclone + Copyparty + qBittorrent

## Summary

Large media library stored in Backblaze B2. Builder (home LAN) mounts B2
via rclone with a VFS cache for instant local playback. Copyparty provides
a web UI and WebDAV for browsing, pre-fetching, and uploading media from
macOS. House (Hetzner VPS) runs qBittorrent for downloading torrents and
auto-uploads completed downloads to B2.

## Architecture

```
macOS
  |
  |  Copyparty WebDAV mount --> upload media to builder
  |  Jellyfin client ---------> watch media
  |  qBittorrent web UI ------> add torrents on house
  |
  v
+------------------------+   +---------------------------------+
|  builder (home LAN)    |   |  house (Hetzner VPS)            |
|  200GB disk            |   |  50GB disk                      |
|                        |   |                                 |
|  rclone mount (B2)     |   |  qBittorrent                    |
|   +- /media/b2         |   |   +- downloads to staging       |
|   +- VFS cache ~150G   |   |  on-complete script:            |
|   +- max-age 168h      |   |   +- rclone copy -> B2          |
|                        |   |   +- delete local file           |
|  Copyparty             |   |                                 |
|   +- serves /media     |   |  nginx reverse proxy            |
|   +- WebDAV for macOS  |   |   +- torrent.<domain> -> :8080  |
|   +- browse/prefetch   |   |                                 |
|                        |   |  (email, monitoring, etc. as-is) |
|  Jellyfin              |   |                                 |
|   +- /media (syncthing)|   |                                 |
|   +- /media/b2 (B2)    |   |                                 |
|                        |   |                                 |
|  Syncthing (unchanged) |   |  Syncthing (unchanged)          |
+------------------------+   +---------------------------------+
           |                            |
           v                            v
+-------------------------------------------------------+
|  Backblaze B2 (full media library, unlimited)          |
+-------------------------------------------------------+
```

## Data Flows

Upload from macOS:
  macOS Finder (WebDAV) -> Copyparty -> rclone mount -> B2

Download via torrent:
  qBittorrent (house) -> staging dir -> rclone copy -> B2 -> delete local

Pre-fetch for viewing:
  Copyparty/Filebrowser (web UI on builder) -> read from rclone mount ->
  VFS cache fills -> file is local on builder disk

Watch:
  Jellyfin reads /media/b2 -> cached files play instantly,
  uncached files stream from B2 with initial buffering

## Existing Services (Unchanged)

- Syncthing on builder: continues syncing /media from paired devices
- Syncthing on house: unchanged
- Jellyfin on builder: unchanged, gains /media/b2 as additional library
- All house services (mail, monitoring, nginx, etc.): unchanged

## Files Created (4 new)

| File                                           | Machine | Purpose                                      |
|------------------------------------------------|---------|----------------------------------------------|
| machines/builder/src/service/secrets.nix       | builder | SOPS config, B2 credentials, rclone env file |
| machines/builder/src/service/rclone-b2.nix     | builder | rclone mount systemd service                 |
| machines/builder/src/service/copyparty.nix     | builder | Copyparty web file server + WebDAV           |
| machines/house/src/service/qbittorrent.nix     | house   | qBittorrent + on-complete B2 upload script   |

## Files Modified (8 existing)

| File                                           | Change                                          |
|------------------------------------------------|-------------------------------------------------|
| flake.nix                                      | Add sops-nix module to builder                  |
| .sops.yaml                                     | Add builder's age public key                    |
| shared/options/identifiers.nix                 | Add torrent subdomain option                    |
| machines/builder/src/config.nix                | Import secrets, rclone-b2, copyparty            |
| machines/house/src/service/secrets.nix         | Add B2 secret declarations + rclone env template|
| machines/house/src/service/web.nix             | Add nginx vhost for torrent subdomain           |
| machines/house/src/service/firewall.nix        | Open torrenting port 6881 TCP+UDP               |
| machines/house/src/config.nix                  | Import qbittorrent.nix                          |

## Implementation Phases

### Phase 0: Infrastructure Prep

1. flake.nix: add sops-nix.nixosModules.sops to builder's module list.

2. .sops.yaml: add builder's age public key (derived from builder's SSH
   host key via ssh-to-age).

3. shared/options/identifiers.nix: add torrent subdomain option with
   default "torrent".

### Phase 1: Builder -- rclone mount + Copyparty

4. machines/builder/src/service/secrets.nix (new):
   - sops.defaultSopsFile -> secrets/builder/core.yaml
   - sops.age.sshKeyPaths -> /etc/ssh/ssh_host_ed25519_key
   - Declare secrets: b2_account_id, b2_application_key
   - SOPS template rclone_b2_env:
       RCLONE_CONFIG_B2_TYPE=b2
       RCLONE_CONFIG_B2_ACCOUNT=<b2_account_id>
       RCLONE_CONFIG_B2_KEY=<b2_application_key>

5. machines/builder/src/service/rclone-b2.nix (new):
   - Install pkgs.rclone and pkgs.fuse3
   - programs.fuse.userAllowOther = true
   - Systemd service rclone-b2-mount:
      - ExecStart: rclone mount b2:entertainment-netmount /media/b2
         --vfs-cache-mode full
         --vfs-cache-max-size 150G
         --vfs-cache-max-age 168h
         --allow-other
         --dir-cache-time 5m
     - EnvironmentFile = SOPS-rendered rclone_b2_env
     - ExecStartPre = mkdir -p /media/b2
     - ExecStop = fusermount -u /media/b2
     - After network-online.target
     - Type=notify, --rc for sd-notify
     - Restart on failure

6. machines/builder/src/service/copyparty.nix (new):
   - Install pkgs.copyparty
   - Systemd service copyparty:
     - Serves /media (full tree: syncthing content + B2 mount)
     - Web UI on port 3923 (Copyparty default)
     - WebDAV enabled
     - Runs as media user
     - After rclone-b2-mount.service

7. machines/builder/src/config.nix:
   - Add imports: secrets.nix, rclone-b2.nix, copyparty.nix

### Phase 2: House -- qBittorrent + auto-upload to B2

8. machines/house/src/service/secrets.nix:
   - Add sops.secrets.b2_account_id and b2_application_key
   - Add SOPS template rclone_b2_env (same format as builder)

9. machines/house/src/service/qbittorrent.nix (new):
   - services.qbittorrent.enable = true
   - services.qbittorrent.webuiPort = 8080
   - services.qbittorrent.torrentingPort = 6881
   - Install pkgs.rclone for on-complete script
   - On-complete helper script (Nix store):
      1. rclone copy "$file" b2:entertainment-netmount/downloads/ using env file
     2. rm "$file" after successful upload
   - qBittorrent serverConfig sets external program on completion

10. machines/house/src/service/web.nix:
    - Add torrent subdomain to ACME extraDomainNames
    - Add nginx virtualHost for torrent.<domain>:
      - onlySSL = true, uses existing ACME cert
      - proxy_pass to 127.0.0.1:8080

11. machines/house/src/service/firewall.nix:
    - Add TCP 6881 (torrenting peers)
    - Add UDP 6881 (DHT/peer discovery)

12. machines/house/src/config.nix:
    - Add import: ./service/qbittorrent.nix

### Phase 3: Verification

13. just syntax -- local Nix syntax check
14. just check -- flake eval check for builder
15. just check house -- flake eval check for house

## Manual Steps Required

| Step                       | When                  | How                                               |
|----------------------------|-----------------------|---------------------------------------------------|
| Builder age public key     | Before implementation | ssh-keyscan <builder-ip> | ssh-to-age            |
| Create builder secrets     | After files written   | just secret secrets/builder/core.yaml             |
|                            |                       | Add: b2_account_id, b2_application_key            |
| Add B2 creds to house      | After files written   | just secret secrets/house/core.yaml               |
|                            |                       | Add: b2_account_id, b2_application_key            |
| B2 bucket name             | Resolved              | entertainment-netmount                            |
| qBittorrent password       | After first deploy    | Log into web UI, change default admin password    |
| Jellyfin library           | After first deploy    | Add /media/b2 as new media library in Jellyfin UI |
| Private identifiers        | Before deploy         | Add torrent subdomain to private/identifiers      |

## Resolved Decisions

- B2 bucket name: entertainment-netmount
- Copyparty auth: password-protected (may share with users outside Tailnet)
- B2 upload path for torrents: downloads/ staging folder in bucket.
  Completed torrents go to entertainment-netmount/downloads/. Organize
  into movies/shows/etc via Copyparty file manager afterward.

## Cost Considerations

- B2 storage: $0.006/GB/month. 1TB = ~$6/month.
- B2 downloads: $0.01/GB after 1GB free/day. A 10GB movie = ~$0.10.
- B2 API calls: negligible for this use case.
- rclone VFS cache avoids repeat download costs for recently watched files.

## Future Additions

- Sonarr/Radarr/Prowlarr: automate torrent search and download. Would
  integrate with qBittorrent on house. Deferred per arr-stack-refactor.md.
- Dedicated media VM: if media services outgrow builder, migrate per
  the migration path in plan/idea/arr-stack-refactor.md.
