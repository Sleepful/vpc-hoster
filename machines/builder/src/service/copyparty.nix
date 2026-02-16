# Part of the media pipeline — see docs/media-pipeline.md
{ config, pkgs, ... }:
{
  # Copyparty: web file manager with WebDAV support.
  # Serves /media (syncthing content + B2 mount) for browsing, upload,
  # and pre-fetching files into the rclone VFS cache.
  #
  # Access: http://<builder-ip>:3923 (LAN / Tailscale)
  # WebDAV: mount in macOS Finder via Connect to Server -> http://<builder-ip>:3923
  # Default credentials: admin / <copyparty_password from SOPS>

  systemd.services.copyparty = {
    description = "Copyparty file server";
    after = [
      "network.target"
      "rclone-b2-mount.service"
    ];
    wants = [ "rclone-b2-mount.service" ];
    wantedBy = [ "multi-user.target" ];

    script = ''
      PASSWORD=$(cat ${config.sops.secrets.copyparty_password.path})
      exec ${pkgs.copyparty}/bin/copyparty \
        -p 3923 \
        -a "admin:$PASSWORD" \
        --usernames \
        -v /media::rw,admin \
        --daw
    '';

    serviceConfig = {
      User = "media";
      Group = "media";
      Restart = "on-failure";
      RestartSec = "5s";
    };
  };

  networking.firewall.allowedTCPPorts = [ 3923 ];
}
