NAME := "builder"

delete:
	ssh {{NAME}} "sudo rm -rf /etc/nixos/*"

copy:
	rsync -av --include='*/' --include='*.nix' --exclude='*' machines/builder/ root@{{NAME}}:/etc/nixos

validate: sync
	ssh {{NAME}} "nix-instantiate '<nixpkgs/nixos>' -A system --arg configuration /etc/nixos/configuration.nix"
	# Done! for a thorough validation use: ssh builder "nixos-rebuild dry-build"

alias s := syntax
syntax:
	nix-instantiate --eval ./machines/builder/configuration.nix

sync: delete copy

deploy: sync build

build:
	ssh {{NAME}} "time nixos-rebuild switch"

SOPS_KEY := "~/.ssh/id_ed25519_nix_hoster"
secret filename:
	SOPS_AGE_SSH_PRIVATE_KEY_FILE={{SOPS_KEY}} sops {{filename}}
