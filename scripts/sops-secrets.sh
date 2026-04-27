#!/usr/bin/env bash
set -euo pipefail

SOPS_FILE="${1:-}"
COMMAND="${2:-}"
KEY="${3:-}"
VALUE="${4:-}"

usage() {
  cat <<'EOF'
Usage: sops-secrets <file> <command> [args]

Commands:
  set <key> <value>     Set or update a secret value
  get <key>             Get a secret value (prints to stdout)
  delete <key>          Delete a secret key
  list                  List all secret keys

Examples:
  sops-secrets secrets/house/core.yaml set my_secret "supersecret"
  sops-secrets secrets/house/core.yaml get my_secret
  sops-secrets secrets/house/core.yaml delete old_secret
  sops-secrets secrets/house/core.yaml list
EOF
  exit 1
}

if [[ -z "$SOPS_FILE" || -z "$COMMAND" ]]; then
  usage
fi

if [[ ! -f "$SOPS_FILE" ]]; then
  echo "Error: File not found: $SOPS_FILE" >&2
  exit 1
fi

case "$COMMAND" in
  set)
    if [[ -z "$KEY" || -z "$VALUE" ]]; then
      echo "Error: set requires key and value" >&2
      usage
    fi
    # Escape value for JSON string
    json_value=$(printf '%s' "$VALUE" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()), end="")')
    sops --set "[\"$KEY\"] $json_value" "$SOPS_FILE"
    echo "Set $KEY in $SOPS_FILE"
    ;;

  get)
    if [[ -z "$KEY" ]]; then
      echo "Error: get requires key" >&2
      usage
    fi
    # Safety gate: refuse non-interactive execution to prevent agent output leaks
    if [[ ! -t 0 ]]; then
      echo "Error: 'get' requires an interactive terminal (stdin is not a TTY)" >&2
      echo "Use 'list' to verify key existence, or run interactively." >&2
      exit 1
    fi
    sops -d --extract "[\"$KEY\"]" "$SOPS_FILE"
    ;;

  delete)
    if [[ -z "$KEY" ]]; then
      echo "Error: delete requires key" >&2
      usage
    fi
    # Decrypt to stdout, filter out key, re-encrypt from stdin
    # Uses Python to modify YAML in memory (no disk writes of plaintext)
    sops -d "$SOPS_FILE" | python3 -c "
import sys, yaml
data = yaml.safe_load(sys.stdin)
if '$KEY' in data:
    del data['$KEY']
    yaml.dump(data, sys.stdout, default_flow_style=False, sort_keys=False)
else:
    yaml.dump(data, sys.stdout, default_flow_style=False, sort_keys=False)
" | sops -e /dev/stdin > "$SOPS_FILE.tmp"
    mv "$SOPS_FILE.tmp" "$SOPS_FILE"
    echo "Deleted $KEY from $SOPS_FILE (if it existed)"
    ;;

  list)
    sops -d "$SOPS_FILE" | python3 -c "
import sys, yaml
data = yaml.safe_load(sys.stdin)
if data:
    for key in data.keys():
        print(key)
"
    ;;

  *)
    echo "Error: Unknown command: $COMMAND" >&2
    usage
    ;;
esac
