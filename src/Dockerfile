FROM alpine:3.20

RUN apk add --no-cache openvpn iptables jq

WORKDIR /etc/openvpn/

COPY docker-entrypoint.sh protonvpn.ovpn healthcheck.sh ./
RUN chmod +x docker-entrypoint.sh healthcheck.sh

HEALTHCHECK --start-period=1m --start-interval=1s --retries=1 CMD ["./healthcheck.sh"]
ENTRYPOINT ["./docker-entrypoint.sh"]
