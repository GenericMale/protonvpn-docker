#shellcheck shell=sh disable=SC2034

Describe "docker-entrypoint.sh"
  DATA="./spec/data"
  TMP="./spec/tmp"
  BeforeEach "rm -rf $TMP && mkdir $TMP"

  Include "src/docker-entrypoint.sh"
  run_as_external() { eval "$1"; }

  Describe "download_servers"
    PROTON_SERVER_FILE="$TMP/servers.json"

    It "finds servers"
      When call download_servers
      The line 1 of stdout should end with "Fetching ProtonVPN Server List..."
      The line 2 of stdout should match pattern "* Found ???? servers."
      The file $PROTON_SERVER_FILE should not be empty file
    End

    It "applies filters"
      VPN_SERVER_FILTER='map(select(.Name == \"GR#3\"))'
      When call download_servers
      The line 2 of stdout should match pattern "* Found 1 servers."
    End

    It "filters by proton tier"
      PROTON_TIER=0
      When call download_servers
      The line 2 of stdout should match pattern "* Found ?? servers."
    End

    It "fails gracefully with invalid url"
      PROTON_API_URL="https://invalid-api-url"
      When call download_servers
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
      The stdout should end with "Downloading ProtonVPN Certificates..."
      The contents of file $OPENVPN_CA_FILE should start with "-----BEGIN CERTIFICATE-----"
      The contents of file $OPENVPN_TLS_CRYPT_FILE should start with "-----BEGIN OpenVPN Static key V1-----"
    End

    It "skips download if files already present"
      OPENVPN_CA_FILE="$DATA/ca.crt"
      OPENVPN_TLS_CRYPT_FILE="$DATA/ta.key"
      When call generate_certificates
      The stdout should not end with "Downloading ProtonVPN Certificates..."
    End

    It "fails gracefully with invalid url"
      PROTON_API_URL="https://invalid-api-url"
      When call generate_certificates
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
      The stderr should equal "--config $OPENVPN_CONFIG_FILE --auth-user-pass $OPENVPN_USER_PASS_FILE --remote 127.0.0.1"
      The stdout should equal $!
    End

    It "accepts server count"
      VPN_SERVER_COUNT=2
      When call start_openvpn
      The stderr should end with "--remote 127.0.0.1 --remote 127.0.0.2"
      The stdout should equal $!
    End

    It "passes extra args"
      OPENVPN_EXTRA_ARGS="--test me tender"
      When call start_openvpn
      The stderr should end with "$OPENVPN_EXTRA_ARGS"
      The stdout should equal $!
    End
  End

  Describe "wait_for_new_ip"
    It "continues when IP changed"
      wget() { echo '{"ip": "'$RANDOM'", "country": "TestCountry", "asn": "TestProvider"}'; }

      When call wait_for_new_ip
      The status should be success
      The line 1 of stdout should match pattern "* Old IP: * TestCountry (TestProvider)"
      The line 2 of stdout should match pattern "* New IP: * TestCountry (TestProvider)"
    End

    It "times out"
      CONNECT_TIMEOUT=1
      When call wait_for_new_ip
      The status should be failure
      The stdout should match pattern "* Old IP: * * (*)"
      The stderr should end with "Timed out waiting for IP change, reconnecting..."
    End
  End
End
