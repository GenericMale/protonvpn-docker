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
: "${PROTON_SERVER_FILE:=/etc/openvpn/servers.json}"

: "${VPN_KILL_SWITCH:=1}"              #Disconnect on VPN drop
: "${EXTERNAL_USER:=openvpn}"          #User which bypasses VPN via split tunneling
: "${INTERNAL_NETWORK:=172.16.0.0/12}" #Default docker address pool which is allowed to bypass kill switch

#Create auth file from credentials if it doesn't exist
if [[ ! -f "$OPENVPN_USER_PASS_FILE" ]]; then
  echo $OPENVPN_USER >$OPENVPN_USER_PASS_FILE
  echo $OPENVPN_PASS >>$OPENVPN_USER_PASS_FILE
fi

activate_kill_switch() {
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

  #Accept All Responses
  iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

  if [[ "$INTERNAL_NETWORK" ]]; then
    #Allow default docker address pool to enable communication with other containers
    iptables -A INPUT -s $INTERNAL_NETWORK -i eth+ -j ACCEPT
    iptables -A OUTPUT -d $INTERNAL_NETWORK -o eth+ -j ACCEPT
  fi

  echo "Kill Switch enabled"
}

deactivate_kill_switch() {
  iptables -F
  iptables -P INPUT ACCEPT
  iptables -P OUTPUT ACCEPT
  iptables -P FORWARD ACCEPT
}

setup_split_tunnel() {
  local gateway=$(ip route | grep -m 1 default | cut -d' ' -f3)

  local nameserver=$(grep -m 1 '^nameserver' /etc/resolv.conf | cut -d' ' -f2)
  if [[ "$nameserver" == "127.0.0.11" ]]; then
    #docker internal DNS has a random port
    nameserver="$nameserver:$(netstat -anu | awk '{ print $4 }' | grep $nameserver | cut -d: -f2)"
  fi

  #Create own routing table for user and allow outgoing calls to original gateway
  iptables -t mangle -A OUTPUT -m owner --uid-owner "$EXTERNAL_USER" -j MARK --set-mark 1
  iptables -A OUTPUT -m mark --mark 1 -j ACCEPT
  ip rule add fwmark 1 table 1
  ip route add default via $gateway table 1

  #Redirect DNS to original nameserver
  iptables -t nat -A OUTPUT -m mark --mark 1 -p udp --dport 53 -j DNAT --to-destination $nameserver
  iptables -t nat -A POSTROUTING -o eth+ -j MASQUERADE
}

download_servers() {
  echo "Fetching Server List..."

  #Filters by proton tier & enabled status and sort for fastest
  local filter=".LogicalServers | map(select(.Tier <= $PROTON_TIER and .Status == 1)) | sort_by(.Score)"
  su -s /bin/sh $EXTERNAL_USER -c \
  "wget -q -O- $PROTON_API_URL/vpn/logicals | jq \"$filter | $VPN_SERVER_FILTER\"" >$PROTON_SERVER_FILE
}

generate_certificates() {
  if [[ ! -f "$OPENVPN_CA_FILE" ]] || [[ ! -f "$OPENVPN_TLS_CRYPT_FILE" ]]; then
    echo "Downloading Certificates..."

    #Get ProtonVPN config by using first server
    local logical_id=$(cat $PROTON_SERVER_FILE | jq -r ".[0].ID")
    local openvpn_config=$(
      su -s /bin/sh $EXTERNAL_USER -c \
      "wget -q -O- \"$PROTON_API_URL/vpn/config?Platform=Linux&Protocol=udp&LogicalID=$logical_id\""
    )

    #Extract CA cert & TLS key from config
    echo "$openvpn_config" | sed -n '/BEGIN CERTIFICATE/,/END CERTIFICATE/p' >$OPENVPN_CA_FILE
    echo "$openvpn_config" | sed -n '/BEGIN OpenVPN Static key/,/END OpenVPN Static key/p' >$OPENVPN_TLS_CRYPT_FILE
  fi
}

kill_openvpn() {
  if pgrep -x openvpn >/dev/null; then
    echo "Disconnecting..."
    pkill openvpn

    #wait until openvpn process is gone
    while pgrep -x openvpn >/dev/null; do sleep 1; done
  fi
}

get_timeout_seconds() {
  if [[ "$VPN_RECONNECT" == *":"* ]]; then
    #Convert HH:MM to seconds from now
    local timeout=$(($(date -d $VPN_RECONNECT +%s) - $(date +%s)))
    if [[ "$timeout" -lt 0 ]]; then timeout=$((86400 + timeout)); fi
    echo $timeout
  else
    #Convert duration like "1d", "2h 5m 30s" etc to seconds
    echo $(($(echo $VPN_RECONNECT | sed 's/d/*24*3600 +/g; s/h/*3600 +/g; s/m/*60 +/g; s/s/\+/g; s/+[ ]*$//g')))
  fi
}

connect() {
  download_servers
  generate_certificates
  kill_openvpn

  #Get Server IPs, remove duplicates and limit number of results.
  local get_unique_ip_list="map({(.Servers[].EntryIP):1}) | add | keys_unsorted | .[:$VPN_SERVER_COUNT][]"
  local servers=$(cat $PROTON_SERVER_FILE | jq -r "$get_unique_ip_list")

  echo "Connecting..."
  openvpn --config $OPENVPN_CONFIG_FILE --auth-user-pass $OPENVPN_USER_PASS_FILE --remote ${servers//$'\n'/' --remote '} &

  #Set session timeout if reconnect enabled
  if [[ "$VPN_RECONNECT" ]]; then
    local timeout=$(get_timeout_seconds)
    echo "Session Timeout in $timeout seconds"
    sleep $timeout &
  fi

  #Wait until OpenVPN dies or we have to reconnect
  wait $!
}

if [[ "$VPN_KILL_SWITCH" -eq 1 ]]; then
  activate_kill_switch
else
  deactivate_kill_switch
fi

setup_split_tunnel

while true; do
  connect
done
