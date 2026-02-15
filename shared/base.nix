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

  services.journald.extraConfig = ''
    SystemMaxUse=300M
  '';

  environment.systemPackages = [
    pkgs.tree
    pkgs.ripgrep
    pkgs.htop
    pkgs.cloud-utils
  ];
}
