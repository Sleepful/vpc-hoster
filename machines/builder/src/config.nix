{ pkgs, ... }:
{
  networking.hostName = "homelab-nixos-builder";

  imports = [
    ./service/tailnet.nix
  ];
}
