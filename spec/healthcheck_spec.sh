Describe "healthcheck.sh"
  It "fails when tun device doesn't exist"
    Mock ip
      echo ""
    End
    When run source src/healthcheck.sh
    The status should be failure
  End

  It "succeeds when tun device has ip"
    Mock ip
      echo "2: tun0: <POINTOPOINT,MULTICAST,NOARP,UP,LOWER_UP> mtu 1500 qdisc fq_codel state UNKNOWN group default qlen 1000
                inet 10.96.0.10/16 scope global tun0
                   valid_lft forever preferred_lft forever"
    End
    When run source src/healthcheck.sh
    The status should be success
  End
End
