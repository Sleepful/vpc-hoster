# Part of the media pipeline — see docs/media-pipeline.md
# TV series search and download manager. Finds episodes on indexers
# (via Prowlarr) and sends them to qBittorrent for download.
# Runs as the shared media user so it can access download directories.
# First time setup:
# 1. Open http://<builder-ip>:8989
# 2. Settings > Download Clients > Add > qBittorrent
#    Host: localhost, Port: 8080
# 3. Settings > Media Management > disable "Completed Download Handling"
#    if you want the existing B2 upload pipeline to handle files untouched
# 4. Set a root folder (required by Sonarr, e.g. /var/lib/qBittorrent/completed)
# 5. Prowlarr will sync indexers automatically once configured there
# 6. Series > Add New > search for a show, select episodes, hit Search
{ ... }:
{
  services.sonarr = {
    enable = true;
    user = "media";
    group = "media";
  };

  networking.firewall.allowedTCPPorts = [ 8989 ];
}
