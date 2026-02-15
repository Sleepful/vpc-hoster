{ config, pkgs, ... }:
let
  ids = config.homelab.identifiers;
  # On-complete script: upload finished torrent to B2 then delete local copy.
  # qBittorrent passes: %N=name %D=save_path %F=content_path %I=hash
  # The script receives %F (full path to downloaded content) as $1.
  uploadScript = pkgs.writeShellScript "qbt-upload-b2" ''
    CONTENT_PATH="$1"
    SAVE_PATH="$2"

    if [ ! -e "$CONTENT_PATH" ]; then
      echo "Content path does not exist: $CONTENT_PATH"
      exit 1
    fi

    # Load rclone B2 credentials
    set -a
    . ${config.sops.templates.rclone_b2_env.path}
    set +a

    # Upload to B2 downloads/ staging folder
    if [ -d "$CONTENT_PATH" ]; then
      ${pkgs.rclone}/bin/rclone copy "$CONTENT_PATH" "b2:entertainment-netmount/downloads/$(${pkgs.coreutils}/bin/basename "$CONTENT_PATH")" --transfers 4
    else
      ${pkgs.rclone}/bin/rclone copy "$CONTENT_PATH" "b2:entertainment-netmount/downloads/" --transfers 4
    fi

    # Delete local file after successful upload
    if [ $? -eq 0 ]; then
      ${pkgs.coreutils}/bin/rm -rf "$CONTENT_PATH"
      echo "Uploaded and cleaned: $CONTENT_PATH"
    else
      echo "Upload failed, keeping local: $CONTENT_PATH"
      exit 1
    fi
  '';
in
{
  services.qbittorrent = {
    enable = true;
    webuiPort = 8080;
    torrentingPort = 6881;

    serverConfig = {
      LegalNotice.Accepted = true;

      Preferences."WebUI\\Password_PBKDF2" = ids.qbittorrent.passwordHash;

      BitTorrent.Session = {
        DefaultSavePath = "/var/lib/qBittorrent/downloads";
      };

      # Auto-upload completed downloads to B2
      AutoRun = {
        enabled = true;
        # %F = content path (file or directory), %D = save path
        program = "${uploadScript} \"%F\" \"%D\"";
      };
    };
  };

  # Ensure the downloads directory exists with correct ownership
  systemd.tmpfiles.rules = [
    "d /var/lib/qBittorrent/downloads 0755 qbittorrent qbittorrent -"
  ];

  # rclone is needed by the upload script
  environment.systemPackages = [ pkgs.rclone ];

  # Allow the qbittorrent user to read the SOPS-rendered rclone env file
  sops.templates.rclone_b2_env.group = "qbittorrent";
}
