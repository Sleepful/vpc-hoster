{ pkgs, ... }:
{
  system.stateVersion = "25.05";
  networking.hostName = "homelab-nixos-builder";

  imports = [
    ./service/tailnet.nix
  ];
}
