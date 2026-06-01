{ config, pkgs, ... }:
{
  services.hermes-agent = {
    enable = true;
    settings.model = {
      base_url = "https://api.deepseek.com/v1";
      default = "deepseek-chat";
    };
    environmentFiles = [ config.sops.templates."hermes-env".path ];
    addToSystemPackages = true;
    extraPackages = with pkgs; [ jq curl ];
    extraDependencyGroups = [ "matrix" ];

    settings.gateway.platforms.matrix.enabled = true;
    settings.matrix = {
      require_mention = true;
      auto_thread = false;
    };
  };
}
