#!/bin/sh
trap 'kill -TERM $(jobs -p); wait; exit' TERM # propagate SIGTERM to openvpn in subshell

: "${VPN_SERVER_COUNT:=1}"  #How many of the fastest servers to rotate
: "${VPN_SERVER_FILTER:=.}" #Additional jq filter to apply to server list

: "${OPENVPN_USER_PASS_FILE:=/etc/openvpn/protonvpn.auth}"
: "${OPENVPN_CONFIG_FILE:=/etc/openvpn/protonvpn.ovpn}"

: "${OPENVPN_CA_FILE:=/etc/openvpn/ca.crt}"
: "${OPENVPN_TLS_CRYPT_FILE:=/etc/openvpn/ta.key}"

: "${PROTON_API_URL:=https://api.protonvpn.ch}"
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
    servers=$(wget -q -O- "$PROTON_API_URL/vpn/logicals" | jq "$get_servers | $VPN_SERVER_FILTER")
    server_ips=$(echo $servers | jq "$get_unique_ip_list")
    extra_args="--remote ${server_ips//$'\n'/' --remote '}"
    echo "Server Pool: ${server_ips//$'\n'/ }"

    #Get ProtonVPN Config and extract CA cert & TLS key. They are the same for all servers and never change.
    if [ ! -f $OPENVPN_CA_FILE ] || [ ! -f $OPENVPN_TLS_CRYPT_FILE ]; then
        echo "Downloading Certificates..."
        logical_id=$(echo $servers|jq -r ".[0].ID")
        openvpn_config=$(wget -q -O- "$PROTON_API_URL/vpn/config?Platform=Linux&Protocol=udp&LogicalID=$logical_id")
        echo "$openvpn_config" | sed -n '/BEGIN CERTIFICATE/,/END CERTIFICATE/p' > $OPENVPN_CA_FILE
        echo "$openvpn_config" | sed -n '/BEGIN OpenVPN Static key/,/END OpenVPN Static key/p' > $OPENVPN_TLS_CRYPT_FILE
    fi

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
      iptables -A INPUT -i tun+ -j ACCEPT
      iptables -A OUTPUT -o tun+ -j ACCEPT
      iptables -A INPUT -m state --state ESTABLISHED -j ACCEPT
      iptables -A OUTPUT -p udp -m udp --dport 1194 -j ACCEPT

      #Allow default docker address pool to enable communication with other containers
      iptables -A INPUT -s 172.16.0.0/12 -i eth+ -j ACCEPT
      iptables -A OUTPUT -d 172.16.0.0/12 -o eth+ -j ACCEPT
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
    unset servers server_ips extra_args logical_id openvpn_config timeout
    wait
done
