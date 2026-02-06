{ config, pkgs, ... }:
{
  environment.systemPackages = [ pkgs.awscli2 ];

  users.groups.awscli.members = [
    config.homelab.identifiers.users.deployUser
    "mc-discord"
  ];

  environment.variables.AWS_SHARED_CREDENTIALS_FILE = config.sops.templates.aws_cli_creds.path;
}
