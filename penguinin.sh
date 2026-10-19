#!/bin/bash
set -e -o pipefail

address=$1
penguin_name=$2

usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") <address> <penguin_name> [flag] [path]

Modes:
  (no flag)     Interactive shell into the penguin container
  -c  <file>    Copy a local file to penguin's home
  -cr <dir>     Copy a local folder to penguin's home
  -e  <file>    Extract a file from penguin's home to cwd
  -er <dir>     Extract a folder from penguin's home to cwd
EOF
  exit 1
}

[[ -z "$address" || -z "$penguin_name" ]] && usage

flag=""
path=""
if [[ $# -ge 3 && "$3" == -* ]]; then
  flag="$3"
  path="$4"
  if [[ $# -ne 4 ]]; then
    echo "Error: flag $flag accepts exactly one path argument." >&2
    usage
  fi
fi

case "$flag" in
  "") ;;
  -c|-cr|-e|-er)
    [[ -n "$path" ]] || { echo "Flag $flag requires a path argument" >&2; usage; }
    ;;
  *) echo "Unknown flag: $flag" >&2; usage ;;
esac

read -rsp "Host password: " password
echo

SSH_BASE=(sshpass -p "$password" ssh -o StrictHostKeyChecking=accept-new)

# Generate the command to be executed inside the Termina VM.
penguin_cmd() {
  local cmd="$1"
  local escaped_cmd
  # Escape single quotes so we can safely wrap the command in single quotes
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
    # Upload file: send command, then the base64 data
    [[ -f "$path" ]] || { echo "Not a regular file: $path" >&2; exit 1; }
    target=$(basename "$path")
    {
      penguin_cmd "base64 -d > \"$target\""
      base64 "$path"
    } | "${SSH_BASE[@]}" -T root@"$address" 'vmc start termina' > /dev/null
    ;;

  -cr)
    # Upload folder: send command, then the tar+base64 data
    [[ -d "$path" ]] || { echo "Not a directory: $path" >&2; exit 1; }
    target=$(basename "$path")
    {
      penguin_cmd "mkdir -p \"$target\" && base64 -d | tar xzf - -C \"$target\""
      tar czf - -C "$path" . | base64
    } | "${SSH_BASE[@]}" -T root@"$address" 'vmc start termina' > /dev/null
    ;;

  -e)
    # Download file: use markers to isolate data from shell prompts
    target=$(basename "$path")
    {
      penguin_cmd "echo '---BEGIN---'; base64 -w 76 \"$path\"; echo '---END---'"
      echo "exit"
    } | "${SSH_BASE[@]}" -T root@"$address" 'vmc start termina' | \
      sed -n '/---BEGIN---/,/---END---/p' | \
      sed '1d;$d' | tr -d '\r' | base64 -d > "$target"
    ;;

  -er)
    # Download folder: use markers
    target=$(basename "$path")
    mkdir -p "$target"
    {
      penguin_cmd "echo '---BEGIN---'; tar czf - -C \"$path\" . | base64 -w 76; echo '---END---'"
      echo "exit"
    } | "${SSH_BASE[@]}" -T root@"$address" 'vmc start termina' | \
      sed -n '/---BEGIN---/,/---END---/p' | \
      sed '1d;$d' | tr -d '\r' | base64 -d | tar xzf - -C "$target"
    ;;
esac
