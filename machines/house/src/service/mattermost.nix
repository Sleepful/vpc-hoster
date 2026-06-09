{ config, pkgs, lib, ... }:
let
  ids = config.homelab.identifiers;
  rootDomain = ids.domain.root;
  sub = ids.subdomains;
  fqdn = name: "${name}.${rootDomain}";
in
{
  services.mattermost = {
    enable = true;
    siteUrl = "https://${fqdn sub.mm}";
    listenAddress = "127.0.0.1:8065";
    mutableConfig = true;
    preferNixConfig = true;
    database.driver = "postgres";
  };

  services.nginx.virtualHosts."${fqdn sub.mm}" = {
    onlySSL = true;
    useACMEHost = rootDomain;
    locations."/" = {
      proxyPass = "http://127.0.0.1:8065";
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
