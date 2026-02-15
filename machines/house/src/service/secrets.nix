{ config, ... }:
let
  ids = config.homelab.identifiers;
in
{
  sops.defaultSopsFile = ../../../../secrets/house/core.yaml;
  sops.defaultSopsFormat = "yaml";

  sops.age.sshKeyPaths = [
    "/etc/ssh/ssh_host_ed25519_key"
  ];

  sops.secrets.syncthing_password.owner = ids.users.deployUser;

  sops.secrets.smtp_username = {
    restartUnits = [ "postfix.service" ];
  };
  sops.secrets.smtp_password = {
    restartUnits = [ "postfix.service" "outline.service" ];
  };

  sops.secrets.miniflux_password = {};

  sops.secrets.aws_cli_user = {};
  sops.secrets.aws_cli_pass = {};

  sops.secrets.discord_token.owner = "mc-discord";
  sops.secrets.instance_id.owner = "mc-discord";

  sops.secrets.outline_oidc_secret_for_dex = {
    key = "outline_oidc_secret";
    owner = "dex";
    restartUnits = [ "dex.service" ];
  };
  sops.secrets.outline_oidc_secret_for_outline = {
    key = "outline_oidc_secret";
    owner = "outline";
    restartUnits = [ "outline.service" ];
  };

  # Dovecot reads hashes via /run/dovecot2/passwd generated at dovecot start.
  # Restart dovecot automatically when hashes change.
  sops.secrets.mail_hash_contact = {
    restartUnits = [ "dovecot2.service" ];
  };
  sops.secrets.mail_hash_outline_noreply = {
    restartUnits = [ "dovecot2.service" ];
  };
  sops.secrets.mail_hash_family = {
    restartUnits = [ "dovecot2.service" ];
  };
  sops.secrets.mail_hash_shared = {
    restartUnits = [ "dovecot2.service" ];
  };

  sops.secrets.dex_hash_super = {
    owner = "dex";
    restartUnits = [ "dex.service" ];
  };
  sops.secrets.dex_hash_atlas = {
    owner = "dex";
    restartUnits = [ "dex.service" ];
  };
  sops.secrets.dex_hash_lumen = {
    owner = "dex";
    restartUnits = [ "dex.service" ];
  };

  sops.templates.miniflux_creds = {
    content = ''
      ADMIN_USERNAME=${ids.users.deployUser}
      ADMIN_PASSWORD=${config.sops.placeholder.miniflux_password}
    '';
    mode = "0440";
  };

  sops.templates.aws_cli_creds = {
    content = ''
      [default]
      region = us-east-1
      aws_access_key_id = ${config.sops.placeholder.aws_cli_user}
      aws_secret_access_key = ${config.sops.placeholder.aws_cli_pass}
    '';
    mode = "0440";
  };

  sops.templates.outline_smtp_password = {
    content = ''
      ${config.sops.placeholder.smtp_password}
    '';
    owner = "outline";
    mode = "0400";
  };

  sops.templates.dex_env = {
    content = ''
      DEX_HASH_SUPER=\${config.sops.placeholder.dex_hash_super}
      DEX_HASH_ATLAS=\${config.sops.placeholder.dex_hash_atlas}
      DEX_HASH_LUMEN=\${config.sops.placeholder.dex_hash_lumen}
    '';
    owner = "dex";
    mode = "0400";
  };

  sops.templates.radicale_users = {
    content = ''
      ${ids.mail.contactAddress}:${config.sops.placeholder.mail_hash_contact}
      ${ids.mail.outlineNoReplyAddress}:${config.sops.placeholder.mail_hash_outline_noreply}
      ${ids.mail.familyAddress}:${config.sops.placeholder.mail_hash_family}
      ${ids.mail.sharedAddress}:${config.sops.placeholder.mail_hash_shared}
    '';
    owner = "radicale";
    mode = "0400";
  };

  # B2 credentials for qBittorrent on-complete upload script
  sops.secrets.b2_account_id = {};
  sops.secrets.b2_application_key = {};

  sops.templates.rclone_b2_env = {
    content = ''
      RCLONE_CONFIG_B2_TYPE=b2
      RCLONE_CONFIG_B2_ACCOUNT=${config.sops.placeholder.b2_account_id}
      RCLONE_CONFIG_B2_KEY=${config.sops.placeholder.b2_application_key}
    '';
    mode = "0440";
  };
}
