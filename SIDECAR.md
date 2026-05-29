# OpenCode Sidecar System (Secure Agent)

Secure execution environment for AI coding agents. Keeps production secrets on the host while allowing agents to run commands with redacted output.

## Repo Boundaries

Three separate git repos, each managing its own scope:

```
~/.cfg/ (bare git)              ~./config/opencode/ (git)          /path/to/project/ (git)
├── ~/.profile                  ├── opencode.json                  ├── .opencode/
├── ~/.bin/*                    ├── agents/                        │   ├── sidecar.py
├── ~/.config/nvim/*            ├── commands/                      │   ├── sidecar/handler.py
├── ~/.zshrc                    ├── skills/                        │   └── Dockerfile
└── ...                         ├── plugin/                        ├── scripts/
                                ├── .bin/  ← you are here          │   ├── run-tests
                                ├── tui.json                       │   └── run-privileged
                                └── ...                            ├── secrets.enc.yaml
                                                                   └── justfile
```

| Repo | Manages | Scope |
|------|---------|-------|
| `~/.cfg/` (dotfiles) | `~/.profile`, `~/.bin/*`, `~/.zshrc`, `~/.config/nvim/*` | Global system config |
| `~/.config/opencode/` | opencode config, skills, plugins, `.bin/` sidecar scripts | OpenCode-specific |
| Per-project repo | `.opencode/`, `scripts/run-*`, `secrets.enc.yaml`, `justfile` | Project-specific |

**Rule**: Never cross boundaries with `cfg add`. `~/.config/opencode/*` is its own repo.

## Architecture

```
Host (macOS)                          Container (Linux)
┌─────────────────┐                  ┌──────────────────┐
│ opencode-reload │──starts──>       │                  │
│ .opencode/      │                  │  opencode TUI    │
│   sidecar.py    │<──unix socket──> │  scripts/run-*   │
│   sidecar/      │                  │                  │
│     handler.py  │                  └──────────────────┘
│ secrets.enc.yaml│
└─────────────────┘
```

1. **Sidecar** (`sidecar.py`) — per-repo HTTP server on a Unix socket, loads the handler module
2. **Handler** (`handler.py`) — executes whitelisted commands with decrypted secrets, redacts output
3. **Client** (`scripts/run-tests`, `scripts/run-privileged`) — Python raw HTTP over Unix socket

### Security Layers

| Layer | Mechanism | Purpose |
|-------|-----------|---------|
| OpenCode permissions | `opencode.json` patterns (`allow`/`ask`) | Gate which scripts the agent can invoke |
| Sidecar whitelist | `ACTIONS` dict in `handler.py` | Only predefined commands get secrets |
| Output redaction | Secret value replacement with `█` | Agent never sees raw secret values |
| Tamper detection | `inspect.getsource()` self-test in handler | Crashes if logging of `env_for_child` is added |
| Cache TTL | 60s cache with auto-expiry | Limits window of decrypted secrets in memory |

### Container Filesystem Mounts

OpenCode stores three kinds of state on disk: configuration, data, and runtime state. The container gets each from a different source.

| Host path | Container mount | Source | Scope | Why |
|-----------|----------------|--------|-------|-----|
| `~/.config/opencode/` | `/root/.config/opencode/` | Host bind mount | Shared | Agents, skills, tools, plugins, permission rules. Read-mostly. No SQLite. Safe to share. |
| `~/.local/share/opencode/` | `/root/.local/share/opencode/` | Named Docker volume `opencode-secure-data` | Global | SQLite database (`opencode.db`), LSP binaries, logs, repos. Isolated from host filesystem to avoid NFS corruption. |
| `~/.local/state/opencode/` | `/root/.local/state/opencode/` | Named Docker volume `opencode-secure-state-<project>` | Per-project | Model preferences (`model.json`), session state (`session.json`), prompt history (`prompt-history.jsonl`). |

**Justification.** SQLite in WAL mode relies on `fcntl()` advisory locking, which is unreliable over NFS ([ref](https://www.sqlite.org/faq.html#q5)). Concurrent writers corrupt the database. Host bind mounts of `~/.local/share/opencode/` into the container route all database I/O through the host filesystem — if that filesystem is NFS, the database corrupts within minutes of concurrent use.

Named Docker volumes store data on the Docker Engine's local filesystem (typically `ext4` or `overlay2`). SQLite locking works correctly here, and `busy_timeout=5000` handles concurrent writers from multiple container sessions.

**Why state is per-project.** Prompt history lives in a single global file (`prompt-history.jsonl`) shared by all opencode instances. The file is append-mostly, but a periodic rewrite (trimming to 50 entries) destroys entries appended by concurrent writers. Per-project volumes isolate each project's prompt history, so concurrent `opencode-secure` sessions in different projects never collide. Restarting `opencode-secure` in the same project preserves history.

**Seed on first run.** On the first `opencode-secure` invocation:

- `auth.json` is copied from the host into the global data volume. This carries over stored API keys for all providers, then diverges from the host. Managing keys inside the container with `opencode auth login` persists to the volume.
- `model.json` and `session.json` are copied from the host into the per-project state volume. Model selections and session data then diverge independently from the host.

**Data volume is shared (not per-project).** All projects share one database volume and one set of stored API keys. The database is not corrupted by concurrent access because the filesystem is local. LSP and ripgrep binaries downloaded by one project are cached for all projects, avoiding redundant downloads.

**Limitations.**

- Concurrent `opencode-secure` sessions in the *same* project share a state volume — prompt-history rewrites still collide and may lose entries (cosmetic, not a crash).
- New state files added by future opencode releases (e.g. `state/prefs/new-feature.json`) start empty in the container and diverge from the host silently. No mechanism exists to detect or backfill these.
- `auth.json`, `model.json`, and `session.json` seed once. If the host updates these after the volume is seeded, the container won't pick up the changes.
- API keys stored in `auth.json` on the host but set via `--env-file .env.low` produce duplicate credentials. Prefer one mechanism: either env vars in `.env.low` or stored keys in `auth.json`, not both.
- The `opencode-secure-data` volume accumulates LSP binaries, logs, and snapshots indefinitely. No automatic pruning. Check size periodically: `docker system df -v | grep opencode-secure-data`.

**Cleanup.**

```bash
# Wipe the global data volume (database, LSP binaries, logs)
docker volume rm opencode-secure-data

# Wipe state for a specific project
docker volume rm opencode-secure-state-myproject

# List all secure-agent volumes
docker volume ls | grep opencode-secure
```

## File Layout

### Host scripts (`~/.config/opencode/.bin/`)

| File | Purpose |
|------|---------|
| `opencode-reload` | Start/restart per-repo sidecar |
| `opencode-secure` | Launch opencode in Docker |
| `opencode-shell` | Bash into Docker container |
| `opencode-scaffold` | Bootstrap a new repo with sidecar |
| `opencode/lib.sh` | Shared helpers (socket path, image name) |
| `opencode/templates/default/` | Scaffold template files |

### Per-repo files (added by `opencode-scaffold`)

| File | Purpose |
|------|---------|
| `.opencode/sidecar.py` | Per-repo sidecar: socket server, loads handler |
| `.opencode/sidecar/handler.py` | Action whitelist, sops decryption, output redaction |
| `.opencode/Dockerfile` | Node base + Python3 + sound players |
| `scripts/run-tests` | Client for whitelisted actions |
| `scripts/run-privileged` | Client for arbitrary commands with secrets |
| `scripts/run-ssh` | Client for SSH to remote servers via sidecar |
| `justfile` | sops-init, secrets-edit, env-low, build |
| `.envrc` | direnv config |
| `.sops.yaml` | Sops creation rules with age key |

Scripts in `scripts/` are on PATH inside the container. The agent invokes them directly:

```bash
run-tests test              # whitelisted action
run-privileged npm run dev  # arbitrary command with secrets
run-ssh server1 whoami      # SSH as restricted user
```

## Execution Levels

| Level | Mechanism | OpenCode Permission |
|-------|-----------|-------------------|
| Basic bash | Direct execution | `allow` |
| Whitelisted sidecar | `scripts/run-tests <action>` | `allow` |
| Privileged sidecar | `scripts/run-privileged <cmd>` | `ask` |

## Quick Reference

```bash
# Setup a new repo
cd /path/to/repo
opencode-scaffold
just sops-init           # Configure age key
just env-low             # Generate .env.low for direnv

# Start sidecar (host)
opencode-reload

# Launch opencode in Docker (host)
opencode-secure

# Or just use the sidecar without Docker
opencode                 # Regular opencode, sidecar runs alongside

# Check sidecar status
opencode-status

# Update templates after editing
opencode-scaffold --force
```

## Socket Path

Each repo gets a unique socket: `/tmp/opencode-<sha256-hash-of-pwd>.sock`

```bash
# Show current socket path
opencode-socket

# Check if sidecar is running
opencode-status
```

## Adding Sidecar Actions

Edit `.opencode/sidecar/handler.py` in your repo:

```python
ACTIONS = {
    "test": {"command": ["pytest", "-x"], "description": "Fast unit tests"},
    "lint": {"command": ["eslint", "."], "description": "Lint"},
}
```

Then restart: `opencode-reload`

## Secrets Management

Four files, two flows:

| File | What | Who sees it | How it's created |
|------|------|-------------|------------------|
| `secrets.enc.yaml` | Production secrets (encrypted) | Nobody — sidecar decrypts in-memory | `just secrets-edit` |
| `secrets-dev.enc.yaml` | Dev/test secrets (encrypted) | Nobody — auto-decrypted by `just env-low` | `just secrets-dev-edit` |
| `.env.low` | Dev secrets (plaintext) | Docker container via `--env-file` | `just env-low` |
| `.envrc` | direnv functions (not secrets) | Your host shell | `opencode-scaffold` |

**Dev flow** (no sidecar, no agent involvement):
```
secrets-dev.enc.yaml  →  just env-low  →  .env.low  →  docker --env-file  →  container env vars
```

**Production flow** (sidecar, agent never sees plaintext):
```
secrets.enc.yaml  →  handler.py decrypts  →  runs command with env  →  redacts output  →  agent gets █
```

**Host shell flow** (manual opt-in):
```bash
opencode-sdev npm run test               # run with dev secrets
opencode-sprod npm run deploy            # run with production secrets
opencode-sdev -- python manage.py migrate
```

Uses `opencode-sprod`/`opencode-sdev` scripts in `.bin/`. Aliased in `.profile`. Secrets live only for the command's lifetime.

`.env.low` is gitignored (plaintext dev secrets). `secrets*.enc.yaml` can be committed (encrypted). `.envrc` is committed (helper functions, no secrets).

## Host Services Pattern

Services run on the host, the agent in Docker reaches them at `host.docker.internal:<port>`. The container gets `--add-host host.docker.internal:host-gateway` so this resolves to the host's IP.

```bash
# On the host (or via agent invoking the sidecar):
npm run dev          # service starts on localhost:3000

# Agent inside Docker reaches it at:
host.docker.internal:3000
```

**Agent-initiated services**: Add a `bash` action request via `scripts/run-privileged`. The sidecar runs the command on the host with decrypted secrets, and the agent then queries the service at `host.docker.internal:<port>`.

**Why this works**: The sidecar runs on the host, so any command executed by the handler runs on the host too. The agent never sees the secrets; it only gets redacted output from the startup command.

## SSH Access

The agent can SSH to remote servers without ever touching an SSH key. The handler uses your existing host keys and enforces a restricted user account.

```bash
# Agent runs this inside the container:
scripts/run-ssh server1 tail -50 /var/log/app
scripts/run-ssh server1 journalctl -u nginx --since "10 minutes ago"
```

The handler constructs `ssh -l debug server1 <command>` and runs it using your host SSH keys. The agent specifies host and command. The handler adds the user and key. The agent never sees either.

**Security**: The `debug` user on remote servers must have no sudo, no `su`, and no ability to switch users. If `debug` can escalate, the agent can too. Your personal keys and accounts are never exposed.

**One-time setup per server**: Create the restricted user and authorize your key. The handler reuses your existing SSH keys — no new key pair needed.

```bash
# On each remote server:
sudo useradd -m debug
sudo su - debug
mkdir -p ~/.ssh
echo "ssh-ed25519 AAAAC3... your-existing-key" >> ~/.ssh/authorized_keys
chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys

# Lock down sudo:
sudo bash -c 'echo "debug ALL=(ALL) !ALL" > /etc/sudoers.d/debug'

# Test from your host:
ssh -l debug server1 whoami   # should print "debug"
ssh -l debug server1 sudo whoami  # should fail
```

**Configuration**: Override the SSH user per repo by editing `handler.py`:

```python
ACTIONS = {
    "ssh": {
        "user": "debug",       # change to your restricted user
        "description": "SSH to remote servers"
    },
}

## Adding a New Secret

The agent never sees secrets in plaintext. When it needs a new API key, it asks. You add it. The sidecar decrypts.

```
[start]: agent working in opencode-secure

[agent]: discovers need for new key

  integrating payment service
    needs PAYMENT_API_KEY
    cannot read secrets.enc.yaml
    [blocked]

[agent]: tells user what's needed

  "Add PAYMENT_API_KEY to secrets.enc.yaml"
  [waiting] ◂── cannot proceed without it

[user]: on host, outside container

  add key to encrypted secrets
    just secrets-edit
    user adds PAYMENT_API_KEY
    sops re-encrypts
    [ok]

  restart sidecar
    opencode-reload
    loads handler with updated secrets
    [ready] ◂── Sidecar listening

[user]: tells agent to continue

[agent]: resumes, runs privileged command

  scripts/run-privileged npm run test:payment

  sidecar receives request
    decrypts secrets.enc.yaml
      PAYMENT_API_KEY=sk_live_abc123
      [ok]
    runs npm run test:payment
      env includes PAYMENT_API_KEY
      [ok]
    redacts output
      sk_live_abc123 ──► █
      [safe]

[agent]: output
    tests pass
    [ok] ◂── integration works

[end]: key added, tests passing
```

The agent asks, you add, the sidecar decrypts. Secrets never cross the socket boundary in plaintext.

## Container Notes

**Can the agent run HTTP servers inside the container?**

Yes — `node server.js`, `npm run dev`, etc. all work. The agent can reach them at `localhost:<port>` since it shares the container's network. The host cannot reach them (no `-p` port publishing in `opencode-secure`). If you need the service accessible from your host browser, start it on the host via `run-privileged` and use the [host services pattern](#host-services-pattern) instead.

**Can the agent install npm packages?**

`npm install` within `/workspace` persists across sessions (the workspace is a mounted host volume). `npm install -g` (global) works but evapourates when the container exits (`--rm`). The container runs as root, so a malicious `postinstall` script could modify workspace files. The host is safe. Docker is the perimeter.

**Does the container cache survive restarts?**

No. `docker run --rm` means every restart is a fresh container from the image. Any filesystem changes outside `/workspace` or the mounted config/state directories are gone.
