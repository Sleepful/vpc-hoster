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
deploy machine=NAME:
	just sync
	ssh {{NAME}} "nixos-rebuild switch --flake path:{{REMOTE}}#{{machine}}"

# Deploy a remote machine (builder builds and pushes via SSH)
deploy-remote machine:
	just sync
	ssh {{NAME}} "nixos-rebuild switch --flake path:{{REMOTE}}#{{machine}} --target-host {{machine}}"

# Bootstrap a fresh builder:
# 0. After installing nixos on the target machine (partitioning, nixos-install ...)
# 1. Copies configuration.nix and hardware-configuration.nix from the builder
# 2. User must manually edit configuration.nix to add: ./imports.nix to imports
# 3. Then run `just deploy` to complete the bootstrap
bootstrap:
	scp {{NAME}}:/etc/nixos/configuration.nix ./machines/builder/configuration.nix
	scp {{NAME}}:/etc/nixos/hardware-configuration.nix ./machines/builder/hardware-configuration.nix
	@echo ""
	@echo "==> Copied configuration.nix and hardware-configuration.nix"
	@echo "==> Now edit machines/builder/configuration.nix:"
	@echo "    Add ./imports.nix to the imports list"
	@echo "==> Then run: just deploy"

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
