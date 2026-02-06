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

  services.journald.extraConfig = ''
    SystemMaxUse=300M
  '';

  environment.systemPackages = [
    pkgs.tree
    pkgs.ripgrep
  ];
}
