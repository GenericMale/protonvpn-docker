function set_up() {
  SRC_DIR="$(dirname "${BASH_SOURCE[0]}")/../src"
}

function test_missing_device() {
  spy ip
  assert_exit_code "1" "$SRC_DIR/healthcheck.sh"
  assert_have_been_called_times 1 ps
  assert_have_been_called_with "-4 addr show tun0" ip
}

function test_success() {
  mock ip<<EOF
2: tun0: <POINTOPOINT,MULTICAST,NOARP,UP,LOWER_UP> mtu 1500 qdisc fq_codel state UNKNOWN group default qlen 1000
    inet 10.96.0.12/16 scope global tun0
       valid_lft forever preferred_lft forever
EOF

  assert_exit_code "0" "$SRC_DIR/healthcheck.sh"
}
