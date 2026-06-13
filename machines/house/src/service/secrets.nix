{ config, ... }:
let
  ids = config.homelab.identifiers;
  rootDomain = ids.domain.root;
  sub = ids.subdomains;
  fqdn = name: "${name}.${rootDomain}";
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

  # Disabled alongside mc-discord service (see config.nix). Uncomment when re-enabling.
  # sops.secrets.discord_token.owner = "mc-discord";
  # sops.secrets.instance_id.owner = "mc-discord";

  sops.secrets.outline_oidc_secret = {
    owner = "outline";
    group = "outline";
    restartUnits = [ "outline.service" ];
  };

  sops.secrets.keycloak_admin_password = {
    restartUnits = [ "keycloak.service" ];
  };

  sops.secrets.keycloak_db_password = {
    restartUnits = [ "keycloak.service" ];
  };

  sops.secrets.discourse_secret_key_base = {
    owner = "discourse";
  };
  sops.secrets.discourse_admin_password = {
    owner = "discourse";
  };

  # Deregistered 2026-05-29: librechat + mongo removed
  # sops.secrets.librechat_creds_key = {};
  # sops.secrets.librechat_creds_iv = {};
  # sops.secrets.librechat_jwt_secret = {};
  # sops.secrets.librechat_jwt_refresh_secret = {};
  # sops.secrets.librechat_oidc_secret = {};
  # sops.secrets.librechat_session_secret = {};

  # # API keys for LibreChat endpoints
  # sops.secrets.moonshot_api_key = {};
  # sops.secrets.deepseek_api_key = {};
  # sops.secrets.exa_api_key = {};
  # sops.secrets.brave_api_key = {};

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

  sops.templates.keycloak_admin_env = {
    content = ''
      KC_BOOTSTRAP_ADMIN_USERNAME=admin
      KC_BOOTSTRAP_ADMIN_PASSWORD=${config.sops.placeholder.keycloak_admin_password}
    '';
    mode = "0400";
  };

  # Deregistered 2026-05-29: librechat + mongo removed
  # sops.templates.librechat_env = {
  #   content = ''
  #     CREDS_KEY=${config.sops.placeholder.librechat_creds_key}
  #     CREDS_IV=${config.sops.placeholder.librechat_creds_iv}
  #     JWT_SECRET=${config.sops.placeholder.librechat_jwt_secret}
  #     JWT_REFRESH_SECRET=${config.sops.placeholder.librechat_jwt_refresh_secret}
  #     OPENID_CLIENT_ID=librechat
  #     OPENID_CLIENT_SECRET=${config.sops.placeholder.librechat_oidc_secret}
  #     OPENID_ISSUER=https://${ids.subdomains.auth}.${ids.domain.root}/realms/master
  #     OPENID_SESSION_SECRET=${config.sops.placeholder.librechat_session_secret}
  #     OPENID_SCOPE=openid profile email
  #     OPENID_CALLBACK_URL=/oauth/openid/callback
  #     OPENID_USE_END_SESSION_ENDPOINT=true
  #     MOONSHOT_API_KEY=${config.sops.placeholder.moonshot_api_key}
  #     DEEPSEEK_API_KEY=${config.sops.placeholder.deepseek_api_key}
  #     EXA_API_KEY=${config.sops.placeholder.exa_api_key}
  #     BRAVE_API_KEY=${config.sops.placeholder.brave_api_key}
  #   '';
  #   mode = "0400";
  #   restartUnits = [ "librechat.service" ];
  # };

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

  sops.secrets.deepseek_api_key = {};
  sops.secrets.hermes_matrix_password = {};
  sops.secrets.matrix_oidc_client_secret = {};
  sops.secrets.matrix_registration_secret = {};
  sops.secrets.hermes_matrix_recovery_key = {};
  sops.secrets.hermes_mattermost_token = {};
  sops.secrets.hermes_mattermost_allowed_users = {};
  sops.secrets.mattermost_oidc_secret = {};

  sops.secrets.onyx_user_auth_secret = {};
  sops.secrets.onyx_oidc_client_secret = {};
  sops.secrets.onyx_postgres_password = {};
  sops.secrets.onyx_opensearch_password = {};
  sops.secrets.onyx_encryption_key_secret = {};

  sops.templates."onyx-env" = {
    content = ''
      POSTGRES_PASSWORD=${config.sops.placeholder.onyx_postgres_password}
      OPENSEARCH_INITIAL_ADMIN_PASSWORD=${config.sops.placeholder.onyx_opensearch_password}
      USER_AUTH_SECRET=${config.sops.placeholder.onyx_user_auth_secret}
      OAUTH_CLIENT_SECRET=${config.sops.placeholder.onyx_oidc_client_secret}
      ENCRYPTION_KEY_SECRET=${config.sops.placeholder.onyx_encryption_key_secret}
    '';
    mode = "0400";
  };

  sops.templates."mattermost-oidc-env" = {
    content = ''
      MM_GITLABSETTINGS_SECRET=${config.sops.placeholder.mattermost_oidc_secret}
    '';
    mode = "0400";
  };

  sops.templates."hermes-env" = {
    content = ''
      DEEPSEEK_API_KEY=${config.sops.placeholder.deepseek_api_key}
      MATRIX_HOMESERVER=https://${fqdn sub.matrix}
      MATRIX_USER_ID=@hermes:${rootDomain}
      MATRIX_PASSWORD=${config.sops.placeholder.hermes_matrix_password}
      MATRIX_ALLOWED_USERS=@jose:${rootDomain}
      MATRIX_RECOVERY_KEY=${config.sops.placeholder.hermes_matrix_recovery_key}
      HERMES_STREAM_STALE_TIMEOUT=300
      MATRIX_HOME_ROOM=!UjlQNEMevrUkiPgtzm:${rootDomain}
      MATRIX_ENCRYPTION=true
      MATRIX_DEVICE_ID=HERMES_BOT
      MATTERMOST_URL=https://${fqdn sub.mm}
      MATTERMOST_TOKEN=${config.sops.placeholder.hermes_mattermost_token}
      MATTERMOST_ALLOWED_USERS=${config.sops.placeholder.hermes_mattermost_allowed_users}
    '';
    mode = "0440";
  };

  sops.templates."synapse-extra" = let
    oidcAttributeRequirements = if ids.matrix.requiredGroup != null then ''
          attribute_requirements:
            - attribute: groups
              value: ${ids.matrix.requiredGroup}'' else "";
  in {
    content = ''
      registration_shared_secret: ${config.sops.placeholder.matrix_registration_secret}
      oidc_providers:
        - idp_id: keycloak
          idp_name: Keycloak
          issuer: https://${fqdn sub.auth}/realms/${ids.keycloakRealm}
          client_id: synapse
          client_secret: ${config.sops.placeholder.matrix_oidc_client_secret}
          scopes: ["openid", "profile"]
          user_mapping_provider:
            config:
              localpart_template: "{{ user.preferred_username.split('@')[0] }}"
              display_name_template: "{{ user.name }}"
          backchannel_logout_enabled: true
          # The hermes bot authenticates with a local password (not OIDC).
          # Without this, OIDC and local-password users cannot coexist.
          allow_existing_users: true
      ${oidcAttributeRequirements}'';
    owner = "matrix-synapse";
    mode = "0400";
  };
}
