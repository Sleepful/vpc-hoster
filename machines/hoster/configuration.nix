{ config, pkgs, ... }:

{
  imports = [ 
    ../../shared/base.nix
    ./src/config.nix
  ];
}
