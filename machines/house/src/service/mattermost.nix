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
      ServiceSettings = {
        TrustedProxyIPHeader = [
          "X-Forwarded-For"
          "X-Real-IP"
        ];
      };
      GitLabSettings = {
        Enable = true;
        Id = "mattermost";
        Secret = "";
        Scope = "openid";
        DiscoveryEndpoint = "https://${fqdn sub.auth}/realms/${ids.keycloakRealm}/.well-known/openid-configuration";
        AuthEndpoint = "https://${fqdn sub.auth}/realms/${ids.keycloakRealm}/protocol/openid-connect/auth";
        TokenEndpoint = "https://${fqdn sub.auth}/realms/${ids.keycloakRealm}/protocol/openid-connect/token";
        UserAPIEndpoint = "https://${fqdn sub.auth}/realms/${ids.keycloakRealm}/protocol/openid-connect/userinfo";
        ButtonText = "Login with Keycloak";
        ButtonColor = "#ADD015";
      };
    };
  };

  services.nginx.virtualHosts."${fqdn sub.mm}" = {
    onlySSL = true;
    useACMEHost = rootDomain;
    locations."/" = {
      proxyPass = "http://127.0.0.1:8065";
      proxyWebsockets = true;
    };
  };
}
