# AGENTS.md

## Project Overview

NixOS infrastructure-as-code for a homelab. Multi-machine mono-repo — each machine
gets its own directory under `machines/`. Pure Nix — no application code, no
TypeScript/JavaScript, no containers. Configuration is edited on macOS, rsynced to
the builder machine, and rebuilt there. The builder deploys to itself and to remote
machines via `nixos-rebuild --flake --target-host`.

Key technologies: NixOS, Nix flakes, `just` (task runner), SOPS/age (secrets),
Tailscale (VPN), PocketBase, PostgreSQL.

Currently managed machines:
- **builder** — Proxmox VM that builds NixOS configurations.
- **hoster** — Hetzner VPS.

## Repository Layout

```
flake.nix                          # Flake entry point — declares inputs + nixosConfigurations
flake.lock                         # Pinned nixpkgs revision (generated)
justfile                           # Deployment automation (just)
.sops.yaml                         # Secrets encryption config (age key)
shared/
  base.nix                         # Common config shared by all machines (flakes, journald, tree)
machines/
  builder/
    configuration.nix              # NixOS root entry point — imports src/config.nix
    src/
      config.nix                   # Machine-specific config (hostname) + import hub
      service/                     # Network/infra services (tailscale, etc.)
      backend/                     # Application backends (pocketbase, postgraphile)
      database/                    # Database engines (pg, mysql, sqlite)
  hoster/
    configuration.nix              # NixOS root entry point — imports src/config.nix
    src/
      config.nix                   # Machine-specific config (hostname) + import hub
```

Module import chain: `flake.nix` -> `machines/<machine>/configuration.nix` ->
`shared/base.nix` + `src/config.nix` -> `src/service/*.nix`.
Not all modules under `src/` are wired into the import chain — some are placeholders or
reference material (e.g., `postgraphile.nix` is comments only, `mysql.nix` and
`sqlite.nix` are empty).

## Build / Deploy / Test Commands

This project uses `just` as its task runner. All commands are defined in `justfile`.
Configuration is edited on macOS, rsynced to the builder machine, and rebuilt there
using Nix flakes.

```sh
# Deploy builder (default) — rsync + nixos-rebuild switch
just deploy

# Deploy a specific machine (builder rebuilds itself)
just deploy builder

# Deploy a remote machine (builder builds and pushes to it via SSH)
just deploy-remote hoster

# Individual steps:
just delete          # SSH rm -rf /etc/nixos/* on builder
just copy            # rsync entire repo to builder:/etc/nixos
just sync            # delete + copy

# Validate flake evaluation without building:
just check           # checks builder (default)
just check hoster    # checks hoster

# Local syntax check (macOS, no SSH):
just syntax          # or: just s

# Edit an encrypted secret file with SOPS:
just secret <filename>
```

The builder machine is the build server — all `nixos-rebuild` commands run there.
The `copy` recipe rsyncs the entire repo (excluding `.git/` and `.jj/`) to
`/etc/nixos` on builder. For remote machines like hoster, builder uses
`--target-host` to push the built closure over SSH (no rsync to hoster needed).

### Testing

There is no automated test suite. Testing is manual:
1. Make changes locally.
2. Deploy to a local NixOS VM (`just deploy`).
3. Verify the service works.
4. If it works, deploy to the production remote.

A successful `nixos-rebuild switch` (the `just deploy` step) is the primary
validation — NixOS module evaluation catches type errors, missing attributes,
and invalid option values at build time.

## Code Style Guidelines

### Language

All infrastructure code is Nix. Shell scripts appear only inside Nix heredoc strings
(`script = '' ... '';`) for systemd service definitions.

### File Naming

- **Files:** All lowercase, no separators. Short descriptive names: `pg.nix`,
  `tailnet.nix`, `pocketbase.nix`, `config.nix`.
- **Directories:** All lowercase, single English word describing the domain:
  `service/`, `backend/`, `database/`, `shared/`, `machines/`.

### Module Structure

Every `.nix` file follows the standard NixOS module pattern:

```nix
{ config, pkgs, ... }:
{
  # configuration attributes
}
```

- Only destructure the arguments you actually use (`config`, `pkgs`,
  `modulesPath`, etc.). Use `...` to ignore the rest.
- Opening brace for the returned attrset goes on the same line as the function
  signature or the next line — either is acceptable, but same-line is more common
  in this repo.

### Imports

- Use the `imports` list within a module to compose sub-modules.
- Use relative paths for local modules (`./service/tailnet.nix`,
  `../../../shared/base.nix`).
- Hardware/profile modules (e.g., installer CD) are declared in `flake.nix`
  module lists, not in `configuration.nix`.
- Only import modules that are actively used. Keep placeholder/WIP files
  as standalone files, not wired into the import chain.

### Formatting

- **Indentation:** 2 spaces. No tabs.
- **Semicolons:** Required after every attribute binding (Nix syntax).
- **Lists:** One item per line, closing `];` on its own line.
- **Line length:** No hard limit, but keep lines reasonable.
- **No formatter is configured.** There is no nixfmt or alejandra setup.
  Match the style of surrounding code.

### Attribute Naming

Follow NixOS module conventions:
- Dot-separated camelCase paths: `services.tailscale.enable`,
  `services.postgresql.dataDir`, `networking.hostName`.
- Systemd unit names use hyphens per systemd convention:
  `systemd.services.tailscale-autoconnect`.

### Comments

- Use `#` for inline comments. Prefer explaining "why" over "what".
- Use `/* ... */` block comments for extended architectural notes, tradeoff
  discussions, or ADR-style documentation (see `pocketbase.nix`).
- Reference URLs are placed as `#` comments above the relevant code.
- Entire files may be comments-only to serve as architectural decision records
  (see `postgraphile.nix`).

### Shell Scripts in Nix

When embedding bash in Nix heredoc strings (`script = '' ... '';`):
- Use `with pkgs;` to bring packages into scope so you can write
  `${tailscale}/bin/tailscale` instead of `${pkgs.tailscale}/bin/tailscale`.
- Always use full Nix store paths for binaries (`${jq}/bin/jq`), never bare
  command names — the script runs in a minimal environment.
- Use guard clauses (early `exit 0`) rather than deep nesting.

### Secrets

- Use SOPS with age encryption (`.sops.yaml` configures the age key).
- Edit secrets via `just secret <filename>`.
- **Never commit plaintext secrets to Nix files.** Pre-auth keys and tokens
  must go through SOPS, not inline in `.nix` source.

### Nix Patterns

- This project uses **Nix flakes**. `flake.nix` at the repo root declares
  all inputs (pinned nixpkgs) and all `nixosConfigurations`.
- Shared configuration lives in `shared/base.nix` and is imported by each
  machine's `src/config.nix`.
- No custom NixOS module options (`mkOption`) are defined — modules only
  consume upstream options via direct attribute assignment.
- No `let ... in` bindings, overlays, or custom packages are used currently.
  Keep things simple; only introduce these when genuinely needed.
- No `lib` usage currently. If needed, add `lib` to the module argument
  destructuring: `{ lib, config, pkgs, ... }:`.

### Justfile Conventions

- Variables use SCREAMING_CASE: `NAME`, `SOPS_KEY`, `REMOTE`.
- Recipe names use lowercase: `delete`, `copy`, `sync`, `deploy`, `check`.
- Recipes with parameters use lowercase for parameter names: `secret filename`,
  `deploy machine`.

### Error Handling

- NixOS module evaluation catches configuration errors at build time.
  There is no runtime error handling in Nix configuration.
- In embedded shell scripts, failures propagate to systemd service status.
  Use guard clauses for expected conditions (e.g., "already connected").
- In the justfile, task chaining (e.g., `deploy: sync`) stops on
  the first failure.

### Documentation

- When modifying the `justfile`, always review `README.md` to ensure it still
  accurately describes the changed recipes. Update any outdated command
  descriptions, examples, or workflow instructions in the README to match.

### Commit Messages

- Sentence-case, starting with a verb: "Adds tailscale", "adds databases
  and justfile".
- No conventional-commits prefix (no `feat:`, `fix:`, etc.).
- Keep messages short and descriptive.
