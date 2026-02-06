{ config, lib, pkgs, ... }:
let
  mcDiscordPkg = pkgs.callPackage ./mcdiscord/default.nix { };
in
{
  environment.systemPackages = [
    mcDiscordPkg
    pkgs.jq
  ];

  users.users.mc-discord = {
    isSystemUser = true;
    group = "mc-discord";
    extraGroups = [ "awscli" ];
  };
  users.groups.mc-discord = { };

  systemd.services.mc-discord = {
    description = "discord bot for Minecraft-server";
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "simple";
      User = "mc-discord";
    };
    path = [
      pkgs.awscli2
      pkgs.jq
    ];
    script = ''
      AWS_SHARED_CREDENTIALS_FILE="${config.sops.templates.aws_cli_creds.path}" \
      DISCORD_TOKEN="$(cat ${config.sops.secrets.discord_token.path})" \
      INSTANCE_ID="$(cat ${config.sops.secrets.instance_id.path})" \
      ${lib.getExe mcDiscordPkg}
    '';
  };
}
