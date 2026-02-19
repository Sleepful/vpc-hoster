# Part of the media pipeline — see docs/media-pipeline.md
# Subtitle manager for Sonarr and Radarr. Automatically searches for
# and downloads subtitles for TV shows and movies.
# Runs as the shared media user so it can read media files.
# First time setup:
# 1. Open http://<builder-ip>:6767
# 2. Settings > Languages > select desired subtitle languages
# 3. Settings > Providers > enable subtitle providers (e.g., OpenSubtitles)
# 4. Settings > Sonarr > Host: localhost, Port: 8989,
#    API Key: (from Sonarr Settings > General)
# 5. Settings > Radarr > Host: localhost, Port: 7878,
#    API Key: (from Radarr Settings > General)
# 6. Bazarr will sync your library from Sonarr/Radarr and begin
#    searching for missing subtitles
{ ... }:
{
  services.bazarr = {
    enable = true;
    user = "media";
    group = "media";
  };

  networking.firewall.allowedTCPPorts = [ 6767 ];
}
