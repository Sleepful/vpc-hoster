{ pkgs, modulesPath, ... }:
{
  services.journald.extraConfig = ''
    SystemMaxUse=300M
  '';
  environment.systemPackages = [
    pkgs.tree
  ];
}
