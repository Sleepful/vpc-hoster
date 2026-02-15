{ pkgs, ... }:
{
  # First time setup:
  # 1. Find builder's LAN IP: 
  #          ssh builder 'ip -4 addr show' 
  #    and look for the
  #    inet address on the LAN interface (e.g., ens18 or eth0). Alternatively
  #    check the Proxmox UI or the router's DHCP lease table.
  # 2. Open http://<builder-ip>:8096 from any LAN or Tailscale client
  #    (or use an SSH tunnel: ssh -L 8096:localhost:8096 builder, then
  #    open http://localhost:8096)
  # 3. Walk through the Jellyfin setup wizard (language, create admin account).
  #    The admin password can only be set through this UI — Jellyfin has no
  #    declarative config for credentials.
  # 4. Add media libraries pointing at /media (or subdirs like /media/movies,
  #    /media/tv, /media/music)
  # 5. Jellyfin will scan the directories and index any media files synced
  #    by Syncthing (see syncthing.nix)

  services.jellyfin = {
    enable = true;
    user = "media";
    group = "media";
  };

  users.users.media = {
    isSystemUser = true;
    group = "media";
    home = "/media";
    createHome = true;
  };

  users.groups.media = { };

  # Jellyfin web UI accessible on LAN and Tailscale
  networking.firewall.allowedTCPPorts = [ 8096 ];
}
