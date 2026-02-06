{ ... }:
{
  imports = [
    ./hardware-configuration.nix
    ../../shared/base.nix
    ./src/config.nix
  ];
}
