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
    enableRegistrationScript = true;

    settings = {
      server_name = rootDomain;
      public_baseurl = "https://${fqdn sub.matrix}";

      database.name = "psycopg2";
      database.args = {
        user = "matrix-synapse";
        dbname = "matrix-synapse";
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
              names = [ "client" "federation" ];
              compress = false;
            }
          ];
        }
      ];

      enable_registration = false;

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
  };
}
