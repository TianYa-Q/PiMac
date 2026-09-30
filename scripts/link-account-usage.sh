#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
source="$root/extensions/account-usage"
agent="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}"
target="$agent/extensions/account-usage"
mkdir -p "$agent/extensions"
if [ -L "$target" ] && [ "$(readlink "$target")" = "$source" ]; then
  printf 'Already linked: %s\n' "$target"
  exit 0
fi
if [ -e "$target" ] || [ -L "$target" ]; then
  printf 'Refusing to overwrite %s. Back up/remove the old installation first.\n' "$target" >&2
  exit 1
fi
ln -s "$source" "$target"
printf 'Linked %s -> %s\nRestart Pi / reconnect Pi Mac sessions to load changes.\n' "$target" "$source"
