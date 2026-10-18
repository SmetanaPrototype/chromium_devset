#!/bin/bash

set -e -o pipefail

address=$1
penguin_name=$2

read -rsp "Password: " password
echo

{ sleep 5; printf 'lxc exec penguin -- su -l $penguin_name\n'; cat; } | sshpass -p '$password' ssh -tt root@$address 'vmc start termina'
