#!/bin/bash

usb=$1
image=$2

sudo umount /dev/"$1"*
sudo wipefs -a /dev/"$1"

sudo pv -p -t -e -r -b -f "$2" | sudo dd of=/dev/"$1" bs=4M iflag=fullblock oflag=direct