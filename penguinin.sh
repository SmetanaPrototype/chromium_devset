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

# Generate the command to be executed inside the Termina VM.
penguin_cmd() {
  local cmd="$1"
  local escaped_cmd
  escaped_cmd=$(printf '%s' "$cmd" | sed "s/'/'\\\\''/g")
  printf "lxc exec penguin -- su -l %s -c '%s'\n" \
    "$penguin_name" "$escaped_cmd"
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
      target=$(basename "$path")
      echo ">>> Uploading file: $path -> $target" >&2
      {
        penguin_cmd "base64 -d > \"$target\""
        base64 "$path"
      } | "${SSH_BASE[@]}" -T root@"$address" 'vmc start termina' > /dev/null
    done
    ;;

  -cr)
    # Upload multiple folders
    for path in "${paths[@]}"; do
      [[ -d "$path" ]] || { echo "Not a directory: $path" >&2; exit 1; }
      target=$(basename "$path")
      echo ">>> Uploading directory: $path -> $target" >&2
      {
        penguin_cmd "mkdir -p \"$target\" && base64 -d | tar xzf - -C \"$target\""
        tar czf - -C "$path" . | base64
      } | "${SSH_BASE[@]}" -T root@"$address" 'vmc start termina' > /dev/null
    done
    ;;

  -e)
    # Download multiple files
    for path in "${paths[@]}"; do
      target=$(basename "$path")
      echo ">>> Downloading file: $path -> $target" >&2
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
      target=$(basename "$path")
      echo ">>> Downloading directory: $path -> $target" >&2
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
