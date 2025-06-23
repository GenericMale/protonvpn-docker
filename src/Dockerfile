FROM python:3.13-alpine

WORKDIR /etc/openvpn/

ENV PYTHONUNBUFFERED=1
ENTRYPOINT ["./docker-entrypoint.sh"]
HEALTHCHECK --start-period=1m --start-interval=1s --retries=1 \
  CMD ["./healthcheck.sh"]

EXPOSE 3128/tcp
VOLUME /etc/openvpn/Proton

RUN apk add --no-cache openvpn tinyproxy iptables jq gpg

ADD https://github.com/ProtonVPN/python-proton-core.git#v0.4.0 /tmp/python-proton-core
ADD https://github.com/ProtonVPN/python-proton-vpn-api-core.git#v0.42.4 /tmp/python-proton-vpn-api-core
RUN pip install pyxdg /tmp/python-proton-core /tmp/python-proton-vpn-api-core && \
    rm -rf /tmp/python-proton-core /tmp/python-proton-vpn-api-core

COPY killswitch.rules /etc/iptables/
COPY tinyproxy.conf /etc/tinyproxy/
COPY docker-entrypoint.sh protonvpn.ovpn healthcheck.sh protonvpn.py ca.crt ta.key ./
RUN chmod +x docker-entrypoint.sh healthcheck.sh protonvpn.py && \
    chown openvpn:openvpn . Proton
