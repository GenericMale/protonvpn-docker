#!/bin/sh

: "${VPN_SERVER_COUNT:=1}"  #How many of the fastest servers to rotate
: "${VPN_SERVER_FILTER:=.}" #Additional jq filter to apply to server list

: "${OPENVPN_USER_PASS_FILE:=/etc/openvpn/protonvpn.auth}"
: "${OPENVPN_CONFIG_FILE:=/etc/openvpn/protonvpn.ovpn}"

: "${PROTON_API_URL:=https://api.protonvpn.ch/vpn/logicals}"
: "${IP_CHECK_URL:=https://ifconfig.co/json}"
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
        #Call API without VPN to get proper scores
        echo "Disconnecting..."

        if [[ $VPN_KILL_SWITCH -eq 1 ]]; then
          #Disable Kill Switch
          iptables -F
          iptables -P OUTPUT ACCEPT
          iptables -P INPUT ACCEPT
        fi

        pkill openvpn
        while pgrep -x openvpn >/dev/null; do sleep 1; done #wait until openvpn process is gone
    fi

    echo "Fetching Server List..."
    servers=$(wget -q -O- $PROTON_API_URL | jq "$get_servers | $VPN_SERVER_FILTER | $get_unique_ip_list")
    echo "Filtered Server Pool: ${servers//$'\n'/, }"

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

    #Start OpenVPN in background
    echo "Connecting..."
    eval "openvpn --config $OPENVPN_CONFIG_FILE --auth-user-pass $OPENVPN_USER_PASS_FILE --remote ${servers//$'\n'/' --remote '} &"

    if [ "$IP_CHECK_URL" ] && [[ $VPN_KILL_SWITCH -eq 1 ]]; then
        #Wait for new IP. Kill Switch blocks until VPN is up.
        while true; do
            ip=$(wget -T 3 -q -O- $IP_CHECK_URL 2>/dev/null)
            if [[ "$?" -eq 0 ]]; then break; fi
            sleep 1
        done
        echo $ip | jq -r '"New IP: \(.ip) - \(.country), \(.asn_org)"'
    fi

    if [ -z $VPN_RECONNECT ]; then
        #Halt until OpenVPN process is interrupted if scheduled reconnect is disabled.
        #So if OpenVPN crashes we'll loop over and try to connect again.
        wait
    elif [[ $VPN_RECONNECT == *":"* ]]; then
        #Convert HH:MM to seconds from now
        sleep=$(($(date -d $VPN_RECONNECT +%s) - $(date +%s)))
        if [ $sleep -lt 0 ]; then sleep=$((86400 + sleep)); fi

        echo "Reconnecting in ${sleep}s ($VPN_RECONNECT)."
        sleep $sleep
    else
        echo "Reconnecting in $VPN_RECONNECT."
        sleep $VPN_RECONNECT
    fi
done
