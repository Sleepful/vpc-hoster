{ config, pkgs, ... }:

{
  imports = [ 
    <nixpkgs/nixos/modules/installer/cd-dvd/installation-cd-minimal-combined.nix>
    ./src/config.nix
  ];
}
