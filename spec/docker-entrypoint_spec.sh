#shellcheck shell=sh disable=SC2034,SC2317

Describe "docker-entrypoint.sh"
  DATA="./spec/data"
  TMP="./spec/tmp"
  BeforeEach "rm -rf $TMP && mkdir $TMP"

  Include "src/docker-entrypoint.sh"
  run_as_external() { eval "$1"; }

  process_killed() {
    pkill -0 "$1" && return 1 || return 0
  }

  Describe "download_servers"
    PROTON_SERVER_FILE="$TMP/servers.json"

    It "finds servers"
      When call download_servers
      The status should be success
      The line 1 of stdout should end with "Fetching ProtonVPN Server List..."
      The line 2 of stdout should match pattern "* Found ???? servers."
      The file $PROTON_SERVER_FILE should not be empty file
    End

    It "applies filters"
      VPN_SERVER_FILTER='map(select(.Name == \"GR#3\"))'
      When call download_servers
      The status should be success
      The line 2 of stdout should match pattern "* Found 1 servers."
    End

    It "filters by proton tier"
      PROTON_TIER=0
      When call download_servers
      The status should be success
      The line 2 of stdout should match pattern "* Found ?? servers."
    End

    It "fails gracefully with invalid url"
      PROTON_API_URL="https://invalid-api-url"
      When call download_servers
      The status should be failure
      The stdout should end with "Fetching ProtonVPN Server List..."
      The stderr should end with "No servers found!"
      The file $PROTON_SERVER_FILE should be empty file
    End
  End

  Describe "generate_certificates"
    PROTON_SERVER_FILE="$DATA/servers.json"
    OPENVPN_CA_FILE="$TMP/ca.crt"
    OPENVPN_TLS_CRYPT_FILE="$TMP/ta.key"

    It "downloads ca & tls-crypt files"
      When call generate_certificates
      The status should be success
      The stdout should end with "Downloading ProtonVPN Certificates..."
      The contents of file $OPENVPN_CA_FILE should start with "-----BEGIN CERTIFICATE-----"
      The contents of file $OPENVPN_TLS_CRYPT_FILE should start with "-----BEGIN OpenVPN Static key V1-----"
    End

    It "skips download if files already present"
      OPENVPN_CA_FILE="$DATA/ca.crt"
      OPENVPN_TLS_CRYPT_FILE="$DATA/ta.key"
      When call generate_certificates
      The status should be success
      The stdout should not end with "Downloading ProtonVPN Certificates..."
    End

    It "fails gracefully with invalid url"
      PROTON_API_URL="https://invalid-api-url"
      When call generate_certificates
      The status should be failure
      The stdout should end with "Downloading ProtonVPN Certificates..."
      The stderr should end with "Failed to download certificates!"
      The file $OPENVPN_CA_FILE should not be exist
      The file $OPENVPN_TLS_CRYPT_FILE should not be exist
    End
  End

  Describe "start_openvpn"
    PROTON_SERVER_FILE="$DATA/servers.json"
    OPENVPN_CONFIG_FILE="$TMP/test.ovpn"
    OPENVPN_USER_PASS_FILE="$TMP/test.auth"
    openvpn() { >&2 echo "$*"; }

    It "executes with config and filtered servers"
      When call start_openvpn
      The status should be success
      The stderr should equal "--config $OPENVPN_CONFIG_FILE --auth-user-pass $OPENVPN_USER_PASS_FILE --remote 127.0.0.1"
    End

    It "accepts server count"
      VPN_SERVER_COUNT=2
      When call start_openvpn
      The status should be success
      The stderr should end with "--remote 127.0.0.1 --remote 127.0.0.2"
    End

    It "passes extra args"
      OPENVPN_EXTRA_ARGS="--test me tender"
      When call start_openvpn
      The stderr should end with "$OPENVPN_EXTRA_ARGS"
    End
  End

  Describe "wait_for_new_ip"
    CONNECT_TIMEOUT=1
    It "continues when IP changed"
      wget() { echo '{"ip": "'"$RANDOM"'", "country": "TestCountry", "asn": "TestProvider"}'; }
      When call wait_for_new_ip
      The status should be success
      The line 1 of stdout should match pattern "* Old IP: * TestCountry (TestProvider)"
      The line 2 of stdout should match pattern "* New IP: * TestCountry (TestProvider)"
    End

    It "times out"
      wget() { echo '{"ip": "1.2.3.4", "country": "TestCountry", "asn": "TestProvider"}'; }
      When call wait_for_new_ip
      The status should be failure
      The stdout should match pattern "* Old IP: * * (*)"
      The stderr should end with "Timed out waiting for IP change, reconnecting..."
    End

    It "skips if URL not set"
      IP_CHECK_URL=
      When call wait_for_new_ip
      The status should be success
      The stdout should not include "Old IP"
    End

    It "skips if URL invalid"
      IP_CHECK_URL="https://invalid-api-url"
      When call wait_for_new_ip
      The status should be failure
      The stderr should end with "Failed to get old IP, skipping IP check."
    End
  End

  Describe "wait_for_reconnect"
    It "doesn't wait if reconnect not set"
      When call wait_for_reconnect
      The status should be success
      The stdout should not include "Reconnecting on"
    End

    Describe "waits until"
      Parameters
        "00:00:00" "00:00:00" "*"
        "05:55" "05:55:00" "*"
        "23:59:59" "23:59:59" "*"
        "10" "*" "10"
        "20s" "*" "20"
        "20m" "*" "$((20 * 60))"
        "48h" "*" "$((48 * 60 * 60))"
        "6d" "*" "$((6 * 24 * 60 * 60))"
        "5d 5h 20m 12s" "*" "$((5 * 24 * 60 * 60 + 5 * 60 * 60 + 20 * 60 + 12))"
      End
      Example "$1"
        VPN_RECONNECT="$1"
        When call wait_for_reconnect 696969 #pass invalid process id so we don't actually have to wait
        The status should be success
        The stdout should match pattern "* Reconnecting on ????-??-?? $2 ($3 sec)"
      End
    End

    It "waits only until provided process terminates"
      Skip if "wait -n not available in ubuntu busybox but is in alpine" [ ! "$BASH" ]
      sleep_wait() {
        sleep 1 &
        wait_for_reconnect $!
      }
      VPN_RECONNECT="10"
      When call sleep_wait
      The status should be success
      The stdout should end with "($VPN_RECONNECT sec)"
    End
  End

  Describe "setup_split_tunnel"
    RESOLVER_CONFIG="$DATA/resolv.conf"
    EXTERNAL_USER="testuser"
    gateway="137.137.137.137"
    nsport="69696"

    iptables() { >&2 echo "iptables $*"; }
    ip() {
      >&2 echo "ip $*"
      [[ "$*" == "route" ]] && echo "default via $gateway dev eth0"
    }
    netstat() {
      echo "Active Internet connections (servers and established)
            Proto Recv-Q Send-Q Local Address
            udp        0      0 0.0.0.0:11111
            udp        0      0 127.0.0.11:$nsport"
    }

    It "should configure iptables"
      When call setup_split_tunnel
      The status should be success
      The line 1 of stderr should equal "ip route"
      The line 2 of stderr should equal "iptables -t mangle -A OUTPUT -m owner --uid-owner $EXTERNAL_USER -j MARK --set-mark 1"
      The line 3 of stderr should equal "iptables -A OUTPUT -m mark --mark 1 -j ACCEPT"
      The line 4 of stderr should equal "ip rule add fwmark 1 table 1"
      The line 5 of stderr should equal "ip route add default via $gateway table 1"
      The line 6 of stderr should equal "iptables -t nat -A OUTPUT -m mark --mark 1 -p udp --dport 53 -j DNAT --to-destination 127.0.0.11:$nsport"
      The line 7 of stderr should equal "iptables -t nat -A POSTROUTING -o eth+ -j MASQUERADE"
    End
  End

  Describe "create_user_pass_file"
    OPENVPN_USER="new_test_user"
    OPENVPN_PASS="new_test_pass"

    It "should write user & pass to file if it doesn't exist"
      OPENVPN_USER_PASS_FILE="$TMP/test.auth"
      When call create_user_pass_file
      The status should be success
      The contents of file $OPENVPN_USER_PASS_FILE should equal $OPENVPN_USER$'\n'$OPENVPN_PASS
    End

    It "should not overwrite if file already exists"
      OPENVPN_USER_PASS_FILE="$DATA/userpass.auth"
      When call create_user_pass_file
      The status should be success
      The contents of file $OPENVPN_USER_PASS_FILE should equal $'test_user\ntest_pass'
    End
  End

  Describe "kill_process"
    It "should return when process not active"
      When call kill_process "invalid_process"
      The status should be success
    End
    It "should kill process if running"
      sleep_kill() {
        timeout 10 sleep 10 &
        kill_process timeout
      }
      When call sleep_kill
      The status should be success
      The stdout should end with "Stopping timeout..."
      Assert process_killed timeout
    End
  End

  Describe "main"
    It "does everything in order"
      iptables() { return; }
      ip() { return; }
      openvpn() { return; }
      wget() { return; }
      wait_for_new_ip() { return; }

      tinyproxy() { >&2 echo "tinyproxy $*"; }
      Mock iptables-restore #somehow won't work as function mock
        >&2 echo "iptables-restore $*"
      End

      EXIT_ON_DISCONNECT=1
      OPENVPN_USER_PASS_FILE="$TMP/test.auth"
      PROTON_SERVER_FILE="$TMP/servers.json"
      OPENVPN_CA_FILE="$TMP/ca.crt"
      OPENVPN_TLS_CRYPT_FILE="$TMP/ta.key"
      HTTP_PROXY=1

      When call main
      The status should be success
      The line 1 of stdout should end with "Kill Switch enabled"
      The line 2 of stdout should end with "Starting Proxy..."
      The line 3 of stdout should end with "Fetching ProtonVPN Server List..."
      The line 4 of stdout should end with "Downloading ProtonVPN Certificates..."
      The line 5 of stdout should end with "Starting OpenVPN..."
      The line 1 of stderr should end with "iptables-restore /etc/iptables/killswitch.rules"
      The line 2 of stderr should end with "tinyproxy -d"
      The line 3 of stderr should end with "No servers found!"
      The line 4 of stderr should end with "Failed to download certificates!"
    End
  End
End
