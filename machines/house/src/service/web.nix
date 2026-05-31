{ config, ... }:
let
  ids = config.homelab.identifiers;
  rootDomain = ids.domain.root;
  sub = ids.subdomains;
  fqdn = name: "${name}.${rootDomain}";
  acmeWebRoot = "/var/lib/acme/.challenges";
  extraDomainNames = map fqdn [
    sub.auth
    sub.cal
    sub.dex
    sub.docs
    sub.email
    sub.grafana
    sub.mail
    sub.matrix
    sub.mini
    sub.outline
    sub.sync
    sub.torrent
    sub.tunnel
  ];

  muralDomain = ids.mural.root;
  muralSub = ids.mural.subdomains;
in
{
  security.acme.acceptTerms = true;
  security.acme.defaults.email = ids.domain.acmeEmail;
  security.acme.certs."${rootDomain}" = {
    webroot = acmeWebRoot;
    group = "nginx";
    extraDomainNames = extraDomainNames;
  };
  # Separate cert for the mail stack — postfix and dovecot reference this path directly.
  security.acme.certs."${fqdn sub.mail}" = {
    webroot = acmeWebRoot;
    group = "nginx";
    extraDomainNames = [
      (fqdn sub.cal)
      (fqdn sub.email)
    ];
  };
  # Cert for secondary domain — add future subdomains to extraDomainNames here.
  security.acme.certs."${muralDomain}" = {
    webroot = acmeWebRoot;
    group = "nginx";
    extraDomainNames = [
      "${muralSub.foro}.${muralDomain}"
    ];
  };

  users.users.nginx.extraGroups = [ "acme" ];

  services.nginx = {
    enable = true;
    recommendedProxySettings = true;
    recommendedTlsSettings = true;
    virtualHosts = {
      "${fqdn sub.acmechallenge}" = {
        serverAliases = [ "*.${rootDomain}" "*.${muralDomain}" ];
        locations."/.well-known/acme-challenge".root = acmeWebRoot;
        locations."/".return = "301 https://$host$request_uri";
      };
      "${rootDomain}" = {
        default = true;
        onlySSL = true;
        useACMEHost = rootDomain;
        locations."/".root = "/var/www";
        locations."= /.well-known/matrix/server".extraConfig = ''
          add_header Content-Type application/json;
          return 200 '{"m.server": "${fqdn sub.matrix}:443"}';
        '';
        locations."= /.well-known/matrix/client".extraConfig = ''
          add_header Content-Type application/json;
          add_header Access-Control-Allow-Origin *;
          return 200 '{"m.homeserver": {"base_url": "https://${fqdn sub.matrix}"}}';
        '';
      };
      "${fqdn sub.matrix}" = {
        onlySSL = true;
        useACMEHost = rootDomain;
        locations."/".return = "404";
        locations."/_matrix" = {
          proxyPass = "http://[::1]:8008";
          proxyWebsockets = true;
        };
        locations."/_synapse/client" = {
          proxyPass = "http://[::1]:8008";
        };
      };
    };
  };

  # qBittorrent web UI reverse proxy
  services.nginx.virtualHosts."${fqdn sub.torrent}" = {
    onlySSL = true;
    useACMEHost = rootDomain;
    locations."/" = {
      proxyPass = "http://127.0.0.1:8080";
      proxyWebsockets = true;
    };
  };

  system.activationScripts.houseLandingPage.text = ''
    mkdir -p /var/www
    echo "house" > /var/www/index.html
  '';
}
