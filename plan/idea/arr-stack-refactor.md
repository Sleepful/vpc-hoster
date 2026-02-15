# *arr Stack Refactor: Dedicated Media Machine

## Context

Jellyfin and Syncthing are initially deployed on builder for simplicity.
Builder's primary role is NixOS build server. Media services are lightweight
today (small library, direct-play, Syncthing for file ingestion), but may
grow.

This document captures the vision for when media outgrows builder and
warrants a dedicated machine.

## Trigger Conditions

Move to a dedicated media machine when any of these become true:

- Transcoding is needed (GPU passthrough required)
- The *arr stack is desired (Sonarr, Radarr, Prowlarr, etc.)
- Media library grows large enough that disk I/O during library scans
  competes with Nix builds
- Builder restarts during deploys become disruptive to streaming

## Target Architecture

A new Proxmox VM (e.g., `media`) running:

```
machines/media/
  configuration.nix
  hardware-configuration.nix
  src/
    config.nix
    service/
      jellyfin.nix        # moved from builder
      syncthing.nix        # moved from builder
      arr.nix              # Sonarr + Radarr + Prowlarr
      transmission.nix     # or another download client
      tailnet.nix          # VPN access
```

### *arr Stack Components

- **Prowlarr** — Indexer manager. Single source of truth for torrent/usenet
  indexers. Feeds search results to Sonarr and Radarr.
- **Sonarr** — TV show automation. Monitors for new episodes, triggers
  downloads, renames and organizes files into Jellyfin's library structure.
- **Radarr** — Movie automation. Same workflow as Sonarr but for films.
- **Transmission** (or qBittorrent) — Download client. Sonarr/Radarr send
  download requests here. Completed downloads are moved to the media library.
- **Jellyfin** — Streams the organized library to clients on the LAN.

### Data Flow

```
Prowlarr (indexers)
    |
    v
Sonarr / Radarr (search + monitor)
    |
    v
Transmission (download)
    |
    v
/media/tv, /media/movies (organized library)
    |
    v
Jellyfin (stream to clients)
```

Syncthing remains useful alongside the *arr stack for manually acquired
media that doesn't go through the automated pipeline.

### Resource Budget

| Component       | RAM     | Notes                              |
|-----------------|---------|------------------------------------|
| Jellyfin        | 300 MB  | More with transcoding              |
| Syncthing       | 100 MB  | Scales with file count             |
| Sonarr          | 300 MB  | .NET process                       |
| Radarr          | 300 MB  | .NET process                       |
| Prowlarr        | 200 MB  | .NET process                       |
| Transmission    | 50 MB   | Lightweight                        |
| **Total**       | ~1.3 GB | 2-4 GB VM recommended              |

### Migration Path

1. Create `machines/media/` following the existing machine pattern.
2. Move `jellyfin.nix` and `syncthing.nix` from `machines/builder/src/service/`
   to `machines/media/src/service/`. The module contents are portable — only
   the import paths in `config.nix` change.
3. Add *arr service modules.
4. Register `media` in `flake.nix`.
5. Add deploy recipe to justfile.
6. Provision Proxmox VM, bootstrap, deploy.

### NixOS Packaging Notes

All *arr apps are packaged in nixpkgs:
- `services.sonarr`
- `services.radarr`
- `services.prowlarr`
- `services.jellyfin`
- `services.transmission`

Each has a NixOS module with `enable`, `user`, `group`, `dataDir` options.
No custom packaging needed.

## Decision

Not yet. Revisit when trigger conditions are met. Current plan is to start
on builder and migrate when needed.
