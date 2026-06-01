{ config, lib, pkgs, ... }:
let
  ids = config.homelab.identifiers;
  rootDomain = ids.domain.root;
  sub = ids.subdomains;
  fqdn = name: "${name}.${rootDomain}";
in
{
  services.matrix-synapse = {
    enable = true;
    extras = ["oidc"];
    enableRegistrationScript = true;

    settings = {
      server_name = rootDomain;
      public_baseurl = "https://${fqdn sub.matrix}";

      database.name = "psycopg2";
      database.args = {
        user = "matrix-synapse";
        database = "matrix-synapse";
        host = "/run/postgresql";
      };

      listeners = [
        {
          port = 8008;
          bind_addresses = [ "::1" ];
          type = "http";
          tls = false;
          x_forwarded = true;
          resources = [
            {
              names = [ "client" ];
              compress = false;
            }
          ];
        }
      ];

      enable_registration = false;

      # Homelab is a private island — no user directory browsing,
      # no profile lookups between users who don't share a room.
      enable_room_list_search = false;
      limit_profile_requests_to_users_who_share_rooms = true;

      # Federation is disabled — homelab is a private island.
      # See docs/matrix-federation.md for the dual-instance plan.
      federation_domain_whitelist = [];

      url_preview_enabled = true;
      url_preview_ip_range_blacklist = [
        "127.0.0.0/8"
        "10.0.0.0/8"
        "172.16.0.0/12"
        "192.168.0.0/16"
        "100.64.0.0/10"
        "169.254.0.0/16"
        "::1/128"
        "fe80::/64"
        "fc00::/7"
      ];
    };

    extraConfigFiles = [
      config.sops.templates."synapse-extra".path
    ];
  };
}
