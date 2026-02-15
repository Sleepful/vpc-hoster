{ config, ... }:
{
  sops.defaultSopsFile = ../../../../secrets/builder/core.yaml;
  sops.defaultSopsFormat = "yaml";

  sops.age.sshKeyPaths = [
    "/etc/ssh/ssh_host_ed25519_key"
  ];

  sops.secrets.b2_account_id = {};
  sops.secrets.b2_application_key = {};

  # Copyparty admin password
  sops.secrets.copyparty_password = {
    owner = "media";
  };

  # rclone B2 credentials as environment variables.
  # rclone reads RCLONE_CONFIG_<remote>_<key> to build remotes on the fly
  # without a config file.
  sops.templates.rclone_b2_env = {
    content = ''
      RCLONE_CONFIG_B2_TYPE=b2
      RCLONE_CONFIG_B2_ACCOUNT=${config.sops.placeholder.b2_account_id}
      RCLONE_CONFIG_B2_KEY=${config.sops.placeholder.b2_application_key}
    '';
    mode = "0440";
  };
}
