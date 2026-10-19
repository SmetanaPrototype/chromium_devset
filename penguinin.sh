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

# Генерирует команду для выполнения внутри пингвина. 
# Кодирует в base64, чтобы избежать проблем с кавычками.
penguin_cmd() {
  local cmd="$1"
  local b64
  b64=$(printf '%s' "$cmd" | base64 | tr -d '\n')
  printf 'lxc exec penguin -- su -l %s -c "echo %s | base64 -d | sh"' \
    "$penguin_name" "$b64"
}

case "$flag" in
  "")
    # Интерактивный вход (как в оригинале)
    { sleep 5; printf 'lxc exec penguin -- su -l %s\n' "$penguin_name"; cat; } \
      | "${SSH_BASE[@]}" -tt root@"$address" 'vmc start termina'
    ;;

  -c)
    # Загрузка файла: шлем команду, затем бинарные данные.
    [[ -f "$path" ]] || { echo "Not a regular file: $path" >&2; exit 1; }
    target=$(basename "$path")
    {
      penguin_cmd "cat > $target"
      echo ""  # Перевод строки, чтобы терминал выполнил команду
      base64 "$path"
    } | "${SSH_BASE[@]}" -T root@"$address" 'vmc start termina' > /dev/null
    ;;

  -cr)
    # Загрузка папки: шлем команду, затем tar+base64.
    [[ -d "$path" ]] || { echo "Not a directory: $path" >&2; exit 1; }
    target=$(basename "$path")
    {
      penguin_cmd "mkdir -p $target && tar xzf - -C $target"
      echo ""
      tar czf - -C "$path" . | base64
    } | "${SSH_BASE[@]}" -T root@"$address" 'vmc start termina' > /dev/null
    ;;

  -e)
    # Скачивание файла: используем маркеры, чтобы отсечь приветствие терминала.
    target=$(basename "$path")
    {
      penguin_cmd "echo '---BEGIN---'; base64 -w 76 $path; echo '---END---'"
      echo ""
      echo "exit"  # Закрываем сессию после выполнения
    } | "${SSH_BASE[@]}" -T root@"$address" 'vmc start termina' | \
      sed -n '/---BEGIN---/,/---END---/p' | \
      sed '1d;$d' | tr -d '\r' | base64 -d > "$target"
    ;;

  -er)
    # Скачивание папки: используем маркеры.
    target=$(basename "$path")
    mkdir -p "$target"
    {
      penguin_cmd "echo '---BEGIN---'; tar czf - -C $path . | base64 -w 76; echo '---END---'"
      echo ""
      echo "exit"
    } | "${SSH_BASE[@]}" -T root@"$address" 'vmc start termina' | \
      sed -n '/---BEGIN---/,/---END---/p' | \
      sed '1d;$d' | tr -d '\r' | base64 -d | tar xzf - -C "$target"
    ;;
esac
