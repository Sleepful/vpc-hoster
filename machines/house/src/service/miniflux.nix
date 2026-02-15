{ config, ... }:
let
  ids = config.homelab.identifiers;
  rootDomain = ids.domain.root;
  sub = ids.subdomains;
  fqdn = name: "${name}.${rootDomain}";
  miniPort = "3131";
in
{
  services.miniflux = {
    enable = true;
    adminCredentialsFile = config.sops.templates.miniflux_creds.path;
    config = {
      CLEANUP_FREQUENCY = "48";
      LISTEN_ADDR = "localhost:${miniPort}";
      FETCH_YOUTUBE_WATCH_TIME = "true";
    };
  };

  # DynamicUser miniflux needs explicit peer auth in pg_hba.conf
  # (nixpkgs 25.11 no longer adds this automatically)
  services.postgresql.authentication = ''
    local miniflux miniflux peer
  '';

  services.nginx.virtualHosts."${fqdn sub.mini}" = {
    onlySSL = true;
    useACMEHost = rootDomain;
    locations."/" = {
      proxyPass = "http://localhost:${miniPort}";
      proxyWebsockets = true;
    };
  };
}
