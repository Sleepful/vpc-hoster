{ pkgs, ... }:
{
  system.stateVersion = "25.05";
  networking.hostName = "nixos-house";

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
    ./service/ssh.nix
    ./service/secrets.nix
    ./service/tailnet.nix
    ./service/web.nix
    ./service/frp.nix
    ./service/miniflux.nix
    ./service/syncthing.nix
    ./service/mail.nix
    ./service/outline-dex.nix
    ./service/monitoring.nix
    ./service/aws.nix
    ./service/mc-discord.nix
    ./service/qbittorrent.nix
    ./service/firewall.nix
  ];
}
