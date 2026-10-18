#!/bin/bash
set -e -o pipefail

address=$1
penguin_name=$2

read -rsp "Host password: " password
echo

{ sleep 5; printf 'lxc exec penguin -- su -l %s\n' "$penguin_name"; cat; } \
  | sshpass -p "$password" ssh -tt root@"$address" 'vmc start termina'
