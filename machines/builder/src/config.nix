{ config, ... }:
let
  ids = config.homelab.identifiers;
in
{
  system.stateVersion = "25.05";
  networking.hostName = "nixos-builder";
  networking.hosts."${ids.hosts.house.ipv4}" = [
    ids.hosts.house.name
  ];

  programs.ssh.knownHosts = {
    "${ids.hosts.house.name}" = {
      hostNames = [
        ids.hosts.house.name
        ids.hosts.house.ipv4
      ];
      publicKey = ids.hosts.house.sshHostPublicKey;
    };
  };

  imports = [
    ./service/tailnet.nix
    ./service/jellyfin.nix
    ./service/syncthing.nix
    ./service/secrets.nix
    ./service/rclone-b2.nix
    ./service/copyparty.nix
    ./service/web.nix
    ./service/qbittorrent.nix
    ./service/prowlarr.nix
    ./service/sonarr.nix
    ./service/radarr.nix
    ./service/bazarr.nix
  ];
}
