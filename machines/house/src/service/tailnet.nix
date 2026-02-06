{ config, pkgs, ... }:
{
  services.tailscale.enable = true;
  services.tailscale.useRoutingFeatures = "server";

  environment.systemPackages = [
    pkgs.tailscale
  ];

  networking.firewall.trustedInterfaces = [ "tailscale0" ];
  networking.firewall.allowedUDPPorts = [ config.services.tailscale.port ];
}
