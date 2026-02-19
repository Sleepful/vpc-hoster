# When adding a new service to builder, add a link and redirect here.
{ pkgs, ... }:
let
  # Landing page linking to all builder services.
  # nginx serves this as a static file at /.
  dashboard = pkgs.writeTextDir "index.html" ''
    <!doctype html>
    <html>
    <head>
      <meta charset="utf-8">
      <title>builder</title>
      <style>
        body { font-family: monospace; background: #1a1a2e; color: #e0e0e0; margin: 3em auto; max-width: 500px; }
        h1 { color: #c0c0c0; }
        a { color: #7ec8e3; text-decoration: none; }
        a:hover { text-decoration: underline; }
        ul { list-style: none; padding: 0; }
        li { margin: 0.8em 0; font-size: 1.1em; }
        .desc { color: #888; font-size: 0.9em; }
      </style>
    </head>
    <body>
      <h1>builder</h1>
      <ul>
        <li><a href="/files/">copyparty</a> <span class="desc">- file manager / webdav</span></li>
        <li><a href="/jellyfin/">jellyfin</a> <span class="desc">- media streaming</span></li>
        <li><a href="/syncthing/">syncthing</a> <span class="desc">- file sync</span></li>
        <li><a href="/qbt/">qbittorrent</a> <span class="desc">- torrent client</span></li>
        <li><a href="/rclone/">rclone</a> <span class="desc">- b2 mount / cache stats</span></li>
        <li><a href="/sonarr/">sonarr</a> <span class="desc">- tv series search / download</span></li>
        <li><a href="/radarr/">radarr</a> <span class="desc">- movie search / download</span></li>
        <li><a href="/prowlarr/">prowlarr</a> <span class="desc">- indexer manager</span></li>
      </ul>
    </body>
    </html>
  '';
in
{
  services.nginx = {
    enable = true;
    recommendedProxySettings = true;

    virtualHosts.default = {
      default = true;
      listen = [{ addr = "0.0.0.0"; port = 80; }];

      # Dashboard
      locations."/" = {
        root = dashboard;
        index = "index.html";
      };

      # Copyparty — redirect to its native port
      locations."/files/" = {
        return = "302 http://$host:3923/";
      };

      # Jellyfin — redirect to its native port (sub-path proxying is unreliable)
      locations."/jellyfin/" = {
        return = "302 http://$host:8096/";
      };

      # Syncthing — redirect to its native port (no sub-path support)
      locations."/syncthing/" = {
        return = "302 http://$host:8384/";
      };

      # qBittorrent — redirect to its native port
      locations."/qbt/" = {
        return = "302 http://$host:8080/";
      };

      # rclone RC API + web GUI — cache stats, prefetch, transfer monitoring
      locations."/rclone/" = {
        return = "302 http://$host:5572/";
      };

      # Sonarr — TV series search and download manager
      locations."/sonarr/" = {
        return = "302 http://$host:8989/";
      };

      # Radarr — movie search and download manager
      locations."/radarr/" = {
        return = "302 http://$host:7878/";
      };

      # Prowlarr — indexer manager for Sonarr/Radarr
      locations."/prowlarr/" = {
        return = "302 http://$host:9696/";
      };
    };
  };

  # Open HTTP port on LAN (already open on Tailscale via trustedInterfaces)
  networking.firewall.allowedTCPPorts = [ 80 ];
}
