# First time setup:
#
# If your Mac's device ID is already in homelab.identifiers.syncthing.devices,
# builder's Syncthing will automatically request a connection to your Mac.
# 1. Open Syncthing on your Mac — a "New Device" request from builder
#    should already be waiting. Accept it.
# 2. Share your media folder with builder — files will sync to /media.
# 3. Files synced here are served by Jellyfin (see jellyfin.nix).
#
# Alternative (manual pairing):
# 1. SSH tunnel to builder: ssh -L 8384:localhost:8384 builder
# 2. Open http://localhost:8384 in your browser
# 3. Add builder's device ID on your Mac's Syncthing (or vice versa)
# 4. Share your media folder with builder — files will sync to /media.
# 5. Files synced here are served by Jellyfin (see jellyfin.nix).

{ config, ... }:
let
  ids = config.homelab.identifiers;
  syncthingDevices = ids.syncthing.devices;
  syncthingDeviceNames = builtins.attrNames syncthingDevices;
in
{
  # Syncthing web UI accessible on LAN and Tailscale
  networking.firewall.allowedTCPPorts = [ 8384 ];

  services.syncthing = {
    enable = true;
    user = "media";
    group = "media";
    dataDir = "/media/st/data";
    configDir = "/media/st/.config";
    # Bound to all interfaces so the nginx redirect from /syncthing/ works.
    # Access is restricted by the firewall — only Tailscale (trustedInterfaces)
    # and LAN port 8384 are allowed.
    guiAddress = "0.0.0.0:8384";
    overrideDevices = true;
    overrideFolders = true;

    settings.devices = syncthingDevices;

    settings.folders.Media = {
      path = "/media/st/data";
      devices = syncthingDeviceNames;
    };
  };
}
