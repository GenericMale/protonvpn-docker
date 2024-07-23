#!/bin/sh

: "${VPN_SERVER_COUNT:=1}" #How many of the fastest servers to rotate
: "${VPN_SERVER_FILTER:=.}" #Additional jq filter to apply to server list

: "${OPENVPN_USER_PASS_FILE:=/etc/openvpn/protonvpn.auth}"
: "${OPENVPN_CONFIG_FILE:=/etc/openvpn/protonvpn.ovpn}"

: "${PROTON_API_URL:=https://api.protonvpn.ch/vpn/logicals}"
: "${PROTON_TIER:=2}" #Proton Tier. 0=Free, 1=Basic, 2=Plus, 3=Visionary

if [ ! -f $OPENVPN_USER_PASS_FILE ]; then
    echo $OPENVPN_USER > $OPENVPN_USER_PASS_FILE
    echo $OPENVPN_PASS >> $OPENVPN_USER_PASS_FILE
fi

while true
do

    if pgrep -x openvpn > /dev/null; then
        #Call API without VPN to get proper scores
        echo "Disconnecting..."

        iptables -F
        iptables -P OUTPUT ACCEPT
        iptables -P INPUT ACCEPT

        pkill openvpn
        while pgrep -x openvpn > /dev/null; do sleep 1; done
    fi

    echo "Fetching Server List..."
    servers=$(wget -q -O- $PROTON_API_URL | jq ".LogicalServers | map(select(.Tier <= $PROTON_TIER and .Status == 1)) | sort_by(.Score) | $VPN_SERVER_FILTER | map(.Servers[0].EntryIP)[:$VPN_SERVER_COUNT][]" | tr -d '"')
    echo ${servers//$'\n'/ }

    echo "Connecting..."
    ovpn_cmd="openvpn --config $OPENVPN_CONFIG_FILE --auth-user-pass $OPENVPN_USER_PASS_FILE --remote ${servers//$'\n'/' --remote '}"

    #Engage Kill Switch
    iptables -F
    iptables -P INPUT DROP
    iptables -P OUTPUT DROP
    iptables -P FORWARD DROP
    iptables -A INPUT -i lo -j ACCEPT
    iptables -A OUTPUT -o lo -j ACCEPT
    iptables -A INPUT -i tun0 -j ACCEPT
    iptables -A OUTPUT -o tun0 -j ACCEPT
    iptables -A INPUT -p udp -m udp --sport 1194 -j ACCEPT
    iptables -A OUTPUT -p udp -m udp --dport 1194 -j ACCEPT
    iptables -A INPUT -s 172.16.0.0/12 -i eth0 -j ACCEPT
    iptables -A OUTPUT -d 172.16.0.0/12 -o eth0 -j ACCEPT

    if [ -z $VPN_RECONNECT ]; then
        # Start OpenVPN in foreground if we don't need to reconnect
        eval "$ovpn_cmd"
    else
        # Start in background and sleep
        eval "$ovpn_cmd &"

        if [[ $VPN_RECONNECT == *":"* ]]; then
            # Convert HH:MM to seconds from now
            sleep=$(($(date -d $VPN_RECONNECT +%s) - $(date +%s)))
            if [ $sleep -lt 0 ]; then sleep=$((86400 + sleep)); fi

            echo "Reconnecting in ${sleep}s ($VPN_RECONNECT)."
            sleep $sleep
        else
            echo "Reconnecting in $VPN_RECONNECT."
            sleep $VPN_RECONNECT
        fi
    fi
done
