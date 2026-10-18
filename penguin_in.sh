#!/bin/bash

set -e -o pipefail

address=$1
penguin_name=$2

read -rsp "Password: " password
echo

expect -c "
  set timeout 60
  spawn sshpass -p \"$password\" ssh -tt root@$address 'vmc start termina'
  expect \"(termina)\"
  expect \"~ \\\$\"
  send \"lxc exec penguin -- su -l $penguin_name\r\"
  interact
"
