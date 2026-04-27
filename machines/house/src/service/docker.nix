{ config, lib, ... }:
let
  ids = config.homelab.identifiers;
in
{
  virtualisation.oci-containers.backend = "docker";

  # MongoDB for LibreChat (Docker avoids SSPL source compilation)
  virtualisation.oci-containers.containers.mongodb = {
    image = "mongo:7";
    autoStart = true;
    ports = [ "127.0.0.1:27017:27017" ];
    volumes = [ "/var/lib/mongodb:/data/db" ];
    environment = {
      MONGO_INITDB_DATABASE = "librechat";
    };
    extraOptions = [ "--user=999:999" ];
  };

  # Local Docker registry for custom app images
  # Push from macOS via SSH tunnel:
  #   ssh -L 5000:localhost:5000 house
  #   docker tag myapp localhost:5000/myapp
  #   docker push localhost:5000/myapp
  virtualisation.oci-containers.containers.registry = {
    image = "registry:2";
    autoStart = true;
    ports = [ "127.0.0.1:5000:5000" ];
    volumes = [ "/var/lib/registry:/var/lib/registry" ];
  };

  users.users.mongodb = {
    uid = 999;
    isSystemUser = true;
    group = "mongodb";
  };
  users.groups.mongodb.gid = 999;

  systemd.tmpfiles.rules = [
    "d /var/lib/mongodb 0755 mongodb mongodb -"
    "d /var/lib/registry 0755 root root -"
  ];
}
