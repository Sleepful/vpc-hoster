NAME := "nix"

delete:
	ssh {{NAME}} "rm -rf /etc/nixos/*"

copy:
	rsync -av --include='src/' --include='*.nix' --exclude='*' --exclude='.git/*' . root@{{NAME}}:/etc/nixos

sync: delete copy

build:
	ssh {{NAME}} "time nixos-rebuild switch"

SOPS_KEY := "~/.ssh/id_ed25519_nix_hoster"
secret filename:
	SOPS_AGE_SSH_PRIVATE_KEY_FILE={{SOPS_KEY}} sops {{filename}}
