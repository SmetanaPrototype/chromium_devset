#!/bin/bash
set -e -o pipefail

address=$1
penguin_name=$2

usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") <address> <penguin_name> [flag] [path]

Modes:
  (no flag)     интерактивный вход в контейнер penguin
  -c  <file>    скопировать локальный файл в home пингвина
  -cr <dir>     скопировать локальную папку в home пингвина
  -e  <file>    извлечь файл из home пингвина в текущую папку
  -er <dir>     извлечь папку из home пингвина в текущую папку
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
    [[ -n "$path" ]] || { echo "Flag $flag requires a path argument" >&2; usage; }
    ;;
  *) echo "Unknown flag: $flag" >&2; usage ;;
esac

read -rsp "Host password: " password
echo

SSH_BASE=(sshpass -p "$password" ssh -o StrictHostKeyChecking=accept-new)

# Безопасная передача команды через base64
penguin_cmd() {
  local cmd="$1"
  local b64
  b64=$(printf '%s' "$cmd" | base64 | tr -d '\n')
  printf "vmc start termina -- lxc exec penguin -- su -l %s -c \"echo %s | base64 -d | sh\"" \
    "$penguin_name" "$b64"
}

case "$flag" in
  "")
    # --- интерактивный вход (как раньше) ---
    { sleep 5; printf 'lxc exec penguin -- su -l %s\n' "$penguin_name"; cat; } \
      | "${SSH_BASE[@]}" -tt root@"$address" 'vmc start termina'
    ;;

  -c)
    # --- файл: локально base64 -> удалённо base64 -d > target ---
    [[ -f "$path" ]] || { echo "Not a regular file: $path" >&2; exit 1; }
    target=$(basename "$path")
    base64 "$path" \
      | "${SSH_BASE[@]}" -T root@"$address" \
          "$(penguin_cmd "tr -d \"\\015\" | base64 -d > $target")" \
        > /dev/null
    ;;

  -cr)
    # --- папка: tar czf - | base64 -> удалённо base64 -d | tar xzf - ---
    [[ -d "$path" ]] || { echo "Not a directory: $path" >&2; exit 1; }
    target=$(basename "$path")
    tar czf - -C "$path" . \
      | base64 \
      | "${SSH_BASE[@]}" -T root@"$address" \
          "$(penguin_cmd "mkdir -p $target && tr -d \"\\015\" | base64 -d | tar xzf - -C $target")" \
        > /dev/null
    ;;

  -e)
    # --- файл из пингвина -> текущая папка ---
    target=$(basename "$path")
    "${SSH_BASE[@]}" -T root@"$address" \
      "$(penguin_cmd "base64 -w 76 $path")" \
      | tr -d '\r' | base64 -d > "$target"
    ;;

  -er)
    # --- папка из пингвина -> текущая папка ---
    target=$(basename "$path")
    mkdir -p "$target"
    "${SSH_BASE[@]}" -T root@"$address" \
      "$(penguin_cmd "tar czf - -C $path . | base64 -w 76")" \
      | tr -d '\r' | base64 -d | tar xzf - -C "$target"
    ;;
esac
