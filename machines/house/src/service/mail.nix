{ config, lib, pkgs, ... }:
let
  ids = config.homelab.identifiers;
  rootDomain = ids.domain.root;
  sub = ids.subdomains;
  mail = ids.mail;
  fqdn = name: "${name}.${rootDomain}";
  escapedDomain = builtins.replaceStrings [ "." ] [ "\\." ] rootDomain;

  mailLoginAccounts = {
    "${mail.contactAddress}" = {
      hashedPasswordFile = config.sops.secrets.mail_hash_contact.path;
      aliases = [
        mail.postmasterAddress
        mail.catchAllDomain
      ];
      aliasesRegexp = [
        "/^serv\\..*@${escapedDomain}$/"
        "/^buy\\..*@${escapedDomain}$/"
        "/^balance\\..*@${escapedDomain}$/"
        "/^freelance\\..*@${escapedDomain}$/"
        "/^comunicacion\\..*@${escapedDomain}$/"
        "/^calendario\\..*@${escapedDomain}$/"
        "/^reuniones\\..*@${escapedDomain}$/"
        "/^host\\..*@${escapedDomain}$/"
      ];
    };
    "${mail.outlineNoReplyAddress}" = {
      hashedPasswordFile = config.sops.secrets.mail_hash_outline_noreply.path;
      sendOnly = true;
    };
    "${mail.familyAddress}" = {
      hashedPasswordFile = config.sops.secrets.mail_hash_family.path;
      sendOnly = true;
    };
    "${mail.sharedAddress}" = {
      hashedPasswordFile = config.sops.secrets.mail_hash_shared.path;
    };
  };

in
{
  imports = [
    (builtins.fetchTarball {
      url = "https://gitlab.com/simple-nixos-mailserver/nixos-mailserver/-/archive/nixos-25.05/nixos-mailserver-nixos-25.05.tar.gz";
      sha256 = "0la8v8d9vzhwrnxmmyz3xnb6vm76kihccjyidhfg6qfi3143fiwq";
    })
  ];

  mailserver = {
    enable = true;
    fqdn = fqdn sub.mail;
    domains = [ rootDomain ];
    loginAccounts = mailLoginAccounts;
    certificateScheme = "acme";
    enableManageSieve = true;
  };

  services.dovecot2.sieve.extensions = [
    "fileinto"
    "editheader"
  ];

  services.postfix.config = {
    # Outbound relay via Mailtrap Email Sending.
    # Mailtrap requires TLS; use STARTTLS on 587.
    relayhost = "[live.smtp.mailtrap.io]:587";
    smtp_sasl_password_maps = "hash:/etc/postfix/sasl_passwd";
    smtp_sasl_auth_enable = "yes";
    smtp_sasl_security_options = "noanonymous";
    smtp_tls_security_level = lib.mkForce "encrypt";
    smtp_tls_note_starttls_offer = "yes";
    smtp_tls_loglevel = "1";
  };

  systemd.services.postfix.preStart = ''
    user=$(cat "${config.sops.secrets.smtp_username.path}")
    pass=$(cat "${config.sops.secrets.smtp_password.path}")
    echo "[live.smtp.mailtrap.io]:587 ''${user}:''${pass}" > /etc/postfix/sasl_passwd
    chown postfix:postfix /etc/postfix
    chown postfix:postfix /etc/postfix/sasl_passwd
    ${pkgs.postfix}/sbin/postmap hash:/etc/postfix/sasl_passwd
  '';

  services.roundcube = {
    enable = true;
    hostName = fqdn sub.mail;
    extraConfig = ''
      $config['smtp_host'] = "tls://${config.mailserver.fqdn}";
      $config['smtp_user'] = "%u";
      $config['smtp_pass'] = "%p";
    '';
    plugins = [
      "archive"
      "managesieve"
      "contextmenu"
      "custom_from"
      "persistent_login"
    ];
    package = pkgs.roundcube.withPlugins (
      plugins: [
        plugins.contextmenu
        plugins.custom_from
        plugins.persistent_login
      ]
    );
  };

  services.radicale = {
    enable = true;
    settings.auth = {
      type = "htpasswd";
      htpasswd_filename = config.sops.templates.radicale_users.path;
      htpasswd_encryption = "bcrypt";
    };
  };

  services.nginx.virtualHosts."${fqdn sub.mail}" = {
    useACMEHost = fqdn sub.mail;
    onlySSL = true;
    forceSSL = false;
    enableACME = lib.mkForce false;
    serverAliases = [ (fqdn sub.email) ];
  };

  services.nginx.virtualHosts."${fqdn sub.cal}" = {
    onlySSL = true;
    useACMEHost = fqdn sub.mail;
    locations."/" = {
      proxyPass = "http://localhost:5232/";
      extraConfig = ''
        proxy_set_header  X-Script-Name /;
        proxy_set_header  X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_pass_header Authorization;
      '';
    };
  };
}
