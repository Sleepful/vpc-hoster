{ config, ... }:
let
  ids = config.homelab.identifiers;
  rootDomain = ids.domain.root;
  sub = ids.subdomains;
  fqdn = name: "${name}.${rootDomain}";
  acmeWebRoot = "/var/lib/acme/.challenges";
  extraDomainNames = map fqdn [
    sub.cal
    sub.dex
    sub.email
    sub.grafana
    sub.mail
    sub.mini
    sub.outline
    sub.sync
    sub.tunnel
  ];
in
{
  security.acme.acceptTerms = true;
  security.acme.defaults.email = ids.domain.acmeEmail;
  security.acme.certs."${rootDomain}" = {
    webroot = acmeWebRoot;
    group = "nginx";
    extraDomainNames = extraDomainNames;
  };
  security.acme.certs."${fqdn sub.mail}" = {
    webroot = acmeWebRoot;
    group = "nginx";
    extraDomainNames = [
      (fqdn sub.cal)
      (fqdn sub.email)
    ];
  };

  users.users.nginx.extraGroups = [ "acme" ];

  services.nginx = {
    enable = true;
    recommendedProxySettings = true;
    recommendedTlsSettings = true;
    virtualHosts = {
      "${fqdn sub.acmechallenge}" = {
        serverAliases = [ "*.${rootDomain}" ];
        locations."/.well-known/acme-challenge".root = acmeWebRoot;
        locations."/".return = "301 https://$host$request_uri";
      };
      "${rootDomain}" = {
        default = true;
        onlySSL = true;
        useACMEHost = rootDomain;
        locations."/".root = "/var/www";
      };
    };
  };

  system.activationScripts.houseLandingPage.text = ''
    mkdir -p /var/www
    echo "house" > /var/www/index.html
  '';
}
