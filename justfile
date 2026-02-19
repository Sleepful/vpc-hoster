NAME := "builder"
REMOTE := "/etc/nixos"
DEPLOY_USER := "jose"
DEPLOY_KEY := "/root/.ssh/id_ed25519_deploy"

delete:
	ssh {{NAME}} "rm -rf {{REMOTE}}/*"

copy:
	rsync -av --exclude='.git/' --exclude='.jj/' . {{NAME}}:{{REMOTE}}

sync: delete copy

# Update flake lockfile locally
lock:
	nix flake update nixpkgs

# Deploy builder only (rebuilds itself)
# Intentionally no machine arg to avoid accidental `just deploy house`.
deploy:
	just sync
	ssh {{NAME}} "nixos-rebuild switch --flake path:{{REMOTE}}#builder"

# Deploy a remote machine (builder builds and pushes via SSH)
deploy-remote machine:
	just sync
	ssh {{NAME}} "NIX_SSHOPTS='-o IdentitiesOnly=yes -i {{DEPLOY_KEY}}' nixos-rebuild switch --fast --flake path:{{REMOTE}}#{{machine}} --target-host {{DEPLOY_USER}}@{{machine}} --use-remote-sudo"

# One-time bootstrap deploy when DEPLOY_USER does not exist yet
deploy-remote-bootstrap machine:
	just sync
	ssh {{NAME}} "NIX_SSHOPTS='-o IdentitiesOnly=yes -i {{DEPLOY_KEY}}' nixos-rebuild switch --fast --flake path:{{REMOTE}}#{{machine}} --target-host root@{{machine}}"

# Deploy a remote machine to an explicit SSH target
deploy-remote-to machine target:
	just sync
	ssh {{NAME}} "NIX_SSHOPTS='-o IdentitiesOnly=yes -i {{DEPLOY_KEY}}' nixos-rebuild switch --fast --flake path:{{REMOTE}}#{{machine}} --target-host {{DEPLOY_USER}}@{{target}} --use-remote-sudo"

# One-time bootstrap deploy to explicit target when DEPLOY_USER is missing
deploy-remote-to-bootstrap machine target:
	just sync
	ssh {{NAME}} "NIX_SSHOPTS='-o IdentitiesOnly=yes -i {{DEPLOY_KEY}}' nixos-rebuild switch --fast --flake path:{{REMOTE}}#{{machine}} --target-host root@{{target}}"

# Bootstrap builder SSH deploy access for an explicit target user
bootstrap-key-user machine target user="jose":
	./scripts/bootstrap-deploy-key.sh --builder {{NAME}} --machine {{machine}} --target {{target}} --deploy-host {{machine}} --target-user {{user}}

# Bootstrap builder SSH deploy access for default deploy user (jose)
bootstrap-key machine target:
	./scripts/bootstrap-deploy-key.sh --builder {{NAME}} --machine {{machine}} --target {{target}} --deploy-host {{machine}} --target-user {{DEPLOY_USER}}

# Bootstrap builder SSH deploy access as root (temporary, first deploy only)
bootstrap-key-root machine target:
	just bootstrap-key-user {{machine}} {{target}} root

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
	ssh {{NAME}} "nix eval path:{{REMOTE}}#nixosConfigurations.{{machine}}.config.system.build.toplevel.drvPath --raw"

# Delete all old generations and garbage-collect the Nix store
gc machine="builder":
	ssh {{machine}} "nix-collect-garbage -d"

# Resize builder disk after expanding it in Proxmox (ext4, /dev/sda1)
resize-disk:
	ssh {{NAME}} "growpart /dev/sda 1 && resize2fs /dev/sda1 && echo 'Done:' && df -h /"

# Check builder usage and inode usage
disk machine="builder":
	ssh {{machine}} "df -h / /nix/store; echo; df -ih / /nix/store; echo; du -sh /nix/store"

# Local syntax check (macOS, no SSH)
alias s := syntax
syntax:
	nix-instantiate --eval ./machines/builder/configuration.nix

# Evaluate config directly from local machine (no builder hop)
check-local machine="house":
	nix --extra-experimental-features "nix-command flakes" eval .#nixosConfigurations.{{machine}}.config.system.build.toplevel.drvPath --raw

# Deploy house from local machine (bootstrap, root on target)
deploy-local-house-bootstrap target="root@house":
	nix --extra-experimental-features "nix-command flakes" run nixpkgs#nixos-rebuild -- switch --fast --flake .#house --target-host {{target}}

# Deploy house from local machine (routine, jose + remote sudo)
deploy-local-house target="jose@house":
	nix --extra-experimental-features "nix-command flakes" run nixpkgs#nixos-rebuild -- switch --fast --flake .#house --target-host {{target}} --use-remote-sudo

# Follow qbittorrent, upload, and cleanup service logs on builder
qbt-logs target="builder":
	ssh {{target}} "journalctl -u qbittorrent -u qbt-upload-b2 -u qbt-cleanup -f --no-pager"

# List active torrents with avg upload rate, seeding duration, and size
torrents target="builder":
	python3 scripts/torrents.py {{target}}

# List files on the B2 mount (defaults to mount root)
b2-ls path="" target="builder":
	ssh {{target}} "ls -lh '/media/b2/{{path}}'"

# Show VFS cache stats (size, open files, active uploads/downloads)
# Uses POST because the rclone RC API requires POST for all endpoints.
b2-cache target="builder":
	ssh {{target}} "curl -s -X POST http://localhost:5572/vfs/stats | jq"

# Prefetch a file into VFS cache before playback by reading it through
# the FUSE mount. Streams to /dev/null — the VFS cache keeps the data.
# Path is relative to the B2 mount root, e.g.:
#   just b2-warm 'downloads/Movies/Some Movie (2024)/movie.mkv'
b2-warm path target="builder":
	ssh {{target}} "cat '/media/b2/{{path}}' > /dev/null && echo 'Cached: {{path}}' || echo 'Failed — check path or rclone-b2-mount status'"

# Quick service health check on house
health-house target="root@house":
	ssh {{target}} "systemctl --failed --no-pager; echo; systemctl is-active dex outline postfix dovecot2"

SOPS_KEY_FILE := "~/.config/sops/age/keys.txt" # contains AGE-SECRET-KEY identities
secret filename:
	SOPS_AGE_KEY_FILE={{SOPS_KEY_FILE}} sops {{filename}}

# Derive an age public key from a machine's SSH host key
age-key machine="builder":
	ssh {{machine}} "cat /etc/ssh/ssh_host_ed25519_key.pub" | nix --extra-experimental-features "nix-command flakes" shell nixpkgs#ssh-to-age -c ssh-to-age

# Generate bcrypt hashes (raw $2y$/$2b$) for Dovecot/Dex.
# Uses the fastest available local tool:
# - htpasswd (preferred; interactive prompt)
# - doveadm
# - fallback to `nix shell nixpkgs#dovecot`
hash-bcrypt rounds="5":
	@bash -lc 'set -euo pipefail; r="{{rounds}}"; \
	  if command -v htpasswd >/dev/null 2>&1; then \
	    htpasswd -nBC "$r" user | cut -d: -f2; \
	  elif command -v doveadm >/dev/null 2>&1; then \
	    doveadm pw -s BLF-CRYPT -r "$r" | sed "s/^{BLF-CRYPT}//"; \
	  else \
	    ROUNDS="$r" nix --extra-experimental-features "nix-command flakes" shell nixpkgs#dovecot -c sh -c "doveadm pw -s BLF-CRYPT -r \"$ROUNDS\" | sed \"s/^{BLF-CRYPT}//\""; \
	  fi'

# Generate a hash on the house machine (fast, no local dependencies).
hash-bcrypt-house rounds="5" target="root@house":
	ssh -t {{target}} "doveadm pw -s BLF-CRYPT -r {{rounds}}"

# Show uncommitted changes inside a git submodule
submodule-status submodule="private":
	@if [ ! -d "{{submodule}}" ]; then echo "Submodule path '{{submodule}}' does not exist"; exit 1; fi
	git -C {{submodule}} status --short

submodule-diff submodule="private":
	@if [ ! -d "{{submodule}}" ]; then echo "Submodule path '{{submodule}}' does not exist"; exit 1; fi
	git -C {{submodule}} diff

# Commit all changes inside a git submodule (runs git add .)
submodule-commit-all message submodule="private":
	@if [ ! -d "{{submodule}}" ]; then echo "Submodule path '{{submodule}}' does not exist"; exit 1; fi
	git -C {{submodule}} add . && git -C {{submodule}} commit -m "{{message}}" && git -C {{submodule}} push
