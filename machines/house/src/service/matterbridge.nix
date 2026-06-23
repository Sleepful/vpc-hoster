{ config, pkgs, ... }:
let
  matterbridge = pkgs.stdenvNoCC.mkDerivation {
    pname = "matterbridge";
    version = "1.26.0";
    src = pkgs.fetchurl {
      url = "https://github.com/42wim/matterbridge/releases/download/v1.26.0/matterbridge-1.26.0-linux-64bit";
      hash = "sha256-f1p0ubfL85W4hz8/P0GNkMYRl+PMZ3iC5wt/ru9MNbA=";
    };
    dontUnpack = true;
    installPhase = ''
      install -Dm755 $src $out/bin/matterbridge
    '';
  };
in
{
  users.users.matterbridge = {
    isSystemUser = true;
    group = "matterbridge";
  };
  users.groups.matterbridge = {};

  systemd.services.matterbridge = {
    description = "Matterbridge (Discord <-> Mattermost)";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      ExecStart = "${matterbridge}/bin/matterbridge -conf ${config.sops.templates.matterbridge_conf.path}";
      Restart = "on-failure";
      RestartSec = 10;
      User = "matterbridge";
      Group = "matterbridge";
      ProtectHome = true;
      PrivateTmp = true;
      NoNewPrivileges = true;
    };
  };
}
