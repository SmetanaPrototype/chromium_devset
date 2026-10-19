#!/bin/bash
set -e -o pipefail

address=$1
penguin_name=$2

usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") <address> <penguin_name> [flag] [paths...]

Modes:
  (no flag)     Interactive shell into the penguin container
  -c  <files>   Copy local file(s) to penguin's home
  -cr <dirs>    Copy local folder(s) to penguin's home
  -e  <files>   Extract file(s) from penguin's home to cwd
  -er <dirs>    Extract folder(s) from penguin's home to cwd

Paths are interpreted relative to the penguin user's home (~) on the
remote side, and preserved locally on extraction.

Examples:
  penguinin 192.168.0.100 user04 -cr wine/dlls
    uploads local wine/dlls into ~/wine/dlls in the penguin

  penguinin 192.168.0.100 user04 -e wine/dlls/foo.dll
    downloads ~/wine/dlls/foo.dll to ./wine/dlls/foo.dll
EOF
  exit 1
}

[[ -z "$address" || -z "$penguin_name" ]] && usage

flag=""
paths=()

if [[ $# -ge 3 && "$3" == -* ]]; then
  flag="$3"
  paths=("${@:4}")
fi

if [[ -n "$flag" ]]; then
  case "$flag" in
    -c|-cr|-e|-er)
      [[ ${#paths[@]} -gt 0 ]] || { echo "Flag $flag requires at least one path argument." >&2; usage; }
      ;;
    *) echo "Unknown flag: $flag" >&2; usage ;;
  esac
fi

read -rsp "Host password: " password
echo

SSH_BASE=(sshpass -p "$password" ssh -o StrictHostKeyChecking=accept-new)

penguin_cmd() {
  local cmd="$1"
  local escaped_cmd
  escaped_cmd=$(printf '%s' "$cmd" | sed "s/'/'\\\\''/g")
  printf "lxc exec penguin -- su -l %s -c '%s'\n" \
    "$penguin_name" "$escaped_cmd"
}

# Convert a local path argument to a path relative to the penguin's home.
#   - absolute paths -> basename (put into ~)
#   - relative paths -> as-is (after stripping leading ./)
penguin_rel_path() {
  local p="$1"
  if [[ "$p" == /* ]]; then
    basename "$p"
  else
    while [[ "$p" == ./* ]]; do
      p="${p#./}"
    done
    echo "$p"
  fi
}

case "$flag" in
  "")
    # Interactive session
    { sleep 5; printf 'lxc exec penguin -- su -l %s\n' "$penguin_name"; cat; } \
      | "${SSH_BASE[@]}" -tt root@"$address" 'vmc start termina'
    ;;

  -c)
    # Upload multiple files
    for path in "${paths[@]}"; do
      [[ -f "$path" ]] || { echo "Not a regular file: $path" >&2; exit 1; }
      rel=$(penguin_rel_path "$path")
      echo ">>> Uploading file: $path -> ~/$rel" >&2
      {
        penguin_cmd "mkdir -p \"\$(dirname \"$rel\")\" && base64 -d > \"$rel\""
        base64 "$path"
      } | "${SSH_BASE[@]}" -T root@"$address" 'vmc start termina' > /dev/null
    done
    ;;

  -cr)
    # Upload multiple folders
    for path in "${paths[@]}"; do
      [[ -d "$path" ]] || { echo "Not a directory: $path" >&2; exit 1; }
      rel=$(penguin_rel_path "$path")
      echo ">>> Uploading directory: $path -> ~/$rel" >&2
      {
        penguin_cmd "mkdir -p \"$rel\" && base64 -d | tar xzf - -C \"$rel\""
        tar czf - -C "$path" . | base64
      } | "${SSH_BASE[@]}" -T root@"$address" 'vmc start termina' > /dev/null
    done
    ;;

  -e)
    # Download multiple files
    for path in "${paths[@]}"; do
      target="$path"
      echo ">>> Downloading file: ~/$path -> ./$target" >&2
      mkdir -p "$(dirname "$target")"
      {
        penguin_cmd "echo '---BEGIN---'; base64 -w 76 \"$path\"; echo '---END---'"
        echo "exit"
      } | "${SSH_BASE[@]}" -T root@"$address" 'vmc start termina' | \
        sed -n '/---BEGIN---/,/---END---/p' | \
        sed '1d;$d' | tr -d '\r' | base64 -d > "$target"
    done
    ;;

  -er)
    # Download multiple folders
    for path in "${paths[@]}"; do
      target="$path"
      echo ">>> Downloading directory: ~/$path -> ./$target" >&2
      mkdir -p "$target"
      {
        penguin_cmd "echo '---BEGIN---'; tar czf - -C \"$path\" . | base64 -w 76; echo '---END---'"
        echo "exit"
      } | "${SSH_BASE[@]}" -T root@"$address" 'vmc start termina' | \
        sed -n '/---BEGIN---/,/---END---/p' | \
        sed '1d;$d' | tr -d '\r' | base64 -d | tar xzf - -C "$target"
    done
    ;;
esac
