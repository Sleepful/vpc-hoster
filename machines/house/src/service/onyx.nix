{ config, pkgs, lib, ... }:
let
  ids = config.homelab.identifiers;
  rootDomain = ids.domain.root;
  sub = ids.subdomains;
  fqdn = name: "${name}.${rootDomain}";
in
{
  systemd.services."onyx-network" = {
    description = "Docker network for Onyx containers";
    wantedBy = [ "multi-user.target" ];
    before = [
      "docker-onyx-db.service"
      "docker-onyx-redis.service"
      "docker-onyx-opensearch.service"
      "docker-onyx-model.service"
      "docker-onyx-indexing-model.service"
      "docker-onyx-api.service"
      "docker-onyx-web.service"
      "docker-onyx-background.service"
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      ${pkgs.docker}/bin/docker network inspect onyx >/dev/null 2>&1 \
        || ${pkgs.docker}/bin/docker network create onyx
    '';
  };

  virtualisation.oci-containers.containers = {
    onyx-db = {
      image = "docker.io/library/postgres:15.2-alpine";
      autoStart = true;
      environment = {
        POSTGRES_USER = "postgres";
      };
      environmentFiles = [ config.sops.templates."onyx-env".path ];
      cmd = [ "-c" "max_connections=250" ];
      extraOptions = [ "--shm-size=1g" "--network=onyx" ];
      volumes = [ "/var/lib/onyx/postgres:/var/lib/postgresql/data" ];
    };

    onyx-redis = {
      image = "docker.io/library/redis:7.4-alpine";
      autoStart = true;
      cmd = [ "redis-server" "--save" "" "--appendonly" "no" ];
      extraOptions = [ "--network=onyx" ];
    };

    onyx-opensearch = {
      image = "docker.io/opensearchproject/opensearch:3.6.0";
      autoStart = true;
      environment = {
        "discovery.type" = "single-node";
        "bootstrap.memory_lock" = "true";
        "OPENSEARCH_JAVA_OPTS" = "-Xms2g -Xmx2g";
        "DISABLE_SECURITY_PLUGIN" = "true";
      };
      environmentFiles = [ config.sops.templates."onyx-env".path ];
      extraOptions = [
        "--network=onyx"
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
      extraOptions = [ "--network=onyx" ];
      volumes = [ "/var/lib/onyx/model-cache-inference:/app/.cache/huggingface" ];
    };

    onyx-indexing-model = {
      image = "docker.io/onyxdotapp/onyx-model-server:latest";
      autoStart = true;
      environment = {
        INDEXING_ONLY = "True";
      };
      cmd = [ "uvicorn" "model_server.main:app" "--host" "0.0.0.0" "--port" "9000" ];
      extraOptions = [ "--network=onyx" ];
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
        WEB_DOMAIN = "https://${fqdn sub.chat}";
        POSTGRES_HOST = "onyx-db";
        REDIS_HOST = "onyx-redis";
        OPENSEARCH_HOST = "onyx-opensearch";
        OPENSEARCH_USE_SSL = "false";
        MODEL_SERVER_HOST = "onyx-model";
        INDEXING_MODEL_SERVER_HOST = "onyx-indexing-model";
        FILE_STORE_BACKEND = "postgres";
        DISABLE_TELEMETRY = "true";
      };
      environmentFiles = [ config.sops.templates."onyx-env".path ];
      extraOptions = [ "--network=onyx" ];
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
        WEB_DOMAIN = "https://${fqdn sub.chat}";
      };
      extraOptions = [ "--network=onyx" ];
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
        OPENSEARCH_USE_SSL = "false";
        MODEL_SERVER_HOST = "onyx-model";
        INDEXING_MODEL_SERVER_HOST = "onyx-indexing-model";
        FILE_STORE_BACKEND = "postgres";
        DISABLE_TELEMETRY = "true";
      };
      environmentFiles = [ config.sops.templates."onyx-env".path ];
      extraOptions = [ "--network=onyx" ];
      cmd = [
        "/bin/sh"
        "-c"
        "if [ -f /etc/ssl/certs/custom-ca.crt ]; then update-ca-certificates; fi && /app/scripts/supervisord_entrypoint.sh"
      ];
      volumes = [ "/var/lib/onyx/bg-logs:/var/log/onyx" ];
    };
  };

  services.nginx.appendHttpConfig = ''
    map $http_upgrade $connection_upgrade {
      default upgrade;
      ""      close;
    }
  '';

  services.nginx.virtualHosts."${fqdn sub.chat}" = {
    onlySSL = true;
    useACMEHost = rootDomain;
    extraConfig = ''
      client_max_body_size 5G;
      proxy_read_timeout 300s;
      proxy_send_timeout 300s;
      proxy_connect_timeout 300s;
      proxy_set_header X-Real-IP $remote_addr;
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto $scheme;
      proxy_set_header X-Forwarded-Host $host;
      proxy_set_header X-Forwarded-Port $server_port;
    '';
    locations = {
      "~ ^/(api|openapi.json)(/.*)?$".extraConfig = ''
        rewrite ^/api(/.*)$ $1 break;
        proxy_set_header Host $host;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_http_version 1.1;
        proxy_buffering off;
        proxy_redirect off;
        proxy_pass http://127.0.0.1:8080;
      '';
      "/".extraConfig = ''
        proxy_set_header Host $host;
        proxy_http_version 1.1;
        proxy_redirect off;
        proxy_pass http://127.0.0.1:3001;
      '';
    };
  };

  # Bind-mount host directories. Ownership must match the uid/gid inside
  # each container, otherwise the container process gets Permission denied.
  # Verified via: docker run --rm --entrypoint id <image>
  #   postgres:15.2-alpine         → uid=70(postgres)  gid=70(postgres)
  #   opensearchproject/opensearch → uid=1000             gid=1000
  systemd.tmpfiles.rules = [
    "d /var/lib/onyx 0750 root root -"
    "d /var/lib/onyx/postgres 0750 70 70 -"
    "d /var/lib/onyx/opensearch 0770 1000 1000 -"
    "d /var/lib/onyx/model-cache-inference 0750 root root -"
    "d /var/lib/onyx/model-cache-indexing 0750 root root -"
    "d /var/lib/onyx/api-logs 0750 root root -"
    "d /var/lib/onyx/bg-logs 0750 root root -"
  ];
}
