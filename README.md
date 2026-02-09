# Homelab NixOS Infrastructure

Multi-machine NixOS configurations managed from macOS. The **builder** machine
(Proxmox VM) is the build server — it rebuilds itself and deploys to remote
machines over SSH.

## Prerequisites

- macOS with `just`, `rsync`, and SSH configured
- SSH alias `builder` in `~/.ssh/config` pointing to the builder machine
- A fresh NixOS install on the builder (any channel)

## Repository structure

```text
builder/
├── flake.nix                         # nixosConfigurations entrypoints
├── justfile                          # deploy/bootstrap/check helpers
├── machines/
│   ├── builder/                      # builder host config
│   ├── house/                        # house host config + services
│   └── hoster/                       # reserved for future hoster machine
├── shared/
│   ├── base.nix                      # shared base imports/packages
│   ├── options/identifiers.nix       # identifier option schema
│   └── identifiers/default.nix       # safe default identifier values
├── secrets/
│   └── house/core.yaml               # SOPS-encrypted runtime secrets
├── scripts/
│   └── bootstrap-deploy-key.sh       # deploy-key bootstrap helper
└── private/                          # private submodule overrides (optional)
    └── identifiers/default.nix       # real identifier values
```

Notes:
- `machines/<name>/configuration.nix` is machine entrypoint; `machines/<name>/src/` holds service modules.
- `shared/*` keeps reusable config; `private/*` overrides it when the submodule is present.
- Secret values live in SOPS files, while secret wiring lives in Nix modules.

### Where to put new files

- New machine: add `machines/<name>/configuration.nix`, `machines/<name>/src/config.nix`, then register it in `flake.nix`.
- Machine-only service: add `machines/<name>/src/service/<feature>.nix` and import it from `machines/<name>/src/config.nix`.
- Shared reusable config: add under `shared/` and import from `shared/base.nix` or machine modules.
- New secret value: add encrypted key in `secrets/<machine>/core.yaml`, then declare wiring in `machines/<machine>/src/service/secrets.nix`.
- Sensitive identifiers/overrides: put real values in `private/identifiers/default.nix`; keep safe defaults in `shared/identifiers/default.nix`.
- Data/config payloads for a service (yaml/json): keep near the machine under `machines/<name>/src/data/` and reference from that service module.

### New service checklist

1. Create `machines/<name>/src/service/<feature>.nix` and import it from `machines/<name>/src/config.nix`.
2. If the service needs secrets, add encrypted values in `secrets/<name>/core.yaml` and wire them in `machines/<name>/src/service/secrets.nix`.
3. If the service needs domains/users/addresses, read them from `config.homelab.identifiers.*` instead of hardcoding values.
4. Run local eval checks: `just check-local <name>` (and `just check <name>` if builder orchestration is used).
5. Deploy and verify: `just deploy-remote <name>` (or `just deploy-remote-to <name> <ip>`) then run `just health-house root@<house-ip>` for house.
6. If a deploy regresses behavior, rollback on the target: `ssh root@<target-ip> "nixos-rebuild switch --rollback"`.

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

# `just deploy` is builder-only. Use deploy-remote for non-builder machines.

# Deploy house (builder builds and pushes over SSH)
just deploy-remote house

# Deploy to explicit SSH target (no alias on builder required)
just deploy-remote-to house <house-ip>

# Bootstrap builder deploy key access for a new machine
just bootstrap-key house root@<house-ip>

# Bootstrap for an explicit user (defaults to DEPLOY_USER in justfile)
just bootstrap-key-user house root@<house-ip> <deploy-user>

# If deploy user does not exist yet on target, bootstrap root once
# (first deploy path: root once, then switch to your deploy user)
just bootstrap-key-root house root@<house-ip>

# Bootstrap deploy meanings
# - bootstrap-key: grant builder SSH access for the default deploy user (DEPLOY_USER)
# - deploy-remote-bootstrap: first nixos switch using root@<machine>
# - deploy-remote-to-bootstrap: same first switch but with explicit target/IP
just deploy-remote-bootstrap house
just deploy-remote-to-bootstrap house <house-ip>

# Local orchestration for house (no builder hop)
just check-local house
just deploy-local-house-bootstrap root@<house-ip>
just deploy-local-house <deploy-user>@house

# Quick post-deploy health check on house
just health-house root@<house-ip>

# Validate config without building (fast)
just check
just check house

# Local syntax check (no SSH needed)
just s

# Edit a SOPS-encrypted secret
just secret <filename>

# Submodule helper recipes
just submodule-status
just submodule-commit-all "message"

# One-time: derive age identity from SSH key for SOPS
nix --extra-experimental-features "nix-command" run nixpkgs#ssh-to-age -- -private-key -i ~/.ssh/<your_ssh_key> >> ~/.config/sops/age/keys.txt

# Re-lock nixpkgs after updating the pin in flake.nix
just lock
```

## Bootstrapping a new remote machine

Use this whenever a machine is new and builder does not yet have deploy access.

1. Create machine config files (`machines/<name>/configuration.nix`, `machines/<name>/src/config.nix`) and add `nixosConfigurations.<name>` in `flake.nix`.
2. Add builder-side trust and name resolution in `machines/builder/src/config.nix`:
   - `programs.ssh.knownHosts.<name>` with the target host public key.
   - `networking.hosts."<target-ip>" = [ "<name>" ];`.
3. Ensure target machine config includes the deploy user (default is `DEPLOY_USER` from `justfile`) with your desired authorized keys and sudo policy.
4. Apply builder changes first: `just deploy`.
5. Bootstrap builder deploy auth to target:
   - Default deploy user: `just bootstrap-key <name> root@<target-ip>`
   - Explicit user: `just bootstrap-key-user <name> root@<target-ip> <user>`
6. Deploy the target machine with centralized just recipes:
   - Preferred: `just deploy-remote <name>`
   - If hostname is not resolvable on builder yet: `just deploy-remote-to <name> <target-ip>`
   - To make hostname resolvable on builder, add in `machines/builder/src/config.nix`:

```nix
networking.hosts."<target-ip>" = [ "<name>" ];
```

   Then run `just deploy` and verify with `ssh builder "getent hosts <name>"`.

If the deploy user does not exist yet on target:

1. `just bootstrap-key-root <name> root@<target-ip>`
2. First deploy: `just deploy-remote-to-bootstrap <name> <target-ip>`
3. `just bootstrap-key <name> root@<target-ip>`
   - Required: this grants builder key access to your deploy user; root bootstrap only grants access to `root`.
   - Normal deploy recipes use `DEPLOY_USER` + `--use-remote-sudo`, so this step is needed before routine deploys.
4. Continue with: `just deploy-remote <name>`

7. Continue using `just deploy-remote <name>` for routine deploys.

## Builder vs local orchestration

- Builder orchestration keeps one Linux control-plane and one shared deploy key for all machines.
- Local orchestration is simpler for house if your macOS already has working Nix and SSH access.

Notes:
- `just bootstrap-key` and `just bootstrap-key-user` are idempotent and re-usable across machines.
- The shared builder deploy key path is `/root/.ssh/id_ed25519_deploy`.
- If host IP or host key changes, update `machines/builder/src/config.nix` and re-run `just deploy`.

## Private overlay via submodule

This repo supports a private identifier overlay mounted as a submodule at `private/`.

```sh
# First clone
git clone git@github.com:Sleepful/vpc-hoster.git
cd vpc-hoster/builder
git submodule update --init --recursive

# Or clone in one step
git clone --recurse-submodules git@github.com:Sleepful/vpc-hoster.git

# After pulling updates
git pull
git submodule update --init --recursive
```

The shared defaults live in `shared/identifiers/default.nix` (safe placeholders).
Real values should live in `private/identifiers/default.nix` (private repo).

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
