{ config, ... }:
let
  ids = config.homelab.identifiers;
  rootDomain = ids.domain.root;
  sub = ids.subdomains;
  fqdn = name: "${name}.${rootDomain}";
in
{
  services.frp = {
    enable = true;
    role = "server";
    settings.common = {
      bind_port = 7000;
      vhost_http_port = 8888;
    };
  };

  services.nginx.virtualHosts."${fqdn sub.tunnel}" = {
    onlySSL = true;
    useACMEHost = rootDomain;
    locations."/" = {
      proxyPass = "http://localhost:8888";
      proxyWebsockets = true;
    };
  };
}
