# AGENTS.md

## Project Overview

NixOS infrastructure-as-code for a homelab Proxmox VM ("builder"). Pure Nix — no
application code, no TypeScript/JavaScript, no containers. Configuration is edited
locally, rsynced to the remote NixOS host, and rebuilt there.

Key technologies: NixOS, `just` (task runner), SOPS/age (secrets), Tailscale (VPN),
PocketBase, PostgreSQL.

## Repository Layout

```
configuration.nix          # NixOS root entry point — imports src/config.nix
src/
  config.nix               # Base host config (hostname, packages, journal) + import hub
  service/                 # Network/infra services (tailscale, etc.)
  backend/                 # Application backends (pocketbase, postgraphile)
  database/                # Database engines (pg, mysql, sqlite)
doc/                       # Notes and documentation
justfile                   # Deployment automation (just)
.sops.yaml                 # Secrets encryption config (age key)
```

Module import chain: `configuration.nix` -> `src/config.nix` -> `src/service/*.nix`.
Not all modules under `src/` are wired into the import chain — some are placeholders or
reference material (e.g., `postgraphile.nix` is comments only, `mysql.nix` and
`sqlite.nix` are empty).

## Build / Deploy / Test Commands

This project uses `just` as its task runner. All commands are defined in `justfile`.

```sh
# Full deploy: wipe remote /etc/nixos, rsync .nix files, rebuild
just deploy

# Individual steps:
just delete          # SSH rm -rf /etc/nixos/* on remote
just copy            # rsync only .nix files to remote /etc/nixos
just sync            # delete + copy
just build           # SSH nixos-rebuild switch on remote

# Edit an encrypted secret file with SOPS:
just secret <filename>
```

The remote host is aliased as `builder` (set by `NAME := "builder"` in justfile;
must match an entry in `~/.ssh/config`).

### Testing

There is no automated test suite. Testing is manual:
1. Make changes locally.
2. Deploy to a local NixOS VM (`just deploy`).
3. Verify the service works.
4. If it works, deploy to the production remote.

A successful `nixos-rebuild switch` (the `just build` step) is the primary
validation — NixOS module evaluation catches type errors, missing attributes,
and invalid option values at build time.

### Validating Changes Without Deploying

To check syntax and evaluate without building:
```sh
ssh builder "nix-instantiate --eval /etc/nixos/configuration.nix"
```

## Code Style Guidelines

### Language

All infrastructure code is Nix. Shell scripts appear only inside Nix heredoc strings
(`script = '' ... '';`) for systemd service definitions.

### File Naming

- **Files:** All lowercase, no separators. Short descriptive names: `pg.nix`,
  `tailnet.nix`, `pocketbase.nix`, `config.nix`.
- **Directories:** All lowercase, single English word describing the domain:
  `service/`, `backend/`, `database/`, `doc/`.

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
- Use relative paths for local modules (`./service/tailnet.nix`).
- Use angle-bracket paths only for nixpkgs built-in modules
  (`<nixpkgs/nixos/modules/...>`).
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

- This project uses the **traditional NixOS channel model** (no flakes).
  Do not introduce `flake.nix` without explicit instruction.
- No custom NixOS module options (`mkOption`) are defined — modules only
  consume upstream options via direct attribute assignment.
- No `let ... in` bindings, overlays, or custom packages are used currently.
  Keep things simple; only introduce these when genuinely needed.
- No `lib` usage currently. If needed, add `lib` to the module argument
  destructuring: `{ lib, config, pkgs, ... }:`.

### Justfile Conventions

- Variables use SCREAMING_CASE: `NAME`, `SOPS_KEY`.
- Recipe names use lowercase: `delete`, `copy`, `sync`, `deploy`, `build`.
- Recipes with parameters use lowercase for parameter names: `secret filename`.

### Error Handling

- NixOS module evaluation catches configuration errors at build time.
  There is no runtime error handling in Nix configuration.
- In embedded shell scripts, failures propagate to systemd service status.
  Use guard clauses for expected conditions (e.g., "already connected").
- In the justfile, task chaining (e.g., `deploy: sync build`) stops on
  the first failure.

### Commit Messages

- Sentence-case, starting with a verb: "Adds tailscale", "adds databases
  and justfile".
- No conventional-commits prefix (no `feat:`, `fix:`, etc.).
- Keep messages short and descriptive.
