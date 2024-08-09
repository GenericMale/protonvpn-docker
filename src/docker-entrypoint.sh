#!/bin/ash

#
# Licensed under the EUPL-1.2 or later.
# You may obtain a copy of the licence at https://joinup.ec.europa.eu/collection/eupl/eupl-text-eupl-12
#

# shellcheck disable=SC2155
[[ "$DEBUG" == "true" ]] && set -x

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

: "${VPN_KILL_SWITCH:=1}"     #Disconnect on VPN drop
: "${EXTERNAL_USER:=openvpn}" #User which bypasses VPN via split tunneling

: "${IP_CHECK_URL:=https://ifconfig.co/json}" #URL to query for external IP
: "${CONNECT_TIMEOUT:=60}"                    #Maximum time in seconds to wait for a new IP until a reconnect is triggered.

: "${HTTP_PROXY:=0}" #Start proxy server
: "${RESOLVER_CONFIG:=/etc/resolv.conf}"
: "${EXIT_ON_DISCONNECT:=0}"

log() { echo "$(date "+%Y-%m-%d %H:%M:%S") $1"; }
run_as_external() { su -s /bin/sh "$EXTERNAL_USER" -c "$1"; }

create_user_pass_file() {
  if [[ -f "$OPENVPN_USER_PASS_FILE" ]]; then return 0; fi
  echo "$OPENVPN_USER" >"$OPENVPN_USER_PASS_FILE"
  echo "$OPENVPN_PASS" >>"$OPENVPN_USER_PASS_FILE"
}

setup_split_tunnel() {
  local gateway="$(ip route | grep -m 1 default | cut -d' ' -f3)"

  local nameserver=$(grep -m 1 '^nameserver' "$RESOLVER_CONFIG" | cut -d' ' -f2)
  if [[ "$nameserver" == "127.0.0.11" ]]; then
    #docker internal DNS has a random port
    local ns_port=$(netstat -anu 2>/dev/null | awk '{ print $4 }' | grep "$nameserver" | cut -d: -f2)
    nameserver="$nameserver:$ns_port"
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
  log "Fetching ProtonVPN Server List..."

  #Filters by proton tier & enabled status and sort for fastest
  local filter=".LogicalServers | map(select(.Tier <= $PROTON_TIER and .Status == 1)) | sort_by(.Score)"
  run_as_external "wget -q -O- $PROTON_API_URL/vpn/logicals | jq \"$filter | $VPN_SERVER_FILTER\"" >"$PROTON_SERVER_FILE"

  if [[ -s "$PROTON_SERVER_FILE" ]]; then
    log "Found $(jq -r "length" "$PROTON_SERVER_FILE") servers."
  else
    log >&2 "No servers found!"
    return 1
  fi
}

generate_certificates() {
  if [[ -f "$OPENVPN_CA_FILE" ]] && [[ -f "$OPENVPN_TLS_CRYPT_FILE" ]]; then return 0; fi

  log "Downloading ProtonVPN Certificates..."

  #Get ProtonVPN config by using first server
  local logical_id="$(jq -r ".[0].ID" "$PROTON_SERVER_FILE")"
  local openvpn_config="$(
    run_as_external "wget -q -O- \"$PROTON_API_URL/vpn/config?Platform=Linux&Protocol=udp&LogicalID=$logical_id\""
  )"

  if [[ "$openvpn_config" ]]; then
    #Extract CA cert & TLS key from config
    echo "$openvpn_config" | sed -n '/BEGIN CERTIFICATE/,/END CERTIFICATE/p' >"$OPENVPN_CA_FILE"
    echo "$openvpn_config" | sed -n '/BEGIN OpenVPN Static key/,/END OpenVPN Static key/p' >"$OPENVPN_TLS_CRYPT_FILE"
  else
    log >&2 "Failed to download certificates!"
    return 1
  fi
}

# shellcheck disable=SC2086
kill_process() {
  local pids=$(pgrep -x "$1" | tr '\n' ' ')
  if [[ ! "$pids" ]]; then return 0; fi

  log "Stopping $1..."
  kill $pids
  wait $pids
  return 0
}

wait_for_reconnect() {
  openvpn_pid=$1
  if [[ ! "$VPN_RECONNECT" ]]; then
    #Just wait until OpenVPN is terminated
    wait "$openvpn_pid" 2>/dev/null
    return 0
  fi

  if echo "$VPN_RECONNECT" | grep -q ":"; then
    #Convert HH:MM to seconds from now
    local timeout=$(($(date -d "$VPN_RECONNECT" +%s) - $(date +%s)))
    if [[ "$timeout" -lt 0 ]]; then timeout=$((86400 + timeout)); fi
  else
    #Convert duration like "1d", "2h 5m 30s" etc to seconds
    local timeout=$(($(echo "$VPN_RECONNECT" | sed 's/d/*24*3600 +/g; s/h/*3600 +/g; s/m/*60 +/g; s/s/\+/g; s/+[ ]*$//g')))
  fi

  local timestamp=$(($(date +%s) + timeout))
  local date="$(date "+%Y-%m-%d %H:%M:%S" -d @$timestamp)"

  log "Reconnecting on $date ($timeout sec)"
  sleep "$timeout" &
  local sleep_pid=$!

  wait_any "$openvpn_pid" "$sleep_pid"
  kill $sleep_pid 2>/dev/null # clean up the sleep when openvpn has died
  return 0
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
  if [[ ! "$IP_CHECK_URL" ]]; then return 0; fi

  local get_ip_cmd="wget -T 3 -q -O- $IP_CHECK_URL 2>/dev/null"
  local format_ip="IP: \(.ip) \(.country) (\(.asn_org // .asn // .hostname))"

  local old_ip_json="$(run_as_external "$get_ip_cmd")"
  if [[ ! "$old_ip_json" ]]; then
    log >&2 "Failed to get old IP, skipping IP check."
    return 1
  fi

  log "$(echo "$old_ip_json" | jq -r "\"Old $format_ip\"")"
  local old_ip=$(echo "$old_ip_json" | jq -r '.ip')

  local start=$(date +%s)
  while [[ "$CONNECT_TIMEOUT" -ge $(($(date +%s) - start)) ]]; do
    local ip_json=$(eval "$get_ip_cmd")
    local new_ip=$(echo "$ip_json" | jq -r '.ip')

    if [[ "$new_ip" ]] && [[ "$old_ip" != "$new_ip" ]]; then
      log "$(echo "$ip_json" | jq -r "\"New $format_ip\"")"
      return 0
    fi
    sleep 1
  done

  log >&2 "Timed out waiting for IP change, reconnecting..."
  return 1
}

start_openvpn() {
  #Get Server IPs, remove duplicates and limit number of results.
  local get_unique_ip_list="map({(.Servers[].EntryIP):1}) | add | keys_unsorted | .[:$VPN_SERVER_COUNT][]"
  local servers="$(jq -r "$get_unique_ip_list" "$PROTON_SERVER_FILE")"

  # shellcheck disable=SC2086
  openvpn \
    --config "$OPENVPN_CONFIG_FILE" \
    --auth-user-pass "$OPENVPN_USER_PASS_FILE" \
    --remote ${servers//$'\n'/' --remote '} \
    $OPENVPN_EXTRA_ARGS &
}

main() {
  if [[ "$VPN_KILL_SWITCH" -eq 1 ]]; then
    iptables-restore /etc/iptables/killswitch.rules
    log "Kill Switch enabled"
  fi

  setup_split_tunnel
  create_user_pass_file

  if [[ "$HTTP_PROXY" -eq 1 ]]; then
    log "Starting Proxy..."
    tinyproxy -d &
  fi

  while true; do
    download_servers
    generate_certificates
    kill_process openvpn

    log "Starting OpenVPN..."
    start_openvpn
    local openvpn_pid=$!

    if wait_for_new_ip; then
      wait_for_reconnect "$openvpn_pid"
    fi

    [[ "$EXIT_ON_DISCONNECT" -eq 0 ]] || break
  done
}

trap 'kill_process openvpn; kill_process tinyproxy; exit' TERM # gracefully shutdown on SIGTERM

#https://github.com/shellspec/shellspec?tab=readme-ov-file#testing-shell-functions
${__SOURCED__:+return}

main
