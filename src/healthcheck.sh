#!/bin/ash

#
# Copyright Sebastian Maurer, 2024. Licensed under the EUPL-1.2 or later.
# You may obtain a copy of the licence at https://joinup.ec.europa.eu/collection/eupl/eupl-text-eupl-12
#

#check if tun device has ip
tun_ip=$(ip -4 addr show tun0 | grep inet | xargs echo -n | cut -d' ' -f2 2>/dev/null)
if echo "$tun_ip" | grep -qE "^([0-9]+\.){3}[0-9]+/[0-9]+$"; then
  exit 0
else
  exit 1
fi
