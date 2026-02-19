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
       and seeded for >= seedingDays:
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
  webuiPort = 8080; # WebUI for torrent management (LAN/Tailscale)
  torrentingPort = 6881; # BitTorrent peer connections (incoming)
  seedingDays = 7; # How long to seed before cleanup removes the torrent and files

  # Download categories — each maps to a subdirectory under completed/ and an
  # import directory under /media/ where Sonarr/Radarr hard link with nice names.
  # Uncategorized downloads land directly in completed/ → downloads/ on B2.
  categories = {
    tv-sonarr = "tv";
    radarr = "movies";
  };

  # Import directories — where Sonarr/Radarr hard link completed downloads.
  # The upload script scans these for files to upload to B2 with nice names.
  importDirs = builtins.mapAttrs (name: subdir: "/media/arr/${subdir}") categories;

  # Space-separated list of category subdirectory paths (used by scripts to skip them)
  categoryDirsList = builtins.concatStringsSep " " (map (sub: "${completedDir}/${sub}") (builtins.attrValues categories));

  # Shell commands to scan each import directory for uploads
  # Import dirs get uploaded to top-level B2 paths (tv/, movies/)
  uploadImportCommands = builtins.concatStringsSep "\n" (builtins.attrValues (builtins.mapAttrs (name: subdir:
    "scan_import_dir \"/media/arr/${subdir}\" \"${subdir}/\""
  ) categories));

  # Shell commands to scan each category subdirectory for cleanup
  cleanupScanCommands = builtins.concatStringsSep "\n" (map (sub:
    "scan_dir \"${completedDir}/${sub}\""
  ) (builtins.attrValues categories));

  # Space-separated list of import directory paths for cleanup to search
  importDirsList = builtins.concatStringsSep " " (map (sub: "/media/arr/${sub}") (builtins.attrValues categories));
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
    "d /media/arr 0755 media media -"
    "d /media/arr/tv 0755 media media -"
    "d /media/arr/movies 0755 media media -"
  ] ++ map (sub: "d ${completedDir}/${sub} 0755 media media -")
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
    };

    script = let
      categoryCommands = builtins.concatStringsSep "\n" (builtins.attrValues (builtins.mapAttrs (name: subdir: ''
        # Create or update category "${name}" -> ${subdir}/
        ${pkgs.curl}/bin/curl -sf -X POST "$API/torrents/createCategory" \
          --data-urlencode "category=${name}" \
          --data-urlencode "savePath=${completedDir}/${subdir}" || \
        ${pkgs.curl}/bin/curl -sf -X POST "$API/torrents/editCategory" \
          --data-urlencode "category=${name}" \
          --data-urlencode "savePath=${completedDir}/${subdir}" || true
        echo "Category: ${name} -> ${subdir}/"
      '') categories));
    in ''
      API="http://localhost:${toString webuiPort}/api/v2"

      # Wait for qBittorrent API to be ready
      for i in $(${pkgs.coreutils}/bin/seq 1 30); do
        ${pkgs.curl}/bin/curl -sf "$API/app/version" >/dev/null && break
        ${pkgs.coreutils}/bin/sleep 1
      done

      ${categoryCommands}
    '';
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
      EnvironmentFile = config.sops.templates.rclone_b2_env.path;
    };

    path = [ pkgs.unar ];

    script = ''
      upload() {
        local SRC="$1" DEST="$2"
        if ! ${pkgs.rclone}/bin/rclone copy "$SRC" "$DEST" \
            --transfers 4 --checksum --stats 30s --stats-log-level NOTICE; then
          echo "Upload failed: $SRC"
          return 1
        fi
        return 0
      }

      # Extract a single archive into a destination directory.
      # unar handles both zip and rar (free/open-source).
      extract() {
        local ARCHIVE="$1" EXTRACT_TO="$2"
        echo "Extracting: $(${pkgs.coreutils}/bin/basename "$ARCHIVE")"
        unar -f -o "$EXTRACT_TO" "$ARCHIVE"
      }

      # Process a single item (file or directory) for upload.
      # $1 = item path, $2 = B2 base path (e.g. tv/ or movies/ or downloads/)
      process_item() {
        local ITEM="$1" B2_BASE="$2"
        local NAME WORK_DIR HAS_ARCHIVES DEST

        NAME=$(${pkgs.coreutils}/bin/basename "$ITEM")
        WORK_DIR="${extractedDir}/$NAME"
        HAS_ARCHIVES=0

        ${pkgs.coreutils}/bin/rm -rf "$WORK_DIR"
        ${pkgs.coreutils}/bin/mkdir -p "$WORK_DIR"

        # Single file archive
        if [ -f "$ITEM" ]; then
          case "$ITEM" in
            *.zip|*.rar)
              extract "$ITEM" "$WORK_DIR"
              HAS_ARCHIVES=1
              ;;
          esac
        fi

        # Directory containing archives
        if [ -d "$ITEM" ]; then
          for ARCHIVE in "$ITEM"/*.zip "$ITEM"/*.rar; do
            [ -f "$ARCHIVE" ] || continue
            extract "$ARCHIVE" "$WORK_DIR"
            HAS_ARCHIVES=1
          done
        fi

        # Upload extracted contents then clean up
        if [ "$HAS_ARCHIVES" = 1 ]; then
          echo "Uploading extracted: $NAME"
          upload "$WORK_DIR" "b2:entertainment-netmount/''${B2_BASE}$NAME"
        fi
        ${pkgs.coreutils}/bin/rm -rf "$WORK_DIR"

        # Upload the original item (archive or not) to B2
        if [ -d "$ITEM" ]; then
          DEST="b2:entertainment-netmount/''${B2_BASE}$NAME"
        else
          DEST="b2:entertainment-netmount/''${B2_BASE}"
        fi

        echo "Uploading: $NAME -> $DEST"
        if ! upload "$ITEM" "$DEST"; then
          return 1
        fi

        # Mark as uploaded so subsequent runs skip this item.
        # If we can't write the marker (e.g. directory permissions), warn loudly
        # and exit non-zero so we don't silently re-upload on every timer tick.
        if ! ${pkgs.coreutils}/bin/touch "$ITEM.uploaded" 2>/dev/null; then
          echo "ERROR: Cannot create upload marker: $ITEM.uploaded (permission denied)"
          echo "Fix ownership: chown -R media:media \"$(${pkgs.coreutils}/bin/dirname "$ITEM")\""
          return 1
        fi
        echo "Uploaded: $NAME"
      }

      # Scan an import directory (/media/tv/, /media/movies/) for items to upload.
      # These contain nicely named files from Sonarr/Radarr.
      # Recurse into subdirectories (e.g. /media/tv/Show Name/Season 1/)
      # $1 = directory to scan, $2 = B2 base path (e.g. tv/ or movies/)
      scan_import_dir() {
        local DIR="$1" B2_BASE="$2"
        for ITEM in "$DIR"/*; do
          [ -e "$ITEM" ] || continue
          case "$ITEM" in *.uploaded) continue ;; esac
          [ -e "$ITEM.uploaded" ] && continue

          if [ -d "$ITEM" ]; then
            # Recurse into subdirectories (show/season structure)
            local SUBDIR_NAME
            SUBDIR_NAME=$(${pkgs.coreutils}/bin/basename "$ITEM")
            scan_import_dir "$ITEM" "''${B2_BASE}$SUBDIR_NAME/"
          else
            # Upload individual files
            process_item "$ITEM" "$B2_BASE" || continue
          fi
        done
      }

      # Scan completed/ for uncategorized downloads (not managed by *arr).
      # $1 = directory to scan, $2 = B2 base path
      scan_dir() {
        local DIR="$1" B2_BASE="$2"
        for ITEM in "$DIR"/*; do
          [ -e "$ITEM" ] || continue
          # Skip marker files, already-uploaded items, and category subdirectories
          case "$ITEM" in *.uploaded) continue ;; esac
          [ -e "$ITEM.uploaded" ] && continue
          [ -d "$ITEM" ] && echo "${categoryDirsList}" \
            | ${pkgs.gnugrep}/bin/grep -qwF "$ITEM" && continue

          process_item "$ITEM" "$B2_BASE" || continue
        done
      }

      # Primary: scan import directories (nice names from *arr)
      ${uploadImportCommands}

      # Fallback: scan uncategorized downloads (top-level completed/)
      scan_dir "${completedDir}" "downloads/"
    '';
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
  #   - If the torrent has been seeding for >= seedingDays and was uploaded to
  #     B2, remove the torrent from qBittorrent and delete local files.
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
    };

    script = ''
      set -o pipefail

      API="http://localhost:${toString webuiPort}/api/v2"
      MAX_AGE=$((${toString seedingDays} * 86400))
      NOW=$(${pkgs.coreutils}/bin/date +%s)

      # Fetch all torrents with their content paths, hashes, and completion times
      if ! TORRENTS=$(${pkgs.curl}/bin/curl -sf "$API/torrents/info" \
        | ${pkgs.jq}/bin/jq -c '.[] | {hash, content_path, completion_on}'); then
        echo "Failed to query qBittorrent API, skipping cleanup"
        exit 0
      fi

      CLEANED=0
      SKIPPED=0
      SEEDING=0

      # Known category subdirectory paths (to skip when scanning top-level)
      CATEGORY_DIRS="${categoryDirsList}"

      # Import directories to search for hard links
      IMPORT_DIRS="${importDirsList}"

      # Remove hard links in import directories (/media/tv/, /media/movies/)
      # that point to the same inode as the file being cleaned up.
      # Then prune empty parent directories up to the import root.
      remove_hardlinks() {
        local ITEM="$1"
        if [ -f "$ITEM" ]; then
          # Single file — find hard links by inode
          local INODE
          INODE=$(${pkgs.coreutils}/bin/stat -c '%i' "$ITEM" 2>/dev/null) || return
          for IMPORT_DIR in $IMPORT_DIRS; do
            ${pkgs.findutils}/bin/find "$IMPORT_DIR" -inum "$INODE" -delete 2>/dev/null || true
          done
        elif [ -d "$ITEM" ]; then
          # Directory — find hard links for each file inside
          ${pkgs.findutils}/bin/find "$ITEM" -type f -print0 | while IFS= read -r -d "" FILE; do
            local INODE
            INODE=$(${pkgs.coreutils}/bin/stat -c '%i' "$FILE" 2>/dev/null) || continue
            for IMPORT_DIR in $IMPORT_DIRS; do
              ${pkgs.findutils}/bin/find "$IMPORT_DIR" -inum "$INODE" -delete 2>/dev/null || true
            done
          done
        fi
        # Prune empty directories in import dirs (bottom-up)
        for IMPORT_DIR in $IMPORT_DIRS; do
          ${pkgs.findutils}/bin/find "$IMPORT_DIR" -mindepth 1 -type d -empty -delete 2>/dev/null || true
        done
      }

      # Process items in a directory. Checks upload status, seeding age, and
      # removes torrents/files when ready.
      scan_dir() {
        local DIR="$1"
        for ITEM in "$DIR"/*; do
          [ -e "$ITEM" ] || continue
          case "$ITEM" in *.uploaded) continue ;; esac

          # Skip category subdirectories when scanning top-level
          if [ -d "$ITEM" ] && echo "$CATEGORY_DIRS" | ${pkgs.gnugrep}/bin/grep -qwF "$ITEM"; then
            continue
          fi

          NAME=$(${pkgs.coreutils}/bin/basename "$ITEM")

          # Never delete files that haven't been uploaded to B2 yet
          if [ ! -e "$ITEM.uploaded" ]; then
            echo "Skipping (not yet uploaded): $NAME"
            SKIPPED=$((SKIPPED + 1))
            continue
          fi

          # Look up this item in qBittorrent's active torrents
          MATCH=$(echo "$TORRENTS" | ${pkgs.jq}/bin/jq -r \
            --arg path "$ITEM" 'select(.content_path == $path)' 2>/dev/null || true)

          if [ -n "$MATCH" ]; then
            # Torrent is still tracked — check if it's old enough to remove
            COMPLETED_ON=$(echo "$MATCH" | ${pkgs.jq}/bin/jq -r '.completion_on')
            HASH=$(echo "$MATCH" | ${pkgs.jq}/bin/jq -r '.hash')
            AGE=$((NOW - COMPLETED_ON))

            if [ "$AGE" -lt "$MAX_AGE" ]; then
              DAYS_LEFT=$(( (MAX_AGE - AGE) / 86400 ))
              echo "Seeding ($DAYS_LEFT days left): $NAME"
              SEEDING=$((SEEDING + 1))
              continue
            fi

            # Seeding period is over — remove torrent from qBittorrent
            echo "Removing torrent after ${toString seedingDays} days: $NAME"
            ${pkgs.curl}/bin/curl -sf -X POST "$API/torrents/delete" \
              --data-urlencode "hashes=$HASH" \
              --data-urlencode "deleteFiles=false" || true
          else
            echo "Cleaning orphan: $NAME"
          fi

          # Remove hard links in import directories before deleting source
          remove_hardlinks "$ITEM"

          ${pkgs.coreutils}/bin/rm -rf "$ITEM" "$ITEM.uploaded"
          CLEANED=$((CLEANED + 1))
        done
      }

      # Scan uncategorized downloads and each category subdirectory
      scan_dir "${completedDir}"
      ${cleanupScanCommands}

      # Also clean up .uploaded markers in import directories that no longer
      # have a corresponding file (leftover from previous uploads)
      for IMPORT_DIR in $IMPORT_DIRS; do
        ${pkgs.findutils}/bin/find "$IMPORT_DIR" -name '*.uploaded' -print0 2>/dev/null \
          | while IFS= read -r -d "" MARKER; do
            SOURCE="''${MARKER%.uploaded}"
            if [ ! -e "$SOURCE" ]; then
              ${pkgs.coreutils}/bin/rm -f "$MARKER"
            fi
          done
      done

      echo "Cleanup done: $CLEANED removed, $SEEDING seeding, $SKIPPED skipped"
    '';
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
