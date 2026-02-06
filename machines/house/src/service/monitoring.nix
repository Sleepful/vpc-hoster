{ config, pkgs, ... }:
let
  ids = config.homelab.identifiers;
  rootDomain = ids.domain.root;
  sub = ids.subdomains;
  fqdn = name: "${name}.${rootDomain}";
in
{
  services.grafana = {
    enable = true;
    settings.server = {
      http_addr = "127.0.0.1";
      http_port = 2342;
    };
  };

  services.prometheus = {
    enable = true;
    port = 9001;
    exporters.node = {
      enable = true;
      enabledCollectors = [ "systemd" ];
      port = 9002;
    };
    scrapeConfigs = [
      {
        job_name = "scrapeConfigs";
        static_configs = [
          {
            targets = [ "127.0.0.1:${toString config.services.prometheus.exporters.node.port}" ];
          }
        ];
      }
    ];
  };

  services.loki = {
    enable = true;
    configFile = ../data/loki-local-config.yaml;
  };

  systemd.services.promtail = {
    description = "Promtail service for Loki";
    wantedBy = [ "multi-user.target" ];
    serviceConfig.ExecStart = ''
      ${pkgs.grafana-loki}/bin/promtail --config.file ${../data/promtail.yaml}
    '';
  };

  services.nginx.virtualHosts."${fqdn sub.grafana}" = {
    onlySSL = true;
    useACMEHost = rootDomain;
    locations."/" = {
      proxyPass = "http://127.0.0.1:${toString config.services.grafana.settings.server.http_port}";
      proxyWebsockets = true;
    };
  };
}
