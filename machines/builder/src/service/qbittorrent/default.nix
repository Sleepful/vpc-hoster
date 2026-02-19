# Part of the media pipeline — see docs/media-pipeline.md
/*
  qBittorrent with automatic B2 upload via Sonarr/Radarr import and seeding.

  All media pipeline services (qBittorrent, Sonarr, Radarr, Jellyfin, Copyparty)
  run as the shared `media` user. This allows Sonarr/Radarr to hard link (not
  copy) completed downloads into their root folders, avoiding duplicate disk usage.

  Workflow:
    1. qBittorrent downloads to downloading/ (TempPath).
    2. On completion, qBittorrent moves the file to completed/ (DefaultSavePath)
       and begins seeding from there.
    3. Sonarr/Radarr detect the completed download and hard link + rename the
       files into /media/arr/tv/ or /media/arr/movies/ (their root folders).
       Since all services run as the same user and files are on the same
       filesystem, hard links work — zero extra disk usage.
    4. qbt-upload-b2.timer fires every 2 minutes. The upload service scans
       /media/arr/tv/ and /media/arr/movies/ for new files (nice names from
       *arr) and uploads them to B2. Falls back to scanning completed/ for
       uncategorized downloads not managed by *arr.
     5. qBittorrent seeds indefinitely (no built-in ratio/time limits).
     6. qbt-cleanup.timer runs every 10 minutes. For items that have been uploaded
        and seeded for >= minSeedingDays (10 days) with avg upload rate < 2 KB/s:
        - Removes the torrent from qBittorrent via API
        - Deletes files from completed/ (the seeding copy)
        - Finds and deletes hard links from /media/arr/tv/ or /media/arr/movies/
        - Prunes empty directories left behind

  Archive extraction (zip, rar):
    If a completed item is an archive or a directory containing archives,
    the upload service extracts them to a temporary extracted/ directory,
    uploads the extracted contents to B2, then deletes extracted/ immediately.
    The original archive stays in completed/ for seeding. Only top-level
    archives are extracted (nested archives are ignored).

  Categories:
    Downloads are organized by category (set by Sonarr/Radarr when sending
    a torrent). Each category maps to a subdirectory under completed/:
      tv-sonarr → completed/tv/
      radarr    → completed/movies/
    Uncategorized downloads land directly in completed/ → downloads/ on B2.

  Import directories (Sonarr/Radarr root folders):
    /media/arr/tv/      — TV series (hard links from completed/tv/, nice names)
    /media/arr/movies/  — Movies (hard links from completed/movies/, nice names)
    These are uploaded to B2 as tv/ and movies/ respectively.

  Directories:
    /var/lib/qBittorrent/downloading  — in-progress downloads
    /var/lib/qBittorrent/completed    — finished downloads (seeding)
    /var/lib/qBittorrent/completed/tv — TV series (Sonarr category)
    /var/lib/qBittorrent/completed/movies — movies (Radarr category)
    /var/lib/qBittorrent/extracted    — temporary extraction dir (ephemeral)
    /media/arr/tv                     — Sonarr root folder (hard links)
    /media/arr/movies                 — Radarr root folder (hard links)

  Manual operations:
    - To free disk early: remove the torrent from qBittorrent's web UI, then
      either wait up to 10 minutes or run `systemctl start qbt-cleanup`.
    - To monitor: `just qbt-logs` (follows qbittorrent, upload, and cleanup).
    - To retry a failed upload: `systemctl start qbt-upload-b2`.

  Scripts:
    The three companion services (categories, upload, cleanup) are implemented
    as standalone Python scripts alongside this module. They read all
    configuration from environment variables set by systemd, making them
    independently testable. Run `just test` to execute the test suite.

  Systemd units:
    qbt-upload-b2.timer      — polls every 2 min for new files to upload
    qbt-upload-b2.service    — uploads to B2 from /media/arr/ and completed/
    qbt-categories.service   — creates qBittorrent categories via API on boot
    qbt-cleanup.timer        — fires every 10 min
    qbt-cleanup.service      — removes torrents after seedingDays, cleans up
*/
{ config, pkgs, ... }:
let
  ids = config.homelab.identifiers;
  completedDir = "/var/lib/qBittorrent/completed";
  extractedDir = "/var/lib/qBittorrent/extracted";
  importBase = "/media/arr";
  b2Remote = "b2:entertainment-netmount";
  webuiPort = 8080; # WebUI for torrent management (LAN/Tailscale)
  torrentingPort = 6881; # BitTorrent peer connections (incoming)
  minSeedingDays = 10; # Minimum days to seed before considering removal
  minAvgRate = 2048; # Minimum avg upload rate (bytes/sec) to keep seeding (2 KB/s)

  # Download categories — each maps to a subdirectory under completed/ and an
  # import directory under importBase/ where Sonarr/Radarr hard link with nice names.
  # Uncategorized downloads land directly in completed/ → downloads/ on B2.
  categories = {
    tv-sonarr = "tv";
    radarr = "movies";
  };

  # Serialized for Python scripts: "tv-sonarr:tv,radarr:movies"
  categoriesEnv = builtins.concatStringsSep "," (
    builtins.attrValues (builtins.mapAttrs (name: subdir: "${name}:${subdir}") categories)
  );

  python = "${pkgs.python3}/bin/python3";
in
{
  services.qbittorrent = {
    enable = true;
    user = "media";
    group = "media";
    inherit webuiPort;
    inherit torrentingPort;

    serverConfig = {
      LegalNotice.Accepted = true;

      Preferences = {
        "WebUI\\Password_PBKDF2" = ids.qbittorrent.passwordHash;
        # Bypass auth for localhost (systemd scripts) and Tailscale CGNAT subnet.
        # Tailscale is the auth layer — no need for a second login.
        "WebUI\\LocalHostAuth" = false;
        "WebUI\\AuthSubnetWhitelistEnabled" = true;
        "WebUI\\AuthSubnetWhitelist" = "100.64.0.0/10";
      };

      BitTorrent.Session = {
        DefaultSavePath = completedDir;
        TempPathEnabled = true;
        TempPath = "/var/lib/qBittorrent/downloading";
        # No MaxRatioAction or GlobalMaxSeedingMinutes — qBittorrent seeds
        # indefinitely. The qbt-cleanup timer handles torrent removal and
        # file deletion after seedingDays have passed.
      };
    };
  };

  # Ensure download and import directories exist with correct ownership
  systemd.tmpfiles.rules = [
    "d /var/lib/qBittorrent/downloading 0755 media media -"
    "d ${completedDir} 0755 media media -"
    "d ${extractedDir} 0755 media media -"
    "d ${importBase} 0755 media media -"
  ] ++ map (sub: "d ${completedDir}/${sub} 0755 media media -")
    (builtins.attrValues categories)
  ++ map (sub: "d ${importBase}/${sub} 0755 media media -")
    (builtins.attrValues categories);

  # Create qBittorrent categories with save paths so downloads are organized
  # into subdirectories (e.g. completed/tv/, completed/movies/). Runs once
  # after qBittorrent starts. Categories persist in qBittorrent's database
  # so this is idempotent.
  systemd.services.qbt-categories = {
    description = "Configure qBittorrent download categories";
    after = [ "qbittorrent.service" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "oneshot";
      User = "media";
      Group = "media";
      RemainAfterExit = true;
      ExecStart = "${python} ${./categories.py}";
      Environment = [
        "QBT_API_URL=http://localhost:${toString webuiPort}/api/v2"
        "COMPLETED_DIR=${completedDir}"
        "CATEGORIES=${categoriesEnv}"
      ];
    };
  };

  # Upload completed downloads to B2.
  # Primary: scans /media/arr/tv/ and /media/arr/movies/ (nice names from Sonarr/Radarr)
  # Fallback: scans completed/ for uncategorized downloads (torrent names)
  # Triggered by qbt-upload-b2.timer every 2 minutes.
  systemd.services.qbt-upload-b2 = {
    description = "Upload completed qBittorrent downloads to B2";

    serviceConfig = {
      Type = "oneshot";
      User = "media";
      Group = "media";
      ExecStart = "${python} ${./upload.py}";
      EnvironmentFile = config.sops.templates.rclone_b2_env.path;
      Environment = [
        "COMPLETED_DIR=${completedDir}"
        "EXTRACTED_DIR=${extractedDir}"
        "IMPORT_BASE=${importBase}"
        "B2_REMOTE=${b2Remote}"
        "CATEGORIES=${categoriesEnv}"
      ];
    };

    path = with pkgs; [ rclone unar ];
  };

  # Poll for new completed downloads and upload them.
  # We use a timer instead of a path unit because DirectoryNotEmpty re-triggers
  # endlessly when files are left in place for seeding (the directory is never
  # emptied). A 2-minute poll is a good balance between latency and overhead —
  # the upload itself is the bottleneck, not detection.
  systemd.timers.qbt-upload-b2 = {
    description = "Poll for completed qBittorrent downloads to upload";
    wantedBy = [ "timers.target" ];

    timerConfig = {
      OnBootSec = "1min";
      OnUnitActiveSec = "2min";
    };
  };

  # Manage seeding lifetime and clean up completed downloads.
  # Runs every 10 minutes. For each uploaded file in completed/:
  #   - Seed for at least minSeedingDays (10 days).
  #   - After that, remove if avg upload rate < minAvgRate (2 KB/s).
  #     avg_rate = total_uploaded / seeding_duration.
  #   - Also removes hard links from /media/arr/tv/ and /media/arr/movies/ by inode,
  #     and prunes empty directories left behind.
  #   - If the file is orphaned (no longer tracked by qBittorrent, e.g.
  #     manually removed from the UI) and was uploaded, delete immediately.
  #   - Never delete files that haven't been uploaded to B2 yet.
  systemd.services.qbt-cleanup = {
    description = "Clean up completed qBittorrent downloads after seeding";

    serviceConfig = {
      Type = "oneshot";
      User = "media";
      Group = "media";
      ExecStart = "${python} ${./cleanup.py}";
      Environment = [
        "QBT_API_URL=http://localhost:${toString webuiPort}/api/v2"
        "COMPLETED_DIR=${completedDir}"
        "IMPORT_BASE=${importBase}"
        "MIN_SEEDING_DAYS=${toString minSeedingDays}"
        "MIN_AVG_RATE=${toString minAvgRate}"
        "CATEGORIES=${categoriesEnv}"
      ];
    };
  };

  systemd.timers.qbt-cleanup = {
    description = "Periodically clean up orphaned qBittorrent downloads";
    wantedBy = [ "timers.target" ];

    timerConfig = {
      OnBootSec = "5min";
      OnUnitActiveSec = "10min";
    };
  };

  networking.firewall.allowedTCPPorts = [
    webuiPort      # qBittorrent WebUI (LAN/Tailscale)
    torrentingPort # BitTorrent incoming peer connections
  ];
  networking.firewall.allowedUDPPorts = [
    torrentingPort # BitTorrent incoming peer connections (UDP)
  ];

  # rclone is needed by the upload service, unar for archive extraction
  environment.systemPackages = [ pkgs.rclone pkgs.unar ];

  # Allow the media user to read the SOPS-rendered rclone env file
  sops.templates.rclone_b2_env.group = "media";
}
