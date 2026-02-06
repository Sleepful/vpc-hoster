{ config, pkgs, ... }:
let
  ids = config.homelab.identifiers;
  rootDomain = ids.domain.root;
  sub = ids.subdomains;
  deployUser = ids.users.deployUser;
  homeDir = "/home/${deployUser}";
  syncthingDevices = ids.syncthing.devices;
  syncthingDeviceNames = builtins.attrNames syncthingDevices;
  fqdn = name: "${name}.${rootDomain}";
in
{
  services.syncthing = {
    enable = true;
    user = deployUser;
    dataDir = "${homeDir}/Documents";
    configDir = "${homeDir}/Documents/.config/syncthing";
    guiAddress = "localhost:8384";
    overrideDevices = true;
    overrideFolders = true;

    settings.gui = {
      user = deployUser;
      # this is necessary to allow nginx reverse proxy
      #   https://docs.syncthing.net/users/faq.html#why-do-i-get-host-check-error-in-the-gui-api
      #   https://github.com/syncthing/docs/issues/401 
      insecureSkipHostcheck = true;
    };

    settings.devices = syncthingDevices;

    settings.folders.Default = {
      path = "${homeDir}/Sync";
      devices = syncthingDeviceNames;
    };
  };

  services.nginx.virtualHosts."${fqdn sub.sync}" = {
    onlySSL = true;
    useACMEHost = rootDomain;
    locations."/" = {
      proxyPass = "http://localhost:8384";
      proxyWebsockets = true;
    };
  };

  # Syncthing's NixOS module currently has no guiPasswordFile option.
  # We keep the GUI password in SOPS and apply it at runtime through the
  # Syncthing REST API after config.xml is initialized.
  #
  # Why this service exists:
  # - keeps plaintext password out of git and the Nix store
  # - avoids storing a public bcrypt hash in repo history
  # - remains declarative because the source of truth is sops secret data
  #
  # Operational usage:
  # - runs on each switch/boot (oneshot)
  # - reads API key from Syncthing's generated config.xml
  # - writes the GUI password via /rest/config/gui
  # - restarts Syncthing only when /rest/config/restart-required says so
  systemd.services.syncthing-gui-password = {
    description = "Sync Syncthing GUI password from SOPS secret";
    after = [
      "network-online.target"
      "sops-install-secrets.service"
      "syncthing.service"
      "syncthing-init.service"
    ];
    wants = [
      "network-online.target"
      "sops-install-secrets.service"
      "syncthing.service"
      "syncthing-init.service"
    ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "oneshot";
      User = deployUser;
    };

    script = ''
      set -eu

      # Runtime-generated Syncthing config (contains API key)
      cfg="${config.services.syncthing.configDir}/config.xml"
      # Decrypted by sops-nix during activation; never evaluated into store
      secret_file="${config.sops.secrets.syncthing_password.path}"
      base_url="http://${config.services.syncthing.guiAddress}"

      # Wait for first Syncthing start to generate config.xml
      while [ ! -f "$cfg" ]; do
        sleep 1
      done

      # GUI endpoint auth uses API key, not the GUI password itself
      api_key="$(${pkgs.libxml2}/bin/xmllint --xpath 'string(configuration/gui/apikey)' "$cfg")"
      password="$(${pkgs.coreutils}/bin/cat "$secret_file")"

      # Merge only the password field while preserving all other GUI settings
      ${pkgs.curl}/bin/curl -fsSL \
        -H "X-API-Key: $api_key" \
        "$base_url/rest/config/gui" \
      | ${pkgs.jq}/bin/jq --arg password "$password" '.password = $password' \
      | ${pkgs.curl}/bin/curl -fsSL \
        -H "X-API-Key: $api_key" \
        -H "Content-Type: application/json" \
        -X PUT \
        --data-binary @- \
        "$base_url/rest/config/gui"

      # Restart only when Syncthing reports it is required
      if ${pkgs.curl}/bin/curl -fsSL \
        -H "X-API-Key: $api_key" \
        "$base_url/rest/config/restart-required" \
        | ${pkgs.jq}/bin/jq -e '.requiresRestart' >/dev/null; then
        ${pkgs.curl}/bin/curl -fsSL \
          -H "X-API-Key: $api_key" \
          -X POST \
          "$base_url/rest/system/restart"
      fi
    '';
  };
}
