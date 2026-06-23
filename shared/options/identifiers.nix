{ lib, ... }:
with lib;
{
  options.homelab.identifiers = {
    domain = {
      root = mkOption {
        type = types.str;
        example = "example.com";
      };

      acmeEmail = mkOption {
        type = types.str;
        example = "ops@example.com";
      };
    };

    hosts = {
      house = {
        name = mkOption {
          type = types.str;
          default = "house";
        };

        ipv4 = mkOption {
          type = types.str;
          example = "203.0.113.10";
        };

        sshHostPublicKey = mkOption {
          type = types.str;
          example = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIexample000000000000000000000000000 house";
        };
      };
    };

    users = {
      deployUser = mkOption {
        type = types.str;
        default = "deploy";
      };

      deployAuthorizedKey = mkOption {
        type = types.str;
        example = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIexample000000000000000000000000000 deploy@example";
      };
    };

    subdomains = {
      acmechallenge = mkOption { type = types.str; default = "acmechallenge"; };
      cal = mkOption { type = types.str; default = "cal"; };
      auth = mkOption { type = types.str; default = "auth"; };
      chat = mkOption { type = types.str; default = "chat"; };
      dex = mkOption { type = types.str; default = "dex"; };
      docs = mkOption { type = types.str; default = "docs"; };
      email = mkOption { type = types.str; default = "email"; };
      grafana = mkOption { type = types.str; default = "grafana"; };
      mail = mkOption { type = types.str; default = "mail"; };
      matrix = mkOption { type = types.str; default = "matrix"; };
      mini = mkOption { type = types.str; default = "mini"; };
      mm = mkOption { type = types.str; default = "mm"; };
      outline = mkOption { type = types.str; default = "outline"; };
      sync = mkOption { type = types.str; default = "sync"; };
      torrent = mkOption { type = types.str; default = "torrent"; };
      tunnel = mkOption { type = types.str; default = "tunnel"; };
    };

    admin = {
      email = mkOption {
        type = types.str;
        example = "admin@example.com";
      };
    };

    mural = {
      root = mkOption {
        type = types.str;
        example = "example.net";
      };

      subdomains = {
        foro = mkOption { type = types.str; default = "forum"; };
      };
    };

    qbittorrent.passwordHash = mkOption {
      type = types.str;
      description = "PBKDF2 hash for qBittorrent web UI, including @ByteArray(...) wrapper.";
      example = "@ByteArray(salt==:hash==)";
    };

    syncthing.devices = mkOption {
      type = types.attrsOf (types.submodule ({ ... }: {
        options.id = mkOption {
          type = types.str;
          example = "ABCDEF1-2345678-90ABCDE-FGHIJKL-MNOPQRS-TUVWXYZ-1234567-89ABCDE";
        };
      }));
      default = { };
      description = "Syncthing remote devices keyed by alias.";
    };

    mail = {
      contactAddress = mkOption {
        type = types.str;
        example = "contact@example.com";
      };

      postmasterAddress = mkOption {
        type = types.str;
        example = "postmaster@example.com";
      };

      catchAllDomain = mkOption {
        type = types.str;
        example = "@example.com";
      };

      outlineNoReplyAddress = mkOption {
        type = types.str;
        example = "outline.noreply@example.com";
      };

      familyAddress = mkOption {
        type = types.str;
        example = "family@example.com";
      };

      sharedAddress = mkOption {
        type = types.str;
        example = "shared@example.com";
      };

      outlineReplyAddress = mkOption {
        type = types.str;
        example = "host.outline@example.com";
      };

      dexSuperAddress = mkOption {
        type = types.str;
        example = "service.outline.super@example.com";
      };

      dexAtlasAddress = mkOption {
        type = types.str;
        example = "atlas@example.net";
      };

      dexLumenAddress = mkOption {
        type = types.str;
        example = "lumen@example.net";
      };

      dexSuperUsername = mkOption {
        type = types.str;
        default = "super";
      };

      dexAtlasUsername = mkOption {
        type = types.str;
        default = "atlas";
      };

      dexLumenUsername = mkOption {
        type = types.str;
        default = "lumen";
      };
    };

    keycloakRealm = mkOption {
      type = types.str;
      default = "master";
      description = "Keycloak realm used for OIDC authentication (Matrix, Mattermost, Discourse).";
    };

    matrix = {
      requiredGroup = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Keycloak group required for Matrix login. null disables the check.";
      };
    };

    bridge = {
      discordGuild = mkOption {
        type = types.str;
        example = "1014051032923385886";
        description = "Discord server (guild) ID for the bridge bot.";
      };

      discordChannel = mkOption {
        type = types.str;
        example = "1014053253853495296";
        description = "Discord channel ID to bridge.";
      };

      mattermostTeam = mkOption {
        type = types.str;
        example = "internet";
        description = "Mattermost team name for the bridged channel.";
      };

      mattermostChannel = mkOption {
        type = types.str;
        example = "town-square";
        description = "Mattermost channel URL slug to bridge (the segment after /channels/, not the internal ID).";
      };
    };
  };
}
