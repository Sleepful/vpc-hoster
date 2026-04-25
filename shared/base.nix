{ lib, pkgs, ... }:
{
  imports =
    [
      ./options/identifiers.nix
      ./identifiers/default.nix
    ]
    ++ lib.optional (builtins.pathExists ../private/identifiers/default.nix)
      ../private/identifiers/default.nix;

  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  nix.settings.auto-optimise-store = true;

  # Weekly garbage collection — delete generations older than 7 days
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 7d";
  };

  # Keep only the last 10 boot generations in the GRUB menu
  boot.loader.grub.configurationLimit = 10;

  services.journald.extraConfig = ''
    SystemMaxUse=300M
  '';

  environment.systemPackages = [
    pkgs.tree
    pkgs.ripgrep
    pkgs.htop
    pkgs.cloud-utils
    pkgs.jq
    pkgs.mosh
    pkgs.git
  ];

  # Mosh uses UDP 60000-61000 for connections
  networking.firewall.allowedUDPPortRanges = [
    { from = 60000; to = 61000; }
  ];

  # Increase file descriptor limits for Nix builds and complex flakes
  security.pam.loginLimits = [
    { domain = "*"; type = "soft"; item = "nofile"; value = "4096"; }
    { domain = "*"; type = "hard"; item = "nofile"; value = "65536"; }
  ];
}
