{ config, pkgs, ... }:
{
  services.postgresql = {
    enable = true;
    package = pkgs.postgresql_18;

    # Sets C locale cluster-wide. Only takes effect on fresh initdb (empty
    # data directory). Existing databases keep their creation-time locale.
    initdbArgs = ["--locale=C"];

    ensureDatabases = [ "matrix-synapse" ];
    ensureUsers = [
      {
        name = "matrix-synapse";
        ensureDBOwnership = true;
      }
    ];
  };

  environment.systemPackages = [
    pkgs.postgresql_18
  ];
}
