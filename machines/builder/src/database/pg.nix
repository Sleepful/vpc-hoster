# https://nixos.org/manual/nixos/stable/#module-postgresql
# https://wiki.nixos.org/wiki/PostgreSQL
{ config, pkgs, ... }:
{ 

  services.postgresql.ensureUsers.*.ensureDBOwnership = true;


  services.postgresql.enable = true;
  services.postgresql.package = pkgs.postgresql_18;
  services.postgresql.dataDir = "/data/postgresql";
  environment.systemPackages = [
    pkgs.postgresql_18
  ];
}
