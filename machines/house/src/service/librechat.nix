{ config, pkgs, lib, ... }:
let
  ids = config.homelab.identifiers;
  rootDomain = ids.domain.root;
  sub = ids.subdomains;
  fqdn = name: "${name}.${rootDomain}";
in
{
  systemd.services.librechat = {
    description = "LibreChat AI assistant";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" "docker-mongodb.service" ];
    requires = [ "docker-mongodb.service" ];

    serviceConfig = {
      Type = "simple";
      User = "librechat";
      Group = "librechat";
      WorkingDirectory = "/var/lib/librechat";
      EnvironmentFile = config.sops.templates.librechat_env.path;
      Environment = [
        "HOST=127.0.0.1"
        "PORT=3080"
        "MONGO_URI=mongodb://127.0.0.1:27017/librechat"
        "DOMAIN_CLIENT=https://${fqdn sub.chat}"
        "DOMAIN_SERVER=https://${fqdn sub.chat}"
        "TRUST_PROXY=1"
        "ALLOW_REGISTRATION=false"
        "ALLOW_SOCIAL_LOGIN=true"
        "ALLOW_SOCIAL_REGISTRATION=true"
        "ANONYMIZED_TELEMETRY=false"
        "DEBUG_CONSOLE=false"
      ];
      ExecStart = "${pkgs.librechat}/bin/librechat-server";
      Restart = "on-failure";
      RestartSec = 5;

      # Hardening
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      ReadWritePaths = [ "/var/lib/librechat" ];
    };
  };

  users.users.librechat = {
    isSystemUser = true;
    group = "librechat";
    home = "/var/lib/librechat";
    createHome = true;
  };
  users.groups.librechat = {};

  systemd.tmpfiles.rules = [
    "d /var/lib/librechat 0750 librechat librechat -"
  ];

  services.nginx.virtualHosts."${fqdn sub.chat}" = {
    onlySSL = true;
    useACMEHost = rootDomain;
    locations."/" = {
      proxyPass = "http://127.0.0.1:3080";
      proxyWebsockets = true;
    };
  };
}
