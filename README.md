# Setting up NixOs in a Proxmox VM

Assuming that there is already access to a Proxmox instance, ideally in a LAN for low latencies.

- Download ISO to Proxmox VM collection, easy to do by using the official NixOs URL from the official site and entering this URL in Proxmox GUI.
- Launch the VM.
- Find the ip of the VM by opening the terminal from the GUI and using `ifconfig`.
- Add a temporary password in console with `sudo passwd`
- Now on your local machine, save the ip as an alias in `~/.ssh/config`
```
Host nix
  Port 22
  User root
  HostName <ip>
```
- Now you can ssh into `root@nix` and use the password.
- Now you can paste your public key:

```
echo "your pub key" > /root/.ssh/authorized_keys
```
- And finally you can delete the temporary password
`sudo passwd -d root`


- Now we can write the config on our machine and copy it into ssh.

The initial config is just this:

`/etc/nixos/configuration.nix`:
```
{ config, pkgs, ... }:

{
  imports = [ <nixpkgs/nixos/modules/installer/cd-dvd/installation-cd-minimal-combined.nix> ];
}
```

By cloning this repo locally and using the commands in the makefile, easily write the config on your local machine and copy it over to the NixOs Proxmox.

You can confirm that the configuration has been applied just by running `tree`, if `tree` command is found, that means configuartion was successful.
