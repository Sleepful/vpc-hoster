/*
  qBittorrent with automatic B2 upload and seeding.

  Workflow:
    1. qBittorrent downloads to downloading/ (TempPath).
    2. On completion, qBittorrent moves the file to completed/ (DefaultSavePath)
       and begins seeding from there.
    3. qbt-upload-b2.path detects the new file immediately and triggers
       qbt-upload-b2.service, which uploads it to B2. The local file is kept
       for seeding.
    4. After 7 days of seeding, qBittorrent removes the torrent from its list
       but leaves the local file on disk.
    5. qbt-cleanup.timer runs every 10 minutes, queries the qBittorrent API
       for active torrent paths, and deletes any file in completed/ that is
       no longer tracked (orphaned after torrent removal).

  Directories:
    /var/lib/qBittorrent/downloading  — in-progress downloads
    /var/lib/qBittorrent/completed    — finished downloads (seeding + upload)

  Manual operations:
    - To free disk early: remove the torrent from qBittorrent's web UI, then
      either wait up to 10 minutes or run `systemctl start qbt-cleanup`.
    - To monitor: `just qbt-logs` (follows qbittorrent, upload, and cleanup).
    - To retry a failed upload: `systemctl start qbt-upload-b2`.

  Systemd units:
    qbt-upload-b2.path     — watches completed/ via inotify (DirectoryNotEmpty)
    qbt-upload-b2.service  — uploads to B2, keeps local files, retries on failure
    qbt-cleanup.timer      — fires every 10 min
    qbt-cleanup.service    — deletes orphaned files not tracked by qBittorrent
*/
{ config, pkgs, ... }:
let
  ids = config.homelab.identifiers;
  completedDir = "/var/lib/qBittorrent/completed";
  webuiPort = 8080;
in
{
  services.qbittorrent = {
    enable = true;
    inherit webuiPort;
    torrentingPort = 6881;

    serverConfig = {
      LegalNotice.Accepted = true;

      Preferences."WebUI\\Password_PBKDF2" = ids.qbittorrent.passwordHash;

      BitTorrent.Session = {
        DefaultSavePath = completedDir;
        TempPathEnabled = true;
        TempPath = "/var/lib/qBittorrent/downloading";
        # Seed for 7 days then remove torrent from list (files stay on disk)
        MaxRatioAction = 1; # Remove
        GlobalMaxSeedingMinutes = 10080; # 7 days
      };
    };
  };

  # Ensure download directories exist with correct ownership
  systemd.tmpfiles.rules = [
    "d /var/lib/qBittorrent/downloading 0755 qbittorrent qbittorrent -"
    "d ${completedDir} 0755 qbittorrent qbittorrent -"
  ];

  # Upload completed downloads to B2 (does not delete local files).
  # Triggered by the path unit whenever the completed directory is non-empty.
  systemd.services.qbt-upload-b2 = {
    description = "Upload completed qBittorrent downloads to B2";
    # Run once at boot to upload anything missed before a reboot
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "oneshot";
      User = "qbittorrent";
      Group = "qbittorrent";
      EnvironmentFile = config.sops.templates.rclone_b2_env.path;
      Restart = "on-failure";
      RestartSec = "30s";
    };

    script = ''
      for ITEM in ${completedDir}/*; do
        [ -e "$ITEM" ] || continue

        NAME=$(${pkgs.coreutils}/bin/basename "$ITEM")

        if [ -d "$ITEM" ]; then
          DEST="b2:entertainment-netmount/downloads/$NAME"
        else
          DEST="b2:entertainment-netmount/downloads/"
        fi

        echo "Uploading: $NAME"
        if ! ${pkgs.rclone}/bin/rclone copy "$ITEM" "$DEST" \
            --transfers 4 --checksum --stats 30s --stats-log-level NOTICE; then
          echo "Upload failed: $ITEM"
          continue
        fi

        echo "Uploaded: $NAME"
      done
    '';
  };

  # Watch the completed directory and trigger the upload service
  systemd.paths.qbt-upload-b2 = {
    description = "Watch for completed qBittorrent downloads";
    wantedBy = [ "multi-user.target" ];

    pathConfig = {
      DirectoryNotEmpty = completedDir;
      MakeDirectory = true;
    };
  };

  # Delete local files that are no longer tracked by any qBittorrent torrent.
  # Runs every 10 minutes. Queries the qBittorrent API for active content paths
  # and removes anything in completed/ that isn't in that list.
  systemd.services.qbt-cleanup = {
    description = "Clean up orphaned qBittorrent downloads";

    serviceConfig = {
      Type = "oneshot";
      User = "qbittorrent";
      Group = "qbittorrent";
    };

    script = ''
      # Get content paths of all torrents qBittorrent is tracking
      ACTIVE=$(${pkgs.curl}/bin/curl -sf "http://localhost:${toString webuiPort}/api/v2/torrents/info" \
        | ${pkgs.jq}/bin/jq -r '.[].content_path // empty')

      if [ -z "$ACTIVE" ] && [ $? -ne 0 ]; then
        echo "Failed to query qBittorrent API, skipping cleanup"
        exit 0
      fi

      for ITEM in ${completedDir}/*; do
        [ -e "$ITEM" ] || continue

        # Skip if qBittorrent is still tracking this path
        if echo "$ACTIVE" | ${pkgs.gnugrep}/bin/grep -qxF "$ITEM"; then
          continue
        fi

        ${pkgs.coreutils}/bin/rm -rf "$ITEM"
        echo "Cleaned orphan: $(${pkgs.coreutils}/bin/basename "$ITEM")"
      done
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

  # rclone is needed by the upload service
  environment.systemPackages = [ pkgs.rclone ];

  # Allow the qbittorrent user to read the SOPS-rendered rclone env file
  sops.templates.rclone_b2_env.group = "qbittorrent";
}
