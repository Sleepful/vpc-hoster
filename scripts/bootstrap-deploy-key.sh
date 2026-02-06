#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Bootstrap builder -> target SSH deploy access using one shared builder key.

Usage:
  ./scripts/bootstrap-deploy-key.sh \
    --target root@<target-ip> \
    --deploy-host house \
    --machine house

Options:
  --target <ssh-target>        Required. Current reachable target (for bootstrap),
                               usually root@<ip>.
  --deploy-host <host>         Hostname/address builder should use later for deploy.
                               Default: host part from --target.
  --machine <name>             NixOS flake machine name for deploy command hint.
                               Default: house.
  --target-user <user>         Remote deploy user (must have sudo/NixOS rights).
                               Default: jose.
  --builder <ssh-host>         Builder SSH target from your local machine.
                               Default: builder.
  --key-path <path>            Private key path on builder.
                               Default: /root/.ssh/id_ed25519_deploy
  --key-comment <comment>      SSH key comment used when creating key.
                               Default: builder-shared-deploy
  --no-seed-known-hosts        Skip writing target host key into builder known_hosts.
  -h, --help                   Show this help.

Notes:
  - Idempotent: safe to re-run.
  - This script does not require a static builder IP.
  - Host key seeding is best-effort; declarative knownHosts in Nix is preferred.
EOF
}

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Missing required command: $cmd" >&2
    exit 1
  fi
}

strip_user_host() {
  local input="$1"
  local host="$input"

  if [[ "$host" == *@* ]]; then
    host="${host#*@}"
  fi

  # Drop :port suffix for plain host:port forms.
  if [[ "$host" == *:* && "$host" != \[*\] ]]; then
    host="${host%%:*}"
  fi

  echo "$host"
}

TARGET_BOOTSTRAP=""
DEPLOY_HOST=""
MACHINE="house"
TARGET_USER="jose"
BUILDER_HOST="builder"
KEY_PATH="/root/.ssh/id_ed25519_deploy"
KEY_COMMENT="builder-shared-deploy"
SEED_KNOWN_HOSTS="yes"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)
      TARGET_BOOTSTRAP="$2"
      shift 2
      ;;
    --deploy-host)
      DEPLOY_HOST="$2"
      shift 2
      ;;
    --machine)
      MACHINE="$2"
      shift 2
      ;;
    --target-user)
      TARGET_USER="$2"
      shift 2
      ;;
    --builder)
      BUILDER_HOST="$2"
      shift 2
      ;;
    --key-path)
      KEY_PATH="$2"
      shift 2
      ;;
    --key-comment)
      KEY_COMMENT="$2"
      shift 2
      ;;
    --no-seed-known-hosts)
      SEED_KNOWN_HOSTS="no"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$TARGET_BOOTSTRAP" ]]; then
  echo "Missing required option: --target" >&2
  usage
  exit 1
fi

require_cmd ssh
require_cmd base64

TARGET_ADDR="$(strip_user_host "$TARGET_BOOTSTRAP")"
if [[ -z "$DEPLOY_HOST" ]]; then
  DEPLOY_HOST="$TARGET_ADDR"
fi

echo "==> Ensuring shared deploy key exists on builder: $KEY_PATH"
ssh "$BUILDER_HOST" "set -eu; install -d -m 700 /root/.ssh; if [ ! -f '$KEY_PATH' ]; then ssh-keygen -t ed25519 -N '' -f '$KEY_PATH' -C '$KEY_COMMENT'; fi; chmod 600 '$KEY_PATH'; chmod 644 '$KEY_PATH.pub'"

BUILDER_PUBKEY="$(ssh "$BUILDER_HOST" "cat '$KEY_PATH.pub'")"
if [[ -z "$BUILDER_PUBKEY" ]]; then
  echo "Failed to read builder public key from $KEY_PATH.pub" >&2
  exit 1
fi

if [[ "$SEED_KNOWN_HOSTS" == "yes" ]]; then
  echo "==> Seeding builder known_hosts for target: $TARGET_ADDR"
  ssh "$BUILDER_HOST" "set -eu; install -d -m 700 /root/.ssh; touch /root/.ssh/known_hosts; chmod 600 /root/.ssh/known_hosts"

  HOST_KEY_LINE="$(ssh "$BUILDER_HOST" "ssh-keyscan -t ed25519 '$TARGET_ADDR' 2>/dev/null | sed -n '1p'")"
  if [[ -n "$HOST_KEY_LINE" ]]; then
    HOST_KEY_B64="$(printf '%s' "$HOST_KEY_LINE" | base64)"
    ssh "$BUILDER_HOST" "set -eu; line=\$(printf '%s' '$HOST_KEY_B64' | base64 -d); ssh-keygen -F '$TARGET_ADDR' -f /root/.ssh/known_hosts >/dev/null || printf '%s\n' \"\$line\" >> /root/.ssh/known_hosts"

    if [[ "$DEPLOY_HOST" != "$TARGET_ADDR" ]]; then
      HOST_ALIAS_LINE="${HOST_KEY_LINE/$TARGET_ADDR/$DEPLOY_HOST}"
      HOST_ALIAS_B64="$(printf '%s' "$HOST_ALIAS_LINE" | base64)"
      ssh "$BUILDER_HOST" "set -eu; line=\$(printf '%s' '$HOST_ALIAS_B64' | base64 -d); ssh-keygen -F '$DEPLOY_HOST' -f /root/.ssh/known_hosts >/dev/null || printf '%s\n' \"\$line\" >> /root/.ssh/known_hosts"
    fi
  else
    echo "WARN: Could not read host key via ssh-keyscan from builder for $TARGET_ADDR" >&2
    echo "WARN: Keep declarative programs.ssh.knownHosts in Nix for this host." >&2
  fi
fi

echo "==> Installing builder public key on $TARGET_BOOTSTRAP for user $TARGET_USER"
PUBKEY_B64="$(printf '%s' "$BUILDER_PUBKEY" | base64)"

if ! ssh "$TARGET_BOOTSTRAP" "id '$TARGET_USER' >/dev/null 2>&1"; then
  echo "Target user not found: $TARGET_USER" >&2
  if [[ "$TARGET_USER" != "root" ]]; then
    echo "Tip: bootstrap root first, deploy once, then bootstrap $TARGET_USER." >&2
    echo "  just bootstrap-key-root $MACHINE $TARGET_BOOTSTRAP" >&2
    echo "  just deploy-remote-to-bootstrap $MACHINE $TARGET_ADDR" >&2
    echo "  just bootstrap-key $MACHINE $TARGET_BOOTSTRAP" >&2
  fi
  exit 1
fi

ssh "$TARGET_BOOTSTRAP" "set -eu; user='$TARGET_USER'; home=\$(getent passwd \"\$user\" | cut -d: -f6); if [ -z \"\$home\" ]; then home=/home/\$user; fi; group=\$(id -gn \"\$user\"); install -d -m 700 -o \"\$user\" -g \"\$group\" \"\$home/.ssh\"; touch \"\$home/.ssh/authorized_keys\"; chown \"\$user:\$group\" \"\$home/.ssh/authorized_keys\"; chmod 600 \"\$home/.ssh/authorized_keys\"; key=\$(printf '%s' '$PUBKEY_B64' | base64 -d); grep -qxF \"\$key\" \"\$home/.ssh/authorized_keys\" || printf '%s\n' \"\$key\" >> \"\$home/.ssh/authorized_keys\""

echo "==> Verifying builder can SSH as $TARGET_USER to $DEPLOY_HOST using deploy key"
VERIFY_HOST="$DEPLOY_HOST"
if ! ssh "$BUILDER_HOST" "ssh -o BatchMode=yes -o IdentitiesOnly=yes -i '$KEY_PATH' '$TARGET_USER@$DEPLOY_HOST' true"; then
  if [[ "$DEPLOY_HOST" != "$TARGET_ADDR" ]]; then
    echo "WARN: Verification via deploy-host '$DEPLOY_HOST' failed; retrying via '$TARGET_ADDR'." >&2
    ssh "$BUILDER_HOST" "ssh -o BatchMode=yes -o IdentitiesOnly=yes -i '$KEY_PATH' '$TARGET_USER@$TARGET_ADDR' true"
    VERIFY_HOST="$TARGET_ADDR"
    echo "WARN: '$DEPLOY_HOST' may not resolve on builder yet. Deploy builder config before using deploy-host aliases." >&2
  else
    echo "ERROR: Builder SSH verification failed for '$TARGET_USER@$DEPLOY_HOST'." >&2
    exit 1
  fi
fi

echo
echo "Bootstrap complete."
echo
echo "Recommended next steps (from repo root):"
echo "  1) just deploy"
if [[ "$TARGET_USER" == "root" ]]; then
  if [[ "$VERIFY_HOST" == "$DEPLOY_HOST" ]]; then
    echo "  2) just deploy-remote-bootstrap $MACHINE"
    echo "  3) just bootstrap-key $MACHINE $TARGET_BOOTSTRAP"
    echo "  4) just deploy-remote $MACHINE"
  else
    echo "  2) just deploy-remote-to-bootstrap $MACHINE $TARGET_ADDR"
    echo "  3) just bootstrap-key $MACHINE $TARGET_BOOTSTRAP"
    echo "  4) just deploy-remote $MACHINE"
    echo "     (use deploy-remote-to until '$DEPLOY_HOST' resolves on builder)"
  fi
else
  if [[ "$VERIFY_HOST" == "$DEPLOY_HOST" ]]; then
    echo "  2) just deploy-remote $MACHINE"
  else
    echo "  2) just deploy-remote-to $MACHINE $TARGET_ADDR"
    echo "     (run deploy-remote after '$DEPLOY_HOST' resolves on builder)"
  fi
fi

echo
echo "Done."
