{ pkgs, modulesPath, ... }:
{
  services.journald.extraConfig = ''
    SystemMaxUse=300M
  '';
  environment.systemPackages = [
    pkgs.tree
  ];

  networking.hostName = "homelab-nixos-builder";

  imports = [ 
    ./service/tailnet.nix
  ];

}
