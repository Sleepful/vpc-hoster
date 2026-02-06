{ config, lib, pkgs, ... }:
let
  ids = config.homelab.identifiers;
  rootDomain = ids.domain.root;
  sub = ids.subdomains;
  mail = ids.mail;
  fqdn = name: "${name}.${rootDomain}";
in
{
  nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [ "outline" ];

  users.users.dex = {
    isSystemUser = true;
    group = "dex";
  };
  users.groups.dex = { };

  services.outline = {
    enable = true;
    publicUrl = "https://${fqdn sub.outline}";
    port = 3003;
    forceHttps = false;
    storage.storageType = "local";
    oidcAuthentication = {
      authUrl = "https://${fqdn sub.dex}/auth";
      tokenUrl = "https://${fqdn sub.dex}/token";
      userinfoUrl = "https://${fqdn sub.dex}/userinfo";
      clientId = "outline";
      clientSecretFile = config.sops.secrets.outline_oidc_secret_for_outline.path;
      scopes = [
        "openid"
        "email"
        "profile"
      ];
      usernameClaim = "preferred_username";
      displayName = "Dex";
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

  services.dex = {
    enable = true;
    environmentFile = config.sops.templates.dex_env.path;
    settings = {
      oauth2.skipApprovalScreen = true;
      expiry.idTokens = "2160h";
      issuer = "https://${fqdn sub.dex}";
      storage.type = "sqlite3";
      web.http = "127.0.0.1:5556";
      enablePasswordDB = true;
      staticClients = [
        {
          id = "outline";
          name = "Outline Client";
          redirectURIs = [ "https://${fqdn sub.outline}/auth/oidc.callback" ];
          secretFile = config.sops.secrets.outline_oidc_secret_for_dex.path;
        }
      ];
      staticPasswords = [
        {
          email = mail.dexSuperAddress;
          # Dex staticPasswords has no secretFile option for hashes, so we use
          # fixed markers and replace them at service start from /run/secrets.
          hash = "__DEX_HASH_SUPER__";
          username = mail.dexSuperUsername;
          userID = "BC7AE212-43E9-4436-9811-9D6FD49F02D1";
        }
        {
          email = mail.dexAtlasAddress;
          hash = "__DEX_HASH_ATLAS__";
          username = mail.dexAtlasUsername;
          userID = "3E6463EF-08CB-490C-B8C0-18E87A66FEA8";
        }
        {
          email = mail.dexLumenAddress;
          hash = "__DEX_HASH_LUMEN__";
          username = mail.dexLumenUsername;
          userID = "D5B5352D-1792-4153-A745-C38A9653CB15";
        }
      ];
    };
  };

  systemd.services.dex.serviceConfig.ExecStartPre = lib.mkAfter [
    # Run after the module's config install + oidc secret replacement pre-starts.
    "${pkgs.runtimeShell} -c 'replace-secret __DEX_HASH_SUPER__ ${config.sops.secrets.dex_hash_super.path} /run/dex/config.yaml'"
    "${pkgs.runtimeShell} -c 'replace-secret __DEX_HASH_ATLAS__ ${config.sops.secrets.dex_hash_atlas.path} /run/dex/config.yaml'"
    "${pkgs.runtimeShell} -c 'replace-secret __DEX_HASH_LUMEN__ ${config.sops.secrets.dex_hash_lumen.path} /run/dex/config.yaml'"
  ];

  services.nginx.virtualHosts."${fqdn sub.outline}" = {
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

  services.nginx.virtualHosts."${fqdn sub.dex}" = {
    onlySSL = true;
    useACMEHost = rootDomain;
    locations."/" = {
      proxyPass = "http://${config.services.dex.settings.web.http}";
      proxyWebsockets = true;
    };
  };
}
