#!/bin/bash
set -e

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="$HOME/.local/bin"
PREFIX="smet-"

mkdir -p "$BIN_DIR"

for script in "$REPO_DIR"/Bash_set/*.sh; do
    [ -f "$script" ] || continue
    base=$(basename "$script" .sh)
    cmd_name="${PREFIX}${base//_/-}"
    target="$BIN_DIR/$cmd_name"
    
    ln -sf "$script" "$target"
    echo "✅ Command installed: $cmd_name"
done
