NAME := "nix"

delete:
	ssh {{NAME}} "rm -f /etc/nixos/*"
copy:
	scp -r ./*.nix root@{{NAME}}:/etc/nixos

sync: delete copy

build:
	ssh {{NAME}} "time nixos-rebuild switch"
