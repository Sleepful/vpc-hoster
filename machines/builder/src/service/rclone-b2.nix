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
      ExecStart = ''
        ${pkgs.rclone}/bin/rclone mount b2:entertainment-netmount /media/b2 \
          --vfs-cache-mode full \
          --vfs-cache-max-size 150G \
          --vfs-cache-max-age 168h \
          --allow-other \
          --dir-cache-time 1m \
          --use-mmap
      '';
      ExecStop = "${pkgs.fuse3}/bin/fusermount3 -u /media/b2";
      Restart = "on-failure";
      RestartSec = "10s";
    };
  };
}
