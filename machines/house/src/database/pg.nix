{ config, pkgs, ... }:
{
  services.postgresql = {
    enable = true;
    package = pkgs.postgresql_18;
  };

  environment.systemPackages = [
    pkgs.postgresql_18
  ];
}
