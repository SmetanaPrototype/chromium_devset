#!/bin/bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="$HOME/.local/bin"
BASHRC="$HOME/.bashrc"

mkdir -p "$BIN_DIR"

shopt -s nullglob

scripts=("$REPO_DIR"/*.sh)
count=0

for script in "${scripts[@]}"; do
    cmd_name=$(basename "$script" .sh)

    [ "$cmd_name" = "install" ] && continue

    target="$BIN_DIR/$cmd_name"
    install -m 755 "$script" "$target"
    echo "✅ Command installed: $cmd_name"
    count=$((count + 1))
done

if [ "$count" -eq 0 ]; then
    echo "⚠️  No scripts found in $REPO_DIR" >&2
    exit 1
fi

# --- Ensure ~/.local/bin is on PATH via ~/.bashrc ---
PATH_LINE='export PATH="$HOME/.local/bin:$PATH"'

if ! grep -qxF "$PATH_LINE" "$BASHRC" 2>/dev/null; then
    {
        echo ''
        echo '# Added by chromium_devset/install.sh'
        echo "$PATH_LINE"
    } >> "$BASHRC"
    echo "✅ Added ~/.local/bin to PATH in $BASHRC"
    echo "   Run 'source ~/.bashrc' or open a new terminal to apply."
else
    echo "ℹ️  ~/.local/bin is already configured in $BASHRC"
fi
