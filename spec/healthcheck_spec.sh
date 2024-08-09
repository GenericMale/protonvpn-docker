#
# Licensed under the EUPL-1.2 or later.
# You may obtain a copy of the licence at https://joinup.ec.europa.eu/collection/eupl/eupl-text-eupl-12
#

#shellcheck shell=sh disable=SC2317

Describe "healthcheck.sh"
  It "should exit with success for valid IP"
    ip() {
      echo "2: tun0: <POINTOPOINT,MULTICAST,NOARP,UP,LOWER_UP> mtu 1500 qdisc fq_codel state UNKNOWN group default qlen 1000
                inet 10.96.0.10/16 scope global tun0
                   valid_lft forever preferred_lft forever"
    }
    When run source src/healthcheck.sh
    The status should be success
  End

  It "should exit with failure for invalid IP"
    ip() {
      echo "2: tun0: <POINTOPOINT,MULTICAST,NOARP,UP,LOWER_UP> mtu 1500 qdisc fq_codel state UNKNOWN group default qlen 1000
                inet 12345678/90 scope global tun0
                   valid_lft forever preferred_lft forever"
    }
    When run source src/healthcheck.sh
    The status should be failure
  End

  It "should exit with failure when tun0 does not exist"
    ip() {
      echo ""
    }
    When run source src/healthcheck.sh
    The status should be failure
  End
End
