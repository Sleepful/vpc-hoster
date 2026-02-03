# Homelab NixOS Infrastructure

Multi-machine NixOS configurations managed from macOS. The **builder** machine
(Proxmox VM) is the build server — it rebuilds itself and deploys to remote
machines over SSH.

## Prerequisites

- macOS with `just`, `rsync`, and SSH configured
- SSH alias `builder` in `~/.ssh/config` pointing to the builder machine
- A fresh NixOS install on the builder (any channel)

## Bootstrap (fresh builder)

A new builder won't have Nix flakes enabled yet. The bootstrap recipe deploys
the config using the traditional channel method, which enables flakes as part
of the build.

```sh
# 1. Bootstrap — deploys config without flakes, enables flakes on the machine
just bootstrap

# 2. Lock — pins nixpkgs, copies flake.lock back to your local repo
just lock

# 3. Commit flake.lock so future deploys are reproducible
```

After this, the builder is ready for flake-based deploys. You only need to
run bootstrap once per fresh machine.

## Daily usage

```sh
# Deploy builder (default)
just deploy

# Deploy hoster (builder builds and pushes over SSH)
just deploy-remote hoster

# Validate config without building (fast)
just check
just check hoster

# Local syntax check (no SSH needed)
just s

# Edit a SOPS-encrypted secret
just secret <filename>

# Re-lock nixpkgs after updating the pin in flake.nix
just lock
```

## Adding a new machine

1. Create `machines/<name>/configuration.nix` and `machines/<name>/src/config.nix`
2. Import `../../../shared/base.nix` from `config.nix` for common settings
3. Add a `nixosConfigurations.<name>` entry in `flake.nix`
4. Deploy with `just deploy-remote <name>`

## Setting up NixOS in a Proxmox VM

Assuming that there is already access to a Proxmox instance, ideally in a LAN for low latencies.

- Download ISO to Proxmox VM collection, easy to do by using the official NixOS URL from the official site and entering this URL in Proxmox GUI.
- Launch the VM.
- Find the ip of the VM by opening the terminal from the GUI and using `ifconfig`.
- Add a temporary password in console with `sudo passwd`
- Now on your local machine, save the ip as an alias in `~/.ssh/config`
```
Host builder
  Port 22
  User root
  HostName <ip>
```
- Now you can ssh into `root@builder` and use the password.
- Paste your public key:
```
echo "your pub key" > /root/.ssh/authorized_keys
```
- Delete the temporary password: `sudo passwd -d root`
- Run `just bootstrap` to deploy the initial config and enable flakes
- Run `just lock` to pin nixpkgs, then commit `flake.lock`
- From now on, deploy with `just deploy`

You can confirm that the configuration has been applied by running `tree` — if the
command is found, the config was deployed successfully.
