{ config, pkgs, ... }:
let
  ids = config.homelab.identifiers;
  rootDomain = ids.domain.root;
  sub = ids.subdomains;
  fqdn = name: "${name}.${rootDomain}";

  emailOtpPlugin = pkgs.stdenv.mkDerivation {
    name = "keycloak-email-otp-authenticator";
    version = "1.4.2";
    src = pkgs.fetchurl {
      url = "https://github.com/for-keycloak/email-otp-authenticator/releases/download/v1.4.2/email-otp-authenticator-v1.4.2-kc-26.5.7.jar";
      sha256 = "09qpvkipy0984vs74sdppa7y7g4k2yzf8f4alk1ma84sbp6c9swg";
    };
    dontUnpack = true;
    installPhase = ''
      mkdir -p $out
      cp $src $out/email-otp-authenticator.jar
    '';
  };
in
{
  services.keycloak = {
    enable = true;
    plugins = [ emailOtpPlugin ];
    database = {
      createLocally = true;
      host = "localhost";
      passwordFile = config.sops.secrets.keycloak_db_password.path;
    };
    settings = {
      http-host = "127.0.0.1";
      http-port = 8081;
      http-enabled = true;
      proxy-headers = "xforwarded";
      hostname = fqdn sub.auth;
      hostname-backchannel-dynamic = false;
    };
  };

  # Load admin credentials via EnvironmentFile (systemd reads as root)
  systemd.services.keycloak.serviceConfig.EnvironmentFile =
    config.sops.templates.keycloak_admin_env.path;

  services.nginx.virtualHosts."${fqdn sub.auth}" = {
    onlySSL = true;
    useACMEHost = rootDomain;
    locations."/" = {
      proxyPass = "http://127.0.0.1:8081";
      proxyWebsockets = true;
      extraConfig = ''
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
      '';
    };
  };
}
