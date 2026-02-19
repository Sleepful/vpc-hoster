# Part of the media pipeline — see docs/media-pipeline.md
# Movie search and download manager. Finds movies on indexers
# (via Prowlarr) and sends them to qBittorrent for download.
# Runs as the shared media user so it can access download directories.
# First time setup:
# 1. Open http://<builder-ip>:7878
# 2. Settings > Download Clients > Add > qBittorrent
#    Host: localhost, Port: 8080, Category: radarr
# 3. Settings > Media Management > disable "Completed Download Handling"
#    if you want the existing B2 upload pipeline to handle files untouched
# 4. Set a root folder (e.g. /var/lib/qBittorrent/completed/movies)
# 5. Prowlarr will sync indexers automatically once configured there
# 6. Movies > Add New > search for a movie, hit Search
{ ... }:
{
  services.radarr = {
    enable = true;
    user = "media";
    group = "media";
  };

  networking.firewall.allowedTCPPorts = [ 7878 ];
}
