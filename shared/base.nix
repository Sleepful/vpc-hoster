{ pkgs, ... }:
{
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  services.journald.extraConfig = ''
    SystemMaxUse=300M
  '';

  environment.systemPackages = [
    pkgs.tree
  ];
}
