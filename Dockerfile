FROM alpine:3.20

RUN apk add --no-cache openvpn iptables jq

COPY protonvpn.ovpn route-up.sh /etc/openvpn/

COPY docker-entrypoint.sh /
RUN chmod +x /docker-entrypoint.sh /etc/openvpn/route-up.sh

ENTRYPOINT ["/docker-entrypoint.sh"]
