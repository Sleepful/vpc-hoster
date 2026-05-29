/*
  Service disabled 2025-05-29 — two issues:
  1. crates.io returns 403 on cargo vendor dependency downloads (addr2line 0.21.0).
     Likely a rate-limit or API change; the fetch-cargo-vendor-util script in nixpkgs
     may need updating.
  2. Rust compilation on the builder VM is slow (every nixpkgs bump triggers a rebuild
     because cargoHash changes).
  Future fix: build a Docker image via GitHub Actions on push, push to house's local
  registry, and run via oci-containers. This avoids Nix compilation entirely and moves
  the build to CI where it can be cached.
*/
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
