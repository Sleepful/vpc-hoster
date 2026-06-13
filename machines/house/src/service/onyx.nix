{ config, pkgs, lib, ... }:
let
  ids = config.homelab.identifiers;
  rootDomain = ids.domain.root;
  sub = ids.subdomains;
  fqdn = name: "${name}.${rootDomain}";
in
{
  virtualisation.oci-containers.containers = {
    onyx-db = {
      image = "docker.io/library/postgres:15.2-alpine";
      autoStart = true;
      environment = {
        POSTGRES_USER = "postgres";
      };
      environmentFiles = [ config.sops.templates."onyx-env".path ];
      cmd = [ "-c" "max_connections=250" ];
      extraOptions = [ "--shm-size=1g" ];
      volumes = [ "/var/lib/onyx/postgres:/var/lib/postgresql/data" ];
    };

    onyx-redis = {
      image = "docker.io/library/redis:7.4-alpine";
      autoStart = true;
      cmd = [ "redis-server" "--save" "" "--appendonly" "no" ];
    };

    onyx-opensearch = {
      image = "docker.io/opensearchproject/opensearch:3.6.0";
      autoStart = true;
      environment = {
        "discovery.type" = "single-node";
        "bootstrap.memory_lock" = "true";
        "OPENSEARCH_JAVA_OPTS" = "-Xms2g -Xmx2g";
      };
      environmentFiles = [ config.sops.templates."onyx-env".path ];
      extraOptions = [
        "--ulimit" "memlock=-1:-1"
        "--ulimit" "nofile=65536:65536"
        "--cap-add=IPC_LOCK"
      ];
      volumes = [ "/var/lib/onyx/opensearch:/usr/share/opensearch/data" ];
    };

    onyx-model = {
      image = "docker.io/onyxdotapp/onyx-model-server:latest";
      autoStart = true;
      cmd = [ "uvicorn" "model_server.main:app" "--host" "0.0.0.0" "--port" "9000" ];
      volumes = [ "/var/lib/onyx/model-cache-inference:/app/.cache/huggingface" ];
    };

    onyx-indexing-model = {
      image = "docker.io/onyxdotapp/onyx-model-server:latest";
      autoStart = true;
      environment = {
        INDEXING_ONLY = "True";
      };
      cmd = [ "uvicorn" "model_server.main:app" "--host" "0.0.0.0" "--port" "9000" ];
      volumes = [ "/var/lib/onyx/model-cache-indexing:/app/.cache/huggingface" ];
    };

    onyx-api = {
      image = "docker.io/onyxdotapp/onyx-backend:latest";
      autoStart = true;
      ports = [ "127.0.0.1:8080:8080" ];
      dependsOn = [
        "onyx-db"
        "onyx-redis"
        "onyx-opensearch"
        "onyx-model"
        "onyx-indexing-model"
      ];
      environment = {
        AUTH_TYPE = "oidc";
        OAUTH_CLIENT_ID = "onyx";
        OPENID_CONFIG_URL = "https://${fqdn sub.auth}/realms/${ids.keycloakRealm}/.well-known/openid-configuration";
        WEB_DOMAIN = "${fqdn sub.chat}";
        POSTGRES_HOST = "onyx-db";
        REDIS_HOST = "onyx-redis";
        OPENSEARCH_HOST = "onyx-opensearch";
        MODEL_SERVER_HOST = "onyx-model";
        INDEXING_MODEL_SERVER_HOST = "onyx-indexing-model";
        FILE_STORE_BACKEND = "postgres";
        DISABLE_TELEMETRY = "true";
      };
      environmentFiles = [ config.sops.templates."onyx-env".path ];
      cmd = [
        "/bin/sh"
        "-c"
        "alembic upgrade head && echo \"Starting Onyx Api Server\" && uvicorn onyx.main:app --host 0.0.0.0 --port 8080"
      ];
      volumes = [ "/var/lib/onyx/api-logs:/var/log/onyx" ];
    };

    onyx-web = {
      image = "docker.io/onyxdotapp/onyx-web-server:latest";
      autoStart = true;
      ports = [ "127.0.0.1:3001:3000" ];
      dependsOn = [ "onyx-api" ];
      environment = {
        INTERNAL_URL = "http://onyx-api:8080";
      };
    };

    onyx-background = {
      image = "docker.io/onyxdotapp/onyx-backend:latest";
      autoStart = true;
      dependsOn = [
        "onyx-db"
        "onyx-redis"
        "onyx-opensearch"
        "onyx-model"
        "onyx-indexing-model"
      ];
      environment = {
        POSTGRES_HOST = "onyx-db";
        REDIS_HOST = "onyx-redis";
        OPENSEARCH_HOST = "onyx-opensearch";
        MODEL_SERVER_HOST = "onyx-model";
        INDEXING_MODEL_SERVER_HOST = "onyx-indexing-model";
        FILE_STORE_BACKEND = "postgres";
        DISABLE_TELEMETRY = "true";
      };
      environmentFiles = [ config.sops.templates."onyx-env".path ];
      cmd = [
        "/bin/sh"
        "-c"
        "if [ -f /etc/ssl/certs/custom-ca.crt ]; then update-ca-certificates; fi && /app/scripts/supervisord_entrypoint.sh"
      ];
      volumes = [ "/var/lib/onyx/bg-logs:/var/log/onyx" ];
    };
  };

  services.nginx.virtualHosts."${fqdn sub.chat}" = {
    onlySSL = true;
    useACMEHost = rootDomain;
    locations = {
      "~ ^/api/ws/".extraConfig = ''
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
      '';
      "/api/".extraConfig = ''
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_buffering off;
      '';
      "/".extraConfig = ''
        proxy_pass http://127.0.0.1:3001;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
      '';
    };
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/onyx 0750 root root -"
    "d /var/lib/onyx/postgres 0750 root root -"
    "d /var/lib/onyx/opensearch 0750 root root -"
    "d /var/lib/onyx/model-cache-inference 0750 root root -"
    "d /var/lib/onyx/model-cache-indexing 0750 root root -"
    "d /var/lib/onyx/api-logs 0750 root root -"
    "d /var/lib/onyx/bg-logs 0750 root root -"
  ];
}
