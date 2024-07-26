#!/bin/sh
trap 'kill -TERM $(jobs -p); wait; exit' TERM # propagate SIGTERM to openvpn in subshell

: "${VPN_SERVER_COUNT:=1}"  #How many of the fastest servers to rotate
: "${VPN_SERVER_FILTER:=.}" #Additional jq filter to apply to server list

: "${OPENVPN_USER_PASS_FILE:=/etc/openvpn/protonvpn.auth}"
: "${OPENVPN_CONFIG_FILE:=/etc/openvpn/protonvpn.ovpn}"

: "${PROTON_API_URL:=https://api.protonvpn.ch/vpn/logicals}"
: "${PROTON_TIER:=2}" #Proton Tier. 0=Free, 1=Basic, 2=Plus, 3=Visionary
: "${VPN_KILL_SWITCH:=1}" #Disconnect on VPN drop

if [ ! -f $OPENVPN_USER_PASS_FILE ]; then
    #Create auth file from credentials if it doesn't exist
    echo $OPENVPN_USER >$OPENVPN_USER_PASS_FILE
    echo $OPENVPN_PASS >>$OPENVPN_USER_PASS_FILE
fi

#Initial JQ Filter for Servers. Filters for proton tier and enabled and sorts by fastest.
get_servers=".LogicalServers | map(select(.Tier <= $PROTON_TIER and .Status == 1)) | sort_by(.Score)"

#Final JQ Filter to remove duplicate IPs and limit number of results.
get_unique_ip_list="map({(.Servers[].EntryIP):1}) | add | keys_unsorted | .[:$VPN_SERVER_COUNT][]"

while true; do
    if pgrep -x openvpn >/dev/null; then
        echo "Disconnecting..."
        pkill openvpn
        while pgrep -x openvpn >/dev/null; do sleep 1; done #wait until openvpn process is gone
    fi

    #Disable Kill Switch
    if [[ $VPN_KILL_SWITCH -eq 1 ]]; then
      iptables -F
      iptables -P OUTPUT ACCEPT
      iptables -P INPUT ACCEPT
    fi

    #Call API without VPN to get proper scores
    echo "Fetching Server List..."
    servers=$(wget -q -O- $PROTON_API_URL | jq "$get_servers | $VPN_SERVER_FILTER | $get_unique_ip_list")
    extra_args="--remote ${servers//$'\n'/' --remote '}"
    echo "Server Pool: ${servers//$'\n'/ }"

    #Engage Kill Switch
    if [[ $VPN_KILL_SWITCH -eq 1 ]]; then
      #Default Drop All
      iptables -F
      iptables -P INPUT DROP
      iptables -P OUTPUT DROP
      iptables -P FORWARD DROP

      #Allow Localhost
      iptables -A INPUT -i lo -j ACCEPT
      iptables -A OUTPUT -o lo -j ACCEPT

      #Allow VPN
      iptables -A INPUT -i tun0 -j ACCEPT
      iptables -A OUTPUT -o tun0 -j ACCEPT
      iptables -A INPUT -p udp -m udp --sport 1194 -j ACCEPT
      iptables -A OUTPUT -p udp -m udp --dport 1194 -j ACCEPT

      #Allow default docker address pool to enable communication with other containers
      iptables -A INPUT -s 172.16.0.0/12 -i eth0 -j ACCEPT
      iptables -A OUTPUT -d 172.16.0.0/12 -o eth0 -j ACCEPT
    fi

    #Set session timeout if reconnect enabled
    if [ "$VPN_RECONNECT" ]; then
        if [[ $VPN_RECONNECT == *":"* ]]; then
            #Convert HH:MM to seconds from now
            timeout=$(($(date -d $VPN_RECONNECT +%s) - $(date +%s)))
            if [ $timeout -lt 0 ]; then timeout=$((86400 + timeout)); fi
        else
            #Convert duration like "1d", "2h 5m 30s" etc to seconds
            timeout=$(($(echo $VPN_RECONNECT | sed 's/d/*24*3600 +/g; s/h/*3600 +/g; s/m/*60 +/g; s/s/\+/g; s/+[ ]*$//g')))
        fi
        echo "Session Timeout in $timeout seconds"
        extra_args="$extra_args --session-timeout $timeout"
    fi

    echo "Connecting..."
    sh -c "openvpn --config $OPENVPN_CONFIG_FILE --auth-user-pass $OPENVPN_USER_PASS_FILE $extra_args" &
    wait
done
