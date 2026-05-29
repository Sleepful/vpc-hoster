{ config, lib, ... }:
let
  ids = config.homelab.identifiers;
  dockerGroup = lib.optional (config.virtualisation.oci-containers.backend or "" == "docker") "docker";
in
{
  users.users.debug = {
    isNormalUser = true;
    extraGroups = [ "systemd-journal" ] ++ dockerGroup;
    openssh.authorizedKeys.keys = [ ids.users.deployAuthorizedKey ];
  };
}
