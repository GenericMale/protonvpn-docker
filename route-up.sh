#!/bin/ash

# Script to look up our IP after the VPN went up and print it to the Docker Logs.

: "${IP_CHECK_URL:=https://ifconfig.co/json}"

if [ "$IP_CHECK_URL" ]; then
  # OpenVPN won't start handling packets until after the script has finished, so we need to execute it in the back.
  nohup /bin/ash -c \
    "sleep 0.1; wget -q -O- $IP_CHECK_URL | jq -r '\"New IP: \(.ip) - \(.country), \(.asn_org)\"'" \
    >/proc/1/fd/1 2>/proc/1/fd/2 & # write to stdout of container entrypoint => docker logs
fi

exit 0
