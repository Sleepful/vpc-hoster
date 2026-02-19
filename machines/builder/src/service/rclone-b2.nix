# Part of the media pipeline — see docs/media-pipeline.md
{ config, pkgs, ... }:
{
  environment.systemPackages = [
    pkgs.rclone
    pkgs.fuse3
  ];

  # Required for --allow-other on the FUSE mount so Jellyfin/Copyparty
  # (running as media user) can access the mount owned by root.
  programs.fuse.userAllowOther = true;

  systemd.services.rclone-b2-mount = {
    description = "rclone FUSE mount for Backblaze B2";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "notify";
      EnvironmentFile = config.sops.templates.rclone_b2_env.path;
      ExecStartPre = "${pkgs.coreutils}/bin/mkdir -p /media/b2";
      # Streaming performance flags:
      # Without read-ahead, rclone only fetches bytes from B2 on demand which
      # causes Jellyfin buffering on cold (uncached) files.
      #   buffer-size 512M    — per-file in-memory read buffer (default 16M).
      #                         Larger buffer = fewer round-trips to B2.
      #   vfs-read-ahead 1G   — background prefetch beyond current read position
      #                         (default 0). When Jellyfin starts playing, rclone
      #                         pre-fetches the next 1G from B2 so data is ready
      #                         before the player needs it. Key flag for streaming.
      #   vfs-read-chunk-streams 4 — download 4 chunks in parallel (default 0 = sequential).
      #                              Speeds up initial fill of the read-ahead buffer.
      #   vfs-fast-fingerprint — cache validation uses size+modtime instead of hash.
      #                          Avoids re-downloading just to check cache validity.
      #
      # RC API flags:
      # HTTP interface at :5572 for cache stats and the rclone web GUI.
      # Bound to 0.0.0.0 so the web GUI is accessible from LAN/Tailscale.
      # No auth — access is restricted by the firewall (Tailscale trustedInterfaces).
      # All RC endpoints require POST. Useful ones:
      #   curl -X POST localhost:5572/vfs/stats    — cache size, open files
      #   curl -X POST localhost:5572/core/stats   — active transfers, bandwidth
      #
      # Transfer logging:
      # Logs transfer stats every 30s, visible via: journalctl -u rclone-b2-mount -f
      ExecStart = ''
        ${pkgs.rclone}/bin/rclone mount b2:entertainment-netmount /media/b2 \
          --vfs-cache-mode full \
          --vfs-cache-max-size 50G \
          --vfs-cache-max-age 48h \
          --allow-other \
          --dir-cache-time 1m \
          --use-mmap \
          --buffer-size 512M \
          --vfs-read-ahead 1G \
          --vfs-read-chunk-streams 4 \
          --vfs-fast-fingerprint \
          --rc \
          --rc-addr 0.0.0.0:5572 \
          --rc-no-auth \
          --rc-web-gui \
          --rc-web-gui-no-open-browser \
          --stats 30s \
          --log-level INFO
      '';
      ExecStop = "${pkgs.fuse3}/bin/fusermount3 -u /media/b2";
      Restart = "on-failure";
      RestartSec = "10s";
    };
  };
}
