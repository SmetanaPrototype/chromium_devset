#!/bin/bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="$HOME/.local/bin"

mkdir -p "$BIN_DIR"

shopt -s nullglob

scripts=("$REPO_DIR"/*.sh)
count=0

for script in "${scripts[@]}"; do
    cmd_name=$(basename "$script" .sh)

    [ "$cmd_name" = "install" ] && continue

    chmod +x "$script"

    target="$BIN_DIR/$cmd_name"

    ln -sf "$script" "$target"
    echo "✅ Command installed: $cmd_name"
    count=$((count + 1))
done

if [ "$count" -eq 0 ]; then
    echo "⚠️  No scripts found in $REPO_DIR" >&2
    exit 1
fi
