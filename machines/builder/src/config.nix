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
  ];
}
