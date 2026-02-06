{ lib, ... }:
{
  config.homelab.identifiers = {
    domain = {
      root = lib.mkDefault "example.com";
      acmeEmail = lib.mkDefault "ops@example.com";
    };

    hosts.house = {
      name = lib.mkDefault "house";
      ipv4 = lib.mkDefault "203.0.113.10";
      sshHostPublicKey = lib.mkDefault "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIexample000000000000000000000000000 house";
    };

    users = {
      deployUser = lib.mkDefault "deploy";
      deployAuthorizedKey = lib.mkDefault "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIexample000000000000000000000000000 deploy@example";
    };

    subdomains = {
      acmechallenge = lib.mkDefault "acmechallenge";
      cal = lib.mkDefault "cal";
      dex = lib.mkDefault "dex";
      email = lib.mkDefault "email";
      grafana = lib.mkDefault "grafana";
      mail = lib.mkDefault "mail";
      mini = lib.mkDefault "mini";
      outline = lib.mkDefault "outline";
      sync = lib.mkDefault "sync";
      tunnel = lib.mkDefault "tunnel";
    };

    syncthing.devices = lib.mkDefault { };

    mail = {
      contactAddress = lib.mkDefault "contact@example.com";
      postmasterAddress = lib.mkDefault "postmaster@example.com";
      catchAllDomain = lib.mkDefault "@example.com";
      outlineNoReplyAddress = lib.mkDefault "outline.noreply@example.com";
      familyAddress = lib.mkDefault "family@example.com";
      sharedAddress = lib.mkDefault "shared@example.com";
      outlineReplyAddress = lib.mkDefault "host.outline@example.com";
      dexSuperAddress = lib.mkDefault "service.outline.super@example.com";
      dexAtlasAddress = lib.mkDefault "atlas@example.net";
      dexLumenAddress = lib.mkDefault "lumen@example.net";
      dexSuperUsername = lib.mkDefault "super";
      dexAtlasUsername = lib.mkDefault "atlas";
      dexLumenUsername = lib.mkDefault "lumen";
    };
  };
}
