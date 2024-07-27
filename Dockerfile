FROM alpine:3.20

RUN apk add --no-cache openvpn iptables jq

WORKDIR /etc/openvpn/

COPY docker-entrypoint.sh protonvpn.ovpn route-up.sh ./
RUN chmod +x docker-entrypoint.sh route-up.sh

ENTRYPOINT ["./docker-entrypoint.sh"]
