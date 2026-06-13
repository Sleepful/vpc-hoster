{ pkgs, lib, ... }:
{
  system.stateVersion = "25.05";
  networking.hostName = "nixos-house";

  nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [ "outline" ];

  boot.loader.grub = {
    enable = true;
    device = "/dev/sda";
  };

  environment.systemPackages = [
    pkgs.vim
    pkgs.htop
    pkgs.netcat
    pkgs.cacert
    pkgs.cloud-utils
  ];

  services.fail2ban.enable = true;
  security.sudo.wheelNeedsPassword = false;
  nix.settings.trusted-users = [ "@wheel" ];

  imports = [
    ./database/pg.nix
    ./service/ssh.nix
    ./service/secrets.nix
    ./service/tailnet.nix
    ./service/web.nix
    ./service/frp.nix
    ./service/miniflux.nix
    ./service/syncthing.nix
    ./service/mail.nix
    ./service/keycloak.nix
    ./service/outline.nix
    ./service/docker.nix
    ./service/discourse.nix
    # ./service/librechat.nix  # Deregistered 2026-05-29: librechat + mongo removed
    ./service/monitoring.nix
    ./service/aws.nix
    # ./service/mc-discord.nix  # Disabled 2025-05-29: Rust compilation slow, crates.io 403 on vendoring.
    #                             # Future fix: build Docker image via GitHub Actions to avoid Nix compilation.
    ./service/synapse.nix
    ./service/hermes.nix
    ./service/mattermost.nix
    ./service/firewall.nix
    ./service/onyx.nix
  ];
}
