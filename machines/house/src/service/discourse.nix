{ config, lib, ... }:
let
  ids = config.homelab.identifiers;
  domain = ids.mural.root;
  hostname = "${ids.mural.subdomains.foro}.${domain}";
  acmeFqdn = "${ids.subdomains.acmechallenge}.${ids.domain.root}";
in
{
  services.discourse = {
    enable = true;
    hostname = hostname;

    sslCertificate = "/var/lib/acme/${domain}/fullchain.pem";
    sslCertificateKey = "/var/lib/acme/${domain}/key.pem";
    enableACME = false;

    database.ignorePostgresqlVersion = true;

    admin = {
      email = ids.admin.email;
      username = "jose";
      fullName = "Jose";
      passwordFile = config.sops.secrets.discourse_admin_password.path;
    };

    secretKeyBaseFile = config.sops.secrets.discourse_secret_key_base.path;

    siteSettings = {
      required.title = "clm-foro";
      login = {
        enable_local_logins = false;
        enable_local_logins_via_email = false;
        auth_skip_create_confirm = true;
        auth_overrides_email = true;
      };
    };
  };

  # Let ACME HTTP challenge hit the acmechallenge vhost before the discourse redirect.
  services.nginx.virtualHosts.${acmeFqdn}.serverAliases = lib.mkAfter [ hostname ];
}
