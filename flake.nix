{
  description = "Homelab NixOS infrastructure";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, sops-nix, ... }: {
    nixosConfigurations = {
      builder = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          ./machines/builder/configuration.nix
        ];
      };
      house = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          sops-nix.nixosModules.sops
          ./machines/house/configuration.nix
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
