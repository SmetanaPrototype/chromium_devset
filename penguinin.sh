#!/bin/bash
set -e -o pipefail

address=$1
penguin_name=$2

usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") <address> <penguin_name> [flag] [path]

Modes:
  (no flag)     interactive shell into the penguin container
  -c  <file>    copy a local file into the penguin user's home
  -cr <dir>     copy a local folder into the penguin user's home
  -e  <file>    extract a file from the penguin user's home into cwd
  -er <dir>     extract a folder from the penguin user's home into cwd
EOF
  exit 1
}

[[ -z "$address" || -z "$penguin_name" ]] && usage

flag=""
path=""
if [[ $# -ge 3 && "$3" == -* ]]; then
  flag="$3"
  path="$4"
fi

case "$flag" in
  "") ;;
  -c|-cr|-e|-er)
    # Every non-interactive mode requires a source/target path.
    [[ -n "$path" ]] || { echo "Flag $flag requires a path argument" >&2; usage; }
    ;;
  *) echo "Unknown flag: $flag" >&2; usage ;;
esac

read -rsp "Host password: " password
echo

SSH_BASE=(sshpass -p "$password" ssh -o StrictHostKeyChecking=accept-new)

# Build the remote command:
#   vmc start termina -- lxc exec penguin -- su -l USER -c '...'
# Single quotes cannot appear inside the single-quoted snippet, so the
# inner command uses only double quotes and octal escapes.
penguin_cmd() {
  printf "vmc start termina -- lxc exec penguin -- su -l %s -c '%s'" \
    "$penguin_name" "$1"
}

case "$flag" in
  "")
    # --- interactive login (same as before) ---
    { sleep 5; printf 'lxc exec penguin -- su -l %s\n' "$penguin_name"; cat; } \
      | "${SSH_BASE[@]}" -tt root@"$address" 'vmc start termina'
    ;;

  -c)
    # --- file: local base64 -> remote base64 -d > target ---
    [[ -f "$path" ]] || { echo "Not a regular file: $path" >&2; exit 1; }
    target=$(basename "$path")
    base64 "$path" \
      | "${SSH_BASE[@]}" -T root@"$address" \
          "$(penguin_cmd "tr -d \"\\015\" | base64 -d > $target")" \
        > /dev/null
    ;;

  -cr)
    # --- folder: tar czf - | base64 -> remote base64 -d | tar xzf - ---
    [[ -d "$path" ]] || { echo "Not a directory: $path" >&2; exit 1; }
    target=$(basename "$path")
    tar czf - -C "$path" . \
      | base64 \
      | "${SSH_BASE[@]}" -T root@"$address" \
          "$(penguin_cmd "mkdir -p $target && tr -d \"\\015\" | base64 -d | tar xzf - -C $target")" \
        > /dev/null
    ;;

  -e)
    # --- file from penguin -> current directory ---
    target=$(basename "$path")
    "${SSH_BASE[@]}" -T root@"$address" \
      "$(penguin_cmd "base64 -w 76 $path")" \
      | tr -d '\r' | base64 -d > "$target"
    ;;

  -er)
    # --- folder from penguin -> current directory ---
    target=$(basename "$path")
    mkdir -p "$target"
    "${SSH_BASE[@]}" -T root@"$address" \
      "$(penguin_cmd "tar czf - -C $path . | base64 -w 76")" \
      | tr -d '\r' | base64 -d | tar xzf - -C "$target"
    ;;
esac
