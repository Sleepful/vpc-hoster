{
  description = "Homelab NixOS infrastructure";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    hermes-agent.url = "github:NousResearch/hermes-agent";
  };

  outputs = { self, nixpkgs, sops-nix, hermes-agent, ... }: {
    nixosConfigurations = {
      builder = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          sops-nix.nixosModules.sops
          ./machines/builder/configuration.nix
        ];
      };
      house = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          sops-nix.nixosModules.sops
          hermes-agent.nixosModules.default
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
