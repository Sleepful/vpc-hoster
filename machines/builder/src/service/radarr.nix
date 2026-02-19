# Part of the media pipeline — see docs/media-pipeline.md
# Movie search and download manager. Finds movies on indexers
# (via Prowlarr) and sends them to qBittorrent for download.
# Runs as the shared media user so hard links work with qBittorrent.
# First time setup:
# 1. Open http://<builder-ip>:7878
# 2. Settings > Download Clients > Add > qBittorrent
#    Host: localhost, Port: 8080, Category: radarr
# 3. Set root folder to /media/arr/movies — Radarr will hard link completed
#    downloads here with clean names. The upload script reads from
#    this directory to upload with nice names to B2.
# 4. Prowlarr will sync indexers automatically once configured there
# 5. Movies > Add New > search for a movie, hit Search
{ ... }:
{
  services.radarr = {
    enable = true;
    user = "media";
    group = "media";
  };

  networking.firewall.allowedTCPPorts = [ 7878 ];
}
