# Part of the media pipeline — see docs/media-pipeline.md
# Indexer manager — configure torrent indexers here once, and Sonarr
# (and any future *arr apps) will use them automatically.
# First time setup:
# 1. Open http://<builder-ip>:9696
# 2. Add your torrent indexer(s) under Indexers > Add Indexer
# 3. Under Settings > Apps, add Sonarr (http://localhost:8989, grab the
#    API key from Sonarr's Settings > General)
{ ... }:
{
  services.prowlarr.enable = true;

  networking.firewall.allowedTCPPorts = [ 9696 ];
}
