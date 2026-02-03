{
  description = "Homelab NixOS infrastructure";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
  };

  outputs = { self, nixpkgs, ... }: {
    nixosConfigurations = {
      builder = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          ./machines/builder/configuration.nix
        ];
      };
      hoster = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          "${nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-minimal-combined.nix"
          ./machines/hoster/configuration.nix
        ];
      };
    };
  };
}
