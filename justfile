NAME := "builder"
REMOTE := "/etc/nixos"

delete:
	ssh {{NAME}} "rm -rf {{REMOTE}}/*"

copy:
	rsync -av --exclude='.git/' --exclude='.jj/' . {{NAME}}:{{REMOTE}}

sync: delete copy

# Pin nixpkgs on builder, copy lockfile back to repo
lock:
	just sync
	ssh {{NAME}} "nix flake lock path:{{REMOTE}}"
	scp {{NAME}}:{{REMOTE}}/flake.lock ./flake.lock

# Deploy builder (rebuilds itself)
deploy machine="builder":
	just sync
	ssh {{NAME}} "nixos-rebuild switch --flake path:{{REMOTE}}#{{machine}}"

# Deploy a remote machine (builder builds and pushes via SSH)
deploy-remote machine:
	just sync
	ssh {{NAME}} "nixos-rebuild switch --flake path:{{REMOTE}}#{{machine}} --target-host {{machine}}"

# Bootstrap a fresh builder (no flakes required) — enables flakes for subsequent deploys
# After this succeeds, use `just deploy` for all subsequent deploys
bootstrap:
	just sync
	ssh {{NAME}} "nixos-rebuild switch --no-flake -I nixos-config={{REMOTE}}/machines/builder/configuration.nix"

# Validate flake evaluation without building
check machine="builder":
	just sync
	ssh {{NAME}} "nix eval path:{{REMOTE}}#nixosConfigurations.{{machine}}.config.system.build.toplevel --no-build"

# Local syntax check (macOS, no SSH)
alias s := syntax
syntax:
	nix-instantiate --eval ./machines/builder/configuration.nix

SOPS_KEY := "~/.ssh/id_ed25519_nix_hoster" # private key for decrypting only
secret filename:
	SOPS_AGE_SSH_PRIVATE_KEY_FILE={{SOPS_KEY}} sops {{filename}}
