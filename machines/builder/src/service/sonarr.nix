# Part of the media pipeline — see docs/media-pipeline.md
# TV series search and download manager. Finds episodes on indexers
# (via Prowlarr) and sends them to qBittorrent for download.
# Runs as the shared media user so hard links work with qBittorrent.
# First time setup:
# 1. Open http://<builder-ip>:8989
# 2. Settings > Download Clients > Add > qBittorrent
#    Host: localhost, Port: 8080, Category: tv-sonarr
# 3. Set root folder to /media/arr/tv — Sonarr will hard link completed
#    downloads here with clean names. The upload script reads from
#    this directory to upload with nice names to B2.
# 4. Prowlarr will sync indexers automatically once configured there
# 5. Series > Add New > search for a show, select episodes, hit Search
{ ... }:
{
  services.sonarr = {
    enable = true;
    user = "media";
    group = "media";
  };

  networking.firewall.allowedTCPPorts = [ 8989 ];
}
