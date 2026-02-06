{ ... }:
{
  networking.firewall.enable = true;
  networking.firewall.allowedTCPPorts = [
    22
    80
    443
    7000
    22000
  ];
  networking.firewall.allowedUDPPorts = [
    22000
    21027
  ];
}
