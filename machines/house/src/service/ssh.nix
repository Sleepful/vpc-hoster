{ config, ... }:
let
  ids = config.homelab.identifiers;
in
{
  services.openssh.enable = true;
  services.openssh.settings = {
    PasswordAuthentication = false;
    KbdInteractiveAuthentication = false;
    PermitRootLogin = "prohibit-password";
  };

  users.users."${ids.users.deployUser}" = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = [ ids.users.deployAuthorizedKey ];
  };
}
