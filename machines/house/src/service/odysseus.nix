{ config, pkgs, ... }:
let
  ids = config.homelab.identifiers;
  rootDomain = ids.domain.root;
  sub = ids.subdomains;
  fqdn = name: "${name}.${rootDomain}";
in
{
  virtualisation.oci-containers.containers = {
    chromadb = {
      image = "docker.io/chromadb/chroma:latest";
      autoStart = true;
      ports = [ "127.0.0.1:8100:8000" ];
      volumes = [ "/var/lib/chromadb:/chroma/chroma" ];
      environment = {
        ANONYMIZED_TELEMETRY = "FALSE";
      };
    };

    searxng = {
      image = "docker.io/searxng/searxng:2026.5.31-7159b8aed";
      autoStart = true;
      ports = [ "127.0.0.1:8080:8080" ];
      volumes = [ "/var/lib/searxng:/etc/searxng" ];
      environment = {
        SEARXNG_BASE_URL = "http://localhost:8080/";
      };
      environmentFiles = [ config.sops.templates."odysseus-searxng-env".path ];
      extraOptions = [
        "--cap-add=CHOWN"
        "--cap-add=SETGID"
        "--cap-add=SETUID"
        "--cap-add=DAC_OVERRIDE"
      ];
    };

    # Build and push image on house (one-time, then redeploy):
    #   git clone https://github.com/pewdiepie-archdaemon/odysseus.git /tmp/odysseus-build
    #   docker build -t 127.0.0.1:5000/odysseus:latest /tmp/odysseus-build
    #   docker push 127.0.0.1:5000/odysseus:latest
    #   rm -rf /tmp/odysseus-build
    odysseus = {
      image = "127.0.0.1:5000/odysseus:latest";
      autoStart = true;
      ports = [ "127.0.0.1:7001:7000" ];
      dependsOn = [ "chromadb" "searxng" ];
      volumes = [
        "/var/lib/odysseus/data:/app/data:z"
        "/var/lib/odysseus/logs:/app/logs:z"
        "/var/lib/odysseus/ssh:/app/.ssh:z"
        "/var/lib/odysseus/huggingface:/app/.cache/huggingface:z"
        "/var/lib/odysseus/local:/app/.local:z"
      ];
      environment = {
        SEARXNG_INSTANCE = "http://searxng:8080";
        CHROMADB_HOST = "chromadb";
        CHROMADB_PORT = "8000";
        DATABASE_URL = "sqlite:///./data/app.db";
        AUTH_ENABLED = "true";
        LOCALHOST_BYPASS = "false";
        SECURE_COOKIES = "true";
        ODYSSEUS_ADMIN_USER = ids.users.deployUser;
        PUID = "1000";
        PGID = "1000";
      };
      environmentFiles = [ config.sops.templates."odysseus-env".path ];
      extraOptions = [
        "--add-host=host.docker.internal:host-gateway"
      ];
    };
  };

  services.nginx.virtualHosts."${fqdn sub.chat}" = {
    onlySSL = true;
    useACMEHost = rootDomain;
    locations."/" = {
      proxyPass = "http://127.0.0.1:7001";
      proxyWebsockets = true;
    };
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/chromadb 0750 root root -"
    "d /var/lib/searxng 0750 root root -"
    "d /var/lib/odysseus 0750 root root -"
    "d /var/lib/odysseus/data 0750 root root -"
    "d /var/lib/odysseus/logs 0750 root root -"
    "d /var/lib/odysseus/ssh 0750 root root -"
    "d /var/lib/odysseus/huggingface 0750 root root -"
    "d /var/lib/odysseus/local 0750 root root -"
  ];
}
