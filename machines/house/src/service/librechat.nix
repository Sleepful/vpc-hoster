{ config, pkgs, lib, ... }:
let
  ids = config.homelab.identifiers;
  rootDomain = ids.domain.root;
  sub = ids.subdomains;
  fqdn = name: "${name}.${rootDomain}";
   librechatYaml = pkgs.writeText "librechat.yaml" ''
    version: 1.3.5
    cache: true
    endpoints:
      custom:
        - name: "Moonshot"
          apiKey: "''${MOONSHOT_API_KEY}"
          baseURL: "https://api.moonshot.ai/v1"
          models:
            default: ["kimi-k2.6"]
            fetch: true
          titleConvo: true
          titleModel: "kimi-k2.6"
          modelDisplayLabel: "Moonshot"
        - name: "DeepSeek"
          apiKey: "''${DEEPSEEK_API_KEY}"
          baseURL: "https://api.deepseek.com/v1"
          models:
            default: ["deepseek-chat"]
            fetch: true
          titleConvo: true
          titleModel: "deepseek-chat"
          modelDisplayLabel: "DeepSeek"
    mcpServers:
      exa:
        type: streamable-http
        url: https://mcp.exa.ai/mcp
        headers:
          x-api-key: "''${EXA_API_KEY}"
      brave-search:
        type: stdio
        command: npx
        args:
          - -y
          - "@brave/brave-search-mcp-server"
        env:
          BRAVE_API_KEY: "''${BRAVE_API_KEY}"
  '';
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
        "CONFIG_PATH=/var/lib/librechat/librechat.yaml"
        "TRUST_PROXY=1"
        "ALLOW_REGISTRATION=false"
        "ALLOW_SOCIAL_LOGIN=true"
        "ALLOW_SOCIAL_REGISTRATION=true"
        "ANONYMIZED_TELEMETRY=false"
        "DEBUG_CONSOLE=false"
        "HOME=/var/lib/librechat"
        "PATH=${lib.makeBinPath [ pkgs.nodejs pkgs.coreutils ]}:/run/wrappers/bin:/usr/bin:/bin"
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

    # Copy config file before starting
    preStart = ''
      ${pkgs.coreutils}/bin/cp ${librechatYaml} /var/lib/librechat/librechat.yaml
      ${pkgs.coreutils}/bin/chown librechat:librechat /var/lib/librechat/librechat.yaml
      ${pkgs.coreutils}/bin/chmod 644 /var/lib/librechat/librechat.yaml
    '';
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
