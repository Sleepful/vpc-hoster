{ config, pkgs, ... }:
{
  services.hermes-agent = {
    enable = true;
    settings.model.default = "anthropic/claude-sonnet-4";
    environmentFiles = [ config.sops.templates."hermes-env".path ];
    addToSystemPackages = true;
    extraPackages = with pkgs; [ jq curl ];
  };
}
