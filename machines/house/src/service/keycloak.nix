{ config, ... }:
let
  ids = config.homelab.identifiers;
  rootDomain = ids.domain.root;
  sub = ids.subdomains;
  fqdn = name: "${name}.${rootDomain}";
in
{
  services.keycloak = {
    enable = true;
    database = {
      createLocally = true;
      host = "localhost";
      passwordFile = config.sops.secrets.keycloak_db_password.path;
    };
    settings = {
      http-host = "127.0.0.1";
      http-port = 8081;
      http-enabled = true;
      proxy-headers = "xforwarded";
      hostname = fqdn sub.auth;
      hostname-backchannel-dynamic = false;
    };
  };

  # Load admin credentials via EnvironmentFile (systemd reads as root)
  systemd.services.keycloak.serviceConfig.EnvironmentFile =
    config.sops.templates.keycloak_admin_env.path;

  services.nginx.virtualHosts."${fqdn sub.auth}" = {
    onlySSL = true;
    useACMEHost = rootDomain;
    locations."/" = {
      proxyPass = "http://127.0.0.1:8081";
      proxyWebsockets = true;
      extraConfig = ''
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
      '';
    };
  };
}
