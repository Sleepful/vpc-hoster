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
    host = "127.0.0.1";
    mutableConfig = true;
    database.driver = "postgres";
    environmentFile = config.sops.templates."mattermost-oidc-env".path;

    settings = {
      OpenIdSettings = {
        Enable = true;
        DiscoveryEndpoint = "https://${fqdn sub.auth}/realms/${ids.keycloakRealm}/.well-known/openid-configuration";
        ClientId = "mattermost";
        # ClientSecret set via environmentFile (sops) to avoid Nix store
        ButtonText = "Login with Keycloak";
        ButtonColor = "#ADD015";
        Scope = "openid profile email";
      };
    };
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
