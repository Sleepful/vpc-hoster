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
      require_mention = false;
      auto_thread = false;
    };

    # Register DeepSeek as a named provider so /model slash commands
    # can switch between models (e.g. /model deepseek/deepseek-v4-pro).
    # key_env tells hermes to read the API key from the DEEPSEEK_API_KEY
    # env var set via the .env file (sops template).
    settings.custom_providers = [{
      name = "deepseek";
      base_url = "https://api.deepseek.com/v1";
      key_env = "DEEPSEEK_API_KEY";
      default_model = "deepseek-chat";
    }];

    # Model aliases: /v4pro switches to the smarter model, /chat switches back
    settings.model_aliases = {
      v4pro = {
        model = "deepseek-v4-pro";
        provider = "custom:deepseek";
      };
      chat = {
        model = "deepseek-chat";
        provider = "custom:deepseek";
      };
    };
  };
}
