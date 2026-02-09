{ ... }:
{
  networking.firewall.enable = true;

  # Provider / edge firewall notes (public inbound):
  # - 22: SSH
  # - 80/443: HTTP(S) + ACME
  # - 25: SMTP (server-to-server inbound)
  # - 465/587: SMTP submission (mail clients/apps -> this server)
  # - 143/993: IMAP (plain/TLS)
  # - 4190: ManageSieve
  # - 7000: FRP
  # - 22000/tcp+udp + 21027/udp: Syncthing
  #
  # Outbound is unaffected by these rules; it depends on provider egress policy.
  networking.firewall.allowedTCPPorts = [
    22
    80
    443
    25
    143
    465
    587
    993
    4190
    7000
    22000
  ];
  networking.firewall.allowedUDPPorts = [
    22000
    21027
    # Tailscale (optional but helps direct connectivity).
    41641
  ];
}
