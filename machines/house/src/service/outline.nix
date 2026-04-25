{ config, lib, pkgs, ... }:
let
  ids = config.homelab.identifiers;
  rootDomain = ids.domain.root;
  sub = ids.subdomains;
  mail = ids.mail;
  fqdn = name: "${name}.${rootDomain}";
in
{
  services.outline = {
    enable = true;
    publicUrl = "https://${fqdn sub.docs}";
    port = 3003;
    forceHttps = false;
    storage.storageType = "local";
    oidcAuthentication = {
      authUrl = "https://${fqdn sub.auth}/realms/master/protocol/openid-connect/auth";
      tokenUrl = "https://${fqdn sub.auth}/realms/master/protocol/openid-connect/token";
      userinfoUrl = "https://${fqdn sub.auth}/realms/master/protocol/openid-connect/userinfo";
      clientId = "outline";
      clientSecretFile = config.sops.secrets.outline_oidc_secret.path;
      scopes = [
        "openid"
        "email"
        "profile"
      ];
      usernameClaim = "preferred_username";
      displayName = "Keycloak";
    };
    smtp = {
      username = mail.outlineNoReplyAddress;
      passwordFile = config.sops.templates.outline_smtp_password.path;
      host = config.mailserver.fqdn;
      port = 465;
      fromEmail = "Outline <${mail.outlineNoReplyAddress}>";
      replyEmail = mail.outlineReplyAddress;
    };
  };

  services.nginx.virtualHosts."${fqdn sub.docs}" = {
    onlySSL = true;
    useACMEHost = rootDomain;
    locations."/" = {
      proxyPass = "http://localhost:${toString config.services.outline.port}";
      proxyWebsockets = true;
      extraConfig = ''
        proxy_set_header X-Scheme $scheme;
      '';
    };
  };
}
