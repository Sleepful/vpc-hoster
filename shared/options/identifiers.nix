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
      dex = mkOption { type = types.str; default = "dex"; };
      email = mkOption { type = types.str; default = "email"; };
      grafana = mkOption { type = types.str; default = "grafana"; };
      mail = mkOption { type = types.str; default = "mail"; };
      mini = mkOption { type = types.str; default = "mini"; };
      outline = mkOption { type = types.str; default = "outline"; };
      sync = mkOption { type = types.str; default = "sync"; };
      torrent = mkOption { type = types.str; default = "torrent"; };
      tunnel = mkOption { type = types.str; default = "tunnel"; };
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
  };
}
