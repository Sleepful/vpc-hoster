{ pkgs ? import <nixpkgs> { } }:

pkgs.rustPlatform.buildRustPackage {
  pname = "mc-discord-bot";
  version = "1.0.0";

  src = pkgs.fetchFromGitHub {
    owner = "Sleepful";
    repo = "minecraft-discord-bot-ec2";
    rev = "11a62344100367f997b32dbef15489ab515dc0d1";
    hash = "sha256-ezICkv3ayyMPR2s3DOUvQJzr/bbiToZnqE/ZFXYLIz4=";
  };

  # Upstream lockfile pins `time = 0.3.34`, which fails on newer Rust toolchains
  # (type inference break introduced around Rust 1.80; error E0282 in time's parser).
  # We patch Cargo.lock during vendoring to use `time >= 0.3.35`.
  #
  # Upstream fix in Sleepful/minecraft-discord-bot-ec2:
  #   cargo update -p time --precise 0.3.36
  #   git add Cargo.lock && git commit
  # After upstream includes that lockfile update, remove this cargoPatches entry
  # and refresh cargoHash for the unpatched source.
  cargoPatches = [
    ./cargo-lock-time-0.3.36.patch
  ];

  cargoHash = "sha256-LtVTBvzPLCeUSmjdg6z0inrGQDK8ilWMmV3evbnQ9gE=";

  meta.mainProgram = "mc_discord";
}
