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
- **house** — Hetzner VPS running mail, web services, monitoring, and more.
- **hoster** — Hetzner VPS (minimal/bootstrap configuration).

## Repository Layout

```
flake.nix                          # Flake entry point — declares inputs + nixosConfigurations
flake.lock                         # Pinned nixpkgs revision (generated)
justfile                           # Deployment automation (just)
.sops.yaml                         # Secrets encryption config (age key)
.gitmodules                        # Declares the private submodule
private/                           # Git submodule — real identifiers (domains, IPs, keys)
  identifiers/
    default.nix                    # Overrides shared/identifiers placeholder values
secrets/
  builder/
    core.yaml                      # SOPS-encrypted secrets for builder
  house/
    core.yaml                      # SOPS-encrypted secrets for house
scripts/
  bootstrap-deploy-key.sh          # Sets up SSH deploy key on a target machine
docs/                              # Architecture docs (e.g., media-pipeline.md)
shared/
  base.nix                         # Common config shared by all machines
  options/
    identifiers.nix                # Custom option declarations (mkOption) for identifiers
  identifiers/
    default.nix                    # Placeholder identifier values (overridden by private/)
machines/
  <machine>/
    configuration.nix              # NixOS root entry point
    hardware-configuration.nix     # Hardware scan output (builder, house only)
    src/
      config.nix                   # Machine-specific config + import hub for services
      service/                     # One .nix file (or directory module) per service
      backend/                     # Application backends (builder only)
      database/                    # Database engines (builder only)
      data/                        # Static data files (house only)
```

### Module Import Chain

`flake.nix` -> `machines/<machine>/configuration.nix` -> `shared/base.nix` +
`src/config.nix` -> `src/service/*.nix`.

Note: builder uses an extra `imports.nix` shim between `configuration.nix` and the
rest (historical artifact from bootstrap). House and hoster import directly.

Not all files under `src/` are wired into the import chain — some are placeholders
or reference material (e.g., `postgraphile.nix` is comments only, `mysql.nix` and
`sqlite.nix` are empty).

### Identifiers System (Private Overlay)

Shared configuration values (domains, IPs, SSH keys, email addresses, subdomains)
are managed through a three-layer system:

1. **Option declarations** — `shared/options/identifiers.nix` defines
   `homelab.identifiers.*` options using `mkOption`.
2. **Placeholder defaults** — `shared/identifiers/default.nix` provides
   `lib.mkDefault` placeholder values (e.g., `example.com`).
3. **Private overrides** — `private/identifiers/default.nix` (git submodule)
   provides real values. Loaded conditionally via `lib.optional
   (builtins.pathExists ...)` in `shared/base.nix`.

Access identifiers in modules via:
```nix
{ config, ... }:
let ids = config.homelab.identifiers; in
{
  # ids.domain.root, ids.hosts.house.ipv4, ids.subdomains.grafana, etc.
}
```

**Gotcha:** The repo builds and evaluates even without the `private/` submodule
(placeholders are valid Nix). But deployed machines will have dummy values.
Always ensure the submodule is initialized: `git submodule update --init`.

### Secrets Organization

Secrets use SOPS with age encryption. Per-machine encrypted files live in
`secrets/<machine>/core.yaml`. Each machine has a dedicated `src/service/secrets.nix`
that:
- Sets `sops.defaultSopsFile` pointing to the machine's `core.yaml`
- Configures `sops.age.sshKeyPaths` (machine's SSH host key decrypts at boot)
- Declares individual `sops.secrets.*` entries
- Defines `sops.templates.*` for composed secret files (env files, configs)

`.sops.yaml` at the repo root lists the age public keys for all machines and the
macOS workstation, so any of them can encrypt/decrypt.

## Build / Deploy / Test Commands

All commands are defined in `justfile`. Configuration is edited on macOS, rsynced
to the builder machine, and rebuilt there.

### Core Deployment

```sh
just deploy                  # Deploy builder — rsync + nixos-rebuild switch
just deploy-remote house     # Deploy house — builder builds and pushes via SSH
just check                   # Validate flake eval (builder, default)
just check house             # Validate flake eval for house
just syntax                  # Local syntax check (macOS, no SSH). Alias: just s
```

### Flake & Store Maintenance

```sh
just lock                    # Update flake lockfile (nix flake update nixpkgs)
just gc                      # Garbage-collect builder's Nix store
just gc house                # Garbage-collect house's Nix store
just disk                    # Show builder disk/inode usage
```

### Secrets

```sh
just secret secrets/house/core.yaml    # Edit encrypted secrets file
just age-key                           # Derive age public key from machine SSH host key
just hash-bcrypt                       # Generate bcrypt hash locally
just hash-bcrypt-house                 # Generate bcrypt hash on house
```

### Bootstrap Recipes

```sh
just bootstrap                              # Pull config from a fresh builder install
just deploy-remote-bootstrap house          # First deploy when deploy user doesn't exist
just deploy-remote-to house 1.2.3.4         # Deploy to explicit IP
just bootstrap-key house 1.2.3.4            # Set up deploy SSH key on target
just bootstrap-key-root house 1.2.3.4       # Bootstrap key as root (first time)
```

### Local Deploy (No Builder Hop)

```sh
just check-local house                       # Evaluate config locally
just deploy-local-house                      # Deploy house from macOS directly
just deploy-local-house-bootstrap root@house # Bootstrap deploy from macOS
```

### Submodule (private/)

```sh
just submodule-status           # Show uncommitted changes in private/
just submodule-diff             # Show diff in private/
just submodule-commit-all "msg" # Stage all, commit, push private/
```

### Testing

For Nix configuration, testing is manual — a successful `nixos-rebuild switch`
is the primary validation (NixOS module evaluation catches type errors, missing
attributes, and invalid option values at build time):
1. Make changes locally.
2. Run `just syntax` for quick local syntax check.
3. Deploy to builder VM (`just deploy`).
4. Verify the service works.
5. If it works, deploy to the production remote (`just deploy-remote house`).

The qBittorrent companion scripts (Python) have a pytest suite:
```sh
just test                    # Run qBittorrent script tests (local, no SSH)
```
See `machines/builder/src/service/qbittorrent/tests/` for the test files.

**Deployment is the user's responsibility.** Do not run `just deploy` or
`just deploy-remote` unless the user explicitly asks. Prepare changes, run
`just syntax` or `just check`, and let the user decide when to deploy.

## Procedures

### Adding a New Service to an Existing Machine

1. Create `machines/<machine>/src/service/<servicename>.nix` using the standard
   module pattern.
2. Add the import to `machines/<machine>/src/config.nix` in the `imports` list.
3. If the service needs secrets, add `sops.secrets.*` entries to
   `machines/<machine>/src/service/secrets.nix`, and add the key to
   `secrets/<machine>/core.yaml` via `just secret secrets/<machine>/core.yaml`.
4. If the service needs a subdomain (house only):
   - Add the subdomain to `shared/options/identifiers.nix` (mkOption).
   - Add a placeholder default in `shared/identifiers/default.nix`.
   - Add the real value in `private/identifiers/default.nix`.
   - Add the subdomain to the ACME `extraDomainNames` list in
     `machines/house/src/service/web.nix`.
   - Add an nginx virtualHost in `web.nix`.
5. If the service runs on builder and has a web UI, add a dashboard link and
   redirect in `machines/builder/src/service/web.nix`.
6. If the service needs a firewall port, add it to the service file or the
   machine's firewall config.
7. Deploy and verify: `just deploy` (builder) or `just deploy-remote house`.

### Adding a New Machine

1. Add a `nixosConfigurations.<name>` entry in `flake.nix` with the appropriate
   modules list (include `sops-nix.nixosModules.sops`).
2. Create `machines/<name>/configuration.nix` importing `shared/base.nix` and
   `./src/config.nix`.
3. Create `machines/<name>/src/config.nix` with hostname, stateVersion, and
   imports list.
4. If the machine needs secrets, create `secrets/<name>/core.yaml` and a
   `src/service/secrets.nix`.
5. Add the machine's age public key to `.sops.yaml` and re-encrypt.
6. Add justfile recipes if the machine has a non-standard deploy path.

### Adding a New Secret

1. Declare the secret in `machines/<machine>/src/service/secrets.nix`:
   `sops.secrets.<key> = {};` (add `owner`, `restartUnits` as needed).
2. If the secret is consumed as an environment variable or config file, create
   a `sops.templates.<name>` using `config.sops.placeholder.<key>`.
3. Add the actual value: `just secret secrets/<machine>/core.yaml`.
4. Reference in service files as `config.sops.secrets.<key>.path` (file path)
   or use the template path.

## Code Style Guidelines

### Language

All infrastructure code is Nix. Shell scripts appear inside Nix heredoc strings
(`script = '' ... '';`) for small systemd service definitions.

**Exception:** The qBittorrent companion services (upload, cleanup, category
registration) are standalone Python scripts in
`machines/builder/src/service/qbittorrent/`. They read configuration from
environment variables set by systemd, making them independently testable with
pytest. See the `tests/` subdirectory and `just test`.

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

- Only destructure the arguments you actually use (`config`, `pkgs`, `lib`,
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
  machine's `configuration.nix` or `imports.nix`.
- Custom NixOS module options are defined in `shared/options/identifiers.nix`
  for the identifier system. Service modules consume upstream options via
  direct attribute assignment.
- `let ... in` bindings are used where helpful (extracting `ids`, `sub`,
  helper functions like `fqdn`). No overlays or custom packages currently.
- `lib` is used in the identifiers modules (`lib.mkDefault`, `lib.mkOption`,
  `lib.optional`). Add `lib` to the module argument destructuring when needed.

### Justfile Conventions

- Variables use SCREAMING_CASE: `NAME`, `SOPS_KEY`, `REMOTE`.
- Recipe names use lowercase with hyphens for multi-word names:
  `deploy-remote`, `bootstrap-key`, `check-local`.
- Recipes with parameters use lowercase for parameter names: `secret filename`,
  `deploy-remote machine`.

### Error Handling

- NixOS module evaluation catches configuration errors at build time.
  There is no runtime error handling in Nix configuration.
- In embedded shell scripts, failures propagate to systemd service status.
  Use guard clauses for expected conditions (e.g., "already connected").
- In the qBittorrent Python scripts, errors are caught with try/except and
  logged — the scripts skip failed items and continue processing.
- In the justfile, task chaining (e.g., `deploy: sync`) stops on
  the first failure.

### Documentation

- When modifying the `justfile`, always review `README.md` to ensure it still
  accurately describes the changed recipes. Update any outdated command
  descriptions, examples, or workflow instructions in the README to match.
- When adding new files, directories, languages, or test suites to the repo,
  review `AGENTS.md` and update the relevant sections (Repository Layout,
  Language, Testing, Procedures, etc.) so they remain accurate.

### Commit Messages

- Sentence-case, starting with a verb: "Adds tailscale", "Fixes rclone config".
- No conventional-commits prefix (no `feat:`, `fix:`, etc.).
- Keep messages short and descriptive.

## Media Pipeline (Builder)

The builder runs a media download pipeline documented in `docs/media-pipeline.md`.
Key services: qBittorrent, Sonarr, Radarr, Prowlarr, rclone B2 mount, Jellyfin.

### Shared Media User

All media pipeline services (qBittorrent, Sonarr, Radarr, Jellyfin, Copyparty)
run as the `media` user. This enables Sonarr/Radarr to hard link (not copy)
completed downloads into their import directories (`/media/arr/tv/`, `/media/arr/movies/`).
Hard links require same user + same filesystem. Prowlarr is the exception — it
uses `DynamicUser = true` and does not accept custom user/group.

The `media` user and group are defined in `jellyfin.nix`.

### qBittorrent Category System

Downloads are organized by category into subdirectories under `completed/`:
- `tv-sonarr` category → `completed/tv/` → hard linked by Sonarr to `/media/arr/tv/` → B2 `tv/`
- `radarr` category → `completed/movies/` → hard linked by Radarr to `/media/arr/movies/` → B2 `movies/`
- `tv` category → `completed/tv/` → hard linked by upload script to `/media/arr/tv/` → B2 `tv/`
- `movie` category → `completed/movies/` → hard linked by upload script to `/media/arr/movies/` → B2 `movies/`
- Uncategorized → `completed/` → B2 `downloads/`

The `tv` and `movie` categories are for manually added torrents. The upload
script detects manual items (all files have `st_nlink == 1`, meaning
Sonarr/Radarr haven't touched them) and creates hard links to the import
directory. Arr-managed items (`st_nlink > 1`) are skipped.

After uploading, the upload script propagates `.uploaded` markers from the
import directory back to `completed/` items (by inode match), so the cleanup
timer can eventually remove them.

Categories are defined in the `categories` attrset in `qbittorrent/default.nix` and
registered via the qBittorrent API by `qbt-categories.service` on boot.

### qBittorrent Scripts (Python)

The three companion services (`qbt-categories`, `qbt-upload-b2`, `qbt-cleanup`)
are implemented as standalone Python scripts alongside the Nix module:

```
machines/builder/src/service/qbittorrent/
  default.nix          # NixOS module (systemd units, env vars, timers)
  categories.py        # Category registration via qBittorrent API
  upload.py            # Upload to B2 from import dirs and completed/
  cleanup.py           # Seeding lifecycle, hardlink removal, pruning
  tests/
    conftest.py        # Adds parent dir to sys.path
    test_categories.py
    test_upload.py
    test_cleanup.py
```

Scripts read all configuration from environment variables set by
`serviceConfig.Environment` in `default.nix`. Only `rclone` and `unar` use
subprocess — everything else (HTTP, JSON, filesystem, inode lookup) is Python
stdlib. Run `just test` to execute the pytest suite locally.

### Adding a New Download Category

1. Add an entry to the `categories` attrset in `qbittorrent/default.nix`:
   `"category-name" = "subdirectory";`
2. Everything else is derived automatically: tmpfiles rules, upload scan
   commands, cleanup scan commands, import directories, hard linking, marker
   propagation, and B2 upload paths.
3. For *arr categories: set the Category field when configuring the download
   client and set the root folder to `/media/arr/<subdirectory>`.
4. For manual categories: assign the category in qBittorrent when adding a
   torrent. The upload script will hard link files to `/media/arr/<subdirectory>/`
   and handle B2 upload automatically.

### Servarr Apps (Sonarr, Radarr, Prowlarr)

- NixOS modules only configure server-level settings (port, update mechanism)
  via environment variables (`APPNAME__SECTION__KEY`).
- Application-level config (download clients, indexers, root folders, quality
  profiles) is stored in SQLite and must be configured through the web UI.
- Sonarr/Radarr support `user`/`group` options — use the shared `media` user.
- Sonarr root folder: `/media/arr/tv`. Radarr root folder: `/media/arr/movies`.
- Prowlarr uses `DynamicUser = true` and does not accept custom user/group.

### Nix String Interpolation in Shell Scripts

When embedding bash in Nix heredoc strings (`script = '' ... '';`) and generating
shell commands from Nix attrsets (e.g., `builtins.mapAttrs`), avoid nesting
`'' ''` multiline strings — this causes parse errors. Instead, hoist the
generated strings into `let` bindings and interpolate the binding name:

```nix
# Bad — nested '' strings cause parser confusion
script = ''
  ${builtins.concatStringsSep "\n" (builtins.mapAttrs (n: v: ''
    echo "${n}"
  '') attrs)}
'';

# Good — pre-compute in let, interpolate the variable
script = let
  cmds = builtins.concatStringsSep "\n" (builtins.mapAttrs (n: v:
    "echo \"${n}\""
  ) attrs);
in ''
  ${cmds}
'';
```

For complex scripts, prefer standalone Python files over inline bash — see
the qBittorrent scripts for the pattern (`ExecStart` pointing to a `.py` file,
configuration via environment variables).

### Validation Levels

- `just syntax` — fast local check (`nix-instantiate --eval`), catches syntax
  errors but NOT option/type errors. Does not SSH anywhere.
- `just check` — full flake evaluation on builder via SSH. Catches option
  mismatches, missing attributes, type errors. Always run before deploying.
- `just deploy` — builds and switches. The ultimate validation.

### Systemd Design Patterns

- **Timer over path unit when files persist:** `DirectoryNotEmpty` re-triggers
  every time the service exits if the directory is still non-empty. Only use
  path units when the service empties the watched directory. If files stay
  (e.g., seeding downloads with `.uploaded` markers), use a timer instead.
- **Avoid multiple path units triggering the same service:** Simultaneous
  activation on boot hits systemd's default rate limit (5 starts in 10s).
  Prefer a single path unit with multiple `DirectoryNotEmpty` directives
  (NixOS `pathConfig` accepts a list), or use a timer.
- **Rate limit state survives `switch-to-configuration`:** If a unit hits
  `start-limit-hit`, `nixos-rebuild switch` does NOT reset the counter for
  unchanged units. Run `systemctl reset-failed <unit>` on the target machine
  before redeploying, or change the unit definition so NixOS regenerates it.

## Gotchas and Non-Obvious Requirements

- **`path:` prefix in flake references:** On builder, flake commands use
  `path:/etc/nixos#machine` not `.#machine`, because the code is rsynced to
  `/etc/nixos` — it's not a git repo there, so `path:` is required.
- **Private submodule must be initialized:** `git submodule update --init`.
  Without it the build still succeeds but uses placeholder identifiers.
- **Private submodule has its own git history:** Changes to `private/` must be
  committed and pushed separately. Use `just submodule-commit-all "msg"` or
  commit manually in `private/`.
- **SOPS re-encryption after key changes:** If you add a new machine's age key
  to `.sops.yaml`, you must re-encrypt all secret files so the new key can
  decrypt them: `just secret secrets/<machine>/core.yaml` (save without changes
  to re-encrypt with updated keys).
- **`system.stateVersion` must not change:** Each machine's `stateVersion` is
  set at first install. Never update it — it controls data migration behavior.
- **`sops.templates` for composed secrets:** When a service needs multiple
  secrets in one file (env file, config), use `sops.templates` with
  `config.sops.placeholder.*` interpolation. Don't concatenate secret file
  paths at runtime.
- **Builder `configuration.nix` is mostly boilerplate:** The real configuration
  lives in `imports.nix` -> `src/config.nix`. The `configuration.nix` retains
  NixOS installer scaffolding comments.
- **Deploy user vs root:** `deploy-remote` uses the `jose` deploy user with
  `--use-remote-sudo`. `deploy-remote-bootstrap` uses `root` directly —
  only for the first deploy before the deploy user exists.
- **Firewall defaults to on:** NixOS firewall is enabled. Services must
  explicitly open ports in their `.nix` file or the machine's firewall config.
  Tailscale interface (`tailscale0`) is trusted — services accessible over
  Tailscale without extra firewall rules.
