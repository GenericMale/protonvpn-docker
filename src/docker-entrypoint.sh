#!/bin/ash
# shellcheck disable=SC2155

: "${VPN_SERVER_COUNT:=1}"  #How many of the fastest servers to rotate
: "${VPN_SERVER_FILTER:=.}" #Additional jq filter to apply to server list

: "${OPENVPN_USER_PASS_FILE:=/etc/openvpn/protonvpn.auth}"
: "${OPENVPN_CONFIG_FILE:=/etc/openvpn/protonvpn.ovpn}"
: "${OPENVPN_EXTRA_ARGS:=}"

: "${OPENVPN_CA_FILE:=/etc/openvpn/ca.crt}"
: "${OPENVPN_TLS_CRYPT_FILE:=/etc/openvpn/ta.key}"

: "${PROTON_API_URL:=https://api.protonvpn.ch}"
: "${PROTON_TIER:=2}" #Proton Tier. 0=Free, 1=Basic, 2=Plus, 3=Visionary
: "${PROTON_SERVER_FILE:=/etc/openvpn/servers.json}"

: "${VPN_KILL_SWITCH:=1}"              #Disconnect on VPN drop
: "${EXTERNAL_USER:=openvpn}"          #User which bypasses VPN via split tunneling
: "${INTERNAL_NETWORK:=172.16.0.0/12}" #Default docker address pool which is allowed to bypass kill switch

: "${IP_CHECK_URL:=https://ifconfig.co/json}" #URL to query for external IP
: "${CONNECT_TIMEOUT:=60}"                    #Maximum time in seconds to wait for a new IP until a reconnect is triggered.

#Create auth file from credentials if it doesn't exist
if [[ ! -f "$OPENVPN_USER_PASS_FILE" ]]; then
  echo "$OPENVPN_USER" >"$OPENVPN_USER_PASS_FILE"
  echo "$OPENVPN_PASS" >>"$OPENVPN_USER_PASS_FILE"
fi

trap 'kill -TERM $(jobs -p); wait; exit' TERM # propagate SIGTERM to openvpn in subshell

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
    iptables -A INPUT -s "$INTERNAL_NETWORK" -i eth+ -j ACCEPT
    iptables -A OUTPUT -d "$INTERNAL_NETWORK" -o eth+ -j ACCEPT
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
  local gateway="$(ip route | grep -m 1 default | cut -d' ' -f3)"

  local nameserver=$(grep -m 1 '^nameserver' /etc/resolv.conf | cut -d' ' -f2)
  if [[ "$nameserver" == "127.0.0.11" ]]; then
    #docker internal DNS has a random port
    nameserver="$nameserver:$(netstat -anu | awk '{ print $4 }' | grep "$nameserver" | cut -d: -f2)"
  fi

  #Create own routing table for user and allow outgoing calls to original gateway
  iptables -t mangle -A OUTPUT -m owner --uid-owner "$EXTERNAL_USER" -j MARK --set-mark 1
  iptables -A OUTPUT -m mark --mark 1 -j ACCEPT
  ip rule add fwmark 1 table 1
  ip route add default via "$gateway" table 1

  #Redirect DNS to original nameserver
  iptables -t nat -A OUTPUT -m mark --mark 1 -p udp --dport 53 -j DNAT --to-destination "$nameserver"
  iptables -t nat -A POSTROUTING -o eth+ -j MASQUERADE
}

download_servers() {
  echo "Fetching Server List..."

  #Filters by proton tier & enabled status and sort for fastest
  local filter=".LogicalServers | map(select(.Tier <= $PROTON_TIER and .Status == 1)) | sort_by(.Score)"
  su -s /bin/ash "$EXTERNAL_USER" -c \
    "wget -q -O- $PROTON_API_URL/vpn/logicals | jq \"$filter | $VPN_SERVER_FILTER\"" >"$PROTON_SERVER_FILE"
}

generate_certificates() {
  if [[ ! -f "$OPENVPN_CA_FILE" ]] || [[ ! -f "$OPENVPN_TLS_CRYPT_FILE" ]]; then
    echo "Downloading Certificates..."

    #Get ProtonVPN config by using first server
    local logical_id="$(jq -r ".[0].ID" "$PROTON_SERVER_FILE")"
    local openvpn_config="$(
      su -s /bin/ash "$EXTERNAL_USER" -c \
        "wget -q -O- \"$PROTON_API_URL/vpn/config?Platform=Linux&Protocol=udp&LogicalID=$logical_id\""
    )"

    #Extract CA cert & TLS key from config
    echo "$openvpn_config" | sed -n '/BEGIN CERTIFICATE/,/END CERTIFICATE/p' >"$OPENVPN_CA_FILE"
    echo "$openvpn_config" | sed -n '/BEGIN OpenVPN Static key/,/END OpenVPN Static key/p' >"$OPENVPN_TLS_CRYPT_FILE"
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
    local timeout=$(($(date -d "$VPN_RECONNECT" +%s) - $(date +%s)))
    if [[ "$timeout" -lt 0 ]]; then timeout=$((86400 + timeout)); fi
    echo $timeout
  else
    #Convert duration like "1d", "2h 5m 30s" etc to seconds
    echo $(($(echo "$VPN_RECONNECT" | sed 's/d/*24*3600 +/g; s/h/*3600 +/g; s/m/*60 +/g; s/s/\+/g; s/+[ ]*$//g')))
  fi
}

# wait for any of the provided list of subprocesses to terminate
wait_any() {
  while true; do
    for pid in "$@"; do
      # check if any of the processes in the list we got is terminated
      if ! kill -0 "$pid" >/dev/null 2>&1; then break 2; fi
    done
    wait -n #wait for any subprocess to die. apparently busybox "wait -n" doesn't accept a list of PIDs
  done
}

wait_for_new_ip() {
  if [[ "$IP_CHECK_URL" ]]; then
    local get_ip_cmd="wget -T 3 -q -O- $IP_CHECK_URL 2>/dev/null"
    local format_ip="IP: \(.ip) \(.country) (\(.asn_org // .asn // .hostname))"

    local old_ip_json="$(su -s /bin/ash "$EXTERNAL_USER" -c "$get_ip_cmd")"
    if [[ ! "$old_ip_json" ]]; then
      echo "Failed to get old IP, skipping IP check."
      return
    fi

    echo "$old_ip_json" | jq -r "\"Old $format_ip\""
    local old_ip=$(echo "$old_ip_json" | jq -r '.ip')

    local start=$(date +%s)
    while [[ "$CONNECT_TIMEOUT" -ge $(($(date +%s) - start)) ]]; do
      local ip_json=$(su -s /bin/ash -c "$get_ip_cmd")
      local new_ip=$(echo "$ip_json" | jq -r '.ip')

      if [[ "$new_ip" ]] && [[ "$old_ip" != "$new_ip" ]]; then
        echo "$ip_json" | jq -r "\"New $format_ip\""
        return
      fi
      sleep 1
    done

    echo "Timed out waiting for IP change, reconnecting..."
    return 1
  fi
}

connect() {
  download_servers
  generate_certificates
  kill_openvpn

  #Get Server IPs, remove duplicates and limit number of results.
  local get_unique_ip_list="map({(.Servers[].EntryIP):1}) | add | keys_unsorted | .[:$VPN_SERVER_COUNT][]"
  local servers="$(jq -r "$get_unique_ip_list" "$PROTON_SERVER_FILE")"

  echo "Connecting..."
  # shellcheck disable=SC2086
  openvpn --config "$OPENVPN_CONFIG_FILE" --auth-user-pass "$OPENVPN_USER_PASS_FILE" --remote ${servers//$'\n'/' --remote '} $OPENVPN_EXTRA_ARGS &
  local openvpn_pid=$!
  if ! wait_for_new_ip; then return; fi

  #Set session timeout if reconnect enabled
  if [[ "$VPN_RECONNECT" ]]; then
    local timeout="$(get_timeout_seconds)"
    local date="$(date @$(($(date +%s) + timeout)) 2>/dev/null)"

    echo "Reconnecting on $date ($timeout sec)"
    sleep "$timeout" &
    local sleep_pid=$!

    wait_any $openvpn_pid $sleep_pid
    kill $sleep_pid 2>/dev/null # clean up the sleep when openvpn has died
  else
    #Just wait until OpenVPN is terminated
    wait $openvpn_pid
  fi
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
