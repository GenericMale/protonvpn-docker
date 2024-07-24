# ProtonVPN Docker Image

[![](https://img.shields.io/github/license/GenericMale/protonvpn-docker)](https://github.com/GenericMale/protonvpn-docker/blob/main/LICENSE)
[![](https://github.com/GenericMale/protonvpn-docker/actions/workflows/docker-publish.yml/badge.svg?label=build)](https://github.com/GenericMale/protonvpn-docker/actions/workflows/docker-publish.yml)
[![](https://ghcr-badge.egpl.dev/GenericMale/protonvpn-docker/tags?ignore=&n=10)](https://github.com/GenericMale/protonvpn-docker/pkgs/container/protonvpn-docker/versions)
[![](https://ghcr-badge.egpl.dev/GenericMale/protonvpn-docker/size)](https://github.com/users/GenericMale/packages/container/package/protonvpn-docker)

Minimal ProtonVPN Docker Image for use with other Containers.

## Features

- Based on Alpine and under 10MB image size.
- Supports any server selection criteria including random selection.
- DNS leak protection
- Kill Switch
- Easily connect any number of containers.
- Scheduled reconnection to enable automatic server switch.

## Usage

Get your OpenVPN Credentials from [account.proton.me/u/0/vpn/OpenVpnIKEv2](https://account.proton.me/u/0/vpn/OpenVpnIKEv2).
You can either use a secrets file which has username and password on two lines by setting `AUTH_USER_PASS_FILE`
like in the following example or alternatively configure the `OPENVPN_USER` and `OPENVPN_PASS` environment variables.

```yaml
services:
    protonvpn:
        image: ghcr.io/genericmale/protonvpn-docker:latest
        restart: unless-stopped
        environment:
            - OPENVPN_USER_PASS_FILE=/run/secrets/protonvpn
            - VPN_RECONNECT=2:00
            - VPN_SERVER_COUNT=10
        volumes:
            - /etc/localtime:/etc/localtime:ro
        devices:
            - /dev/net/tun
        cap_add:
            - NET_ADMIN
        secrets:
            - protonvpn
secrets:
    protonvpn:
        file: protonvpn.auth
```

To connect a container to the VPN, use `network_mode: service:protonvpn` on the other container, for example:

```yaml
services:
    searxng:
        image: searxng/searxng
        network_mode: service:protonvpn
```
**Important**: You need to perform all port mappings on the protonvpn container when you set the `network_mode`
because they are sharing a network stack.

### Environment variables

| Variable               | Default                               | Description                                                                                                                                                              |
|------------------------|---------------------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| OPENVPN_USER_PASS_FILE | /etc/openvpn/protonvpn.auth           | File containing the OpenVPN credentials. If it doesn't exist it is created from `OPENVPN_USER` and `OPENVPN_PASS`.                                                       |
| OPENVPN_USER           |                                       | see `OPENVPN_USER_PASS_FILE`                                                                                                                                             |
| OPENVPN_PASS           |                                       | see `OPENVPN_USER_PASS_FILE`                                                                                                                                             |
| PROTON_TIER            | 2                                     | Your Proton Tier. 0 = Free, 1 = Basic, 2 = Plus, 3 = Visionary                                                                                                           |
| PROTON_API_URL         | https://api.protonvpn.ch/vpn/logicals | API to query for servers.                                                                                                                                                |
| IP_URL                 | https://ifconfig.co/json              | URL to check for new IP. Unset to disable.                                                                                                                               |                                                                                                                              
| VPN_SERVER_FILTER      | .                                     | Additional filter to apply to the server list. By default the servers are ranked by score (e.g. the closest/fastest is on top).                                          |
| VPN_SERVER_COUNT       | 1                                     | The number of top servers from the filtered server list to pass to OpenVPN, from which one is randomly chosen.                                                           |
| VPN_RECONNECT          |                                       | Optional reconnect time. Can be either HH:MM to trigger a daily reconnect at a fixed time, or a relative time to wait after a connection has been established (e.g. 6h). |

#### Example Server Filters

Some examples for the `VPN_SERVER_FILTER`:

```yaml

# Fastest Servers from Germany
- VPN_SERVER_FILTER=map(select(.ExitCountry == "DE"))

# Servers with the lowest load
- VPN_SERVER_FILTER=sort_by(.Load)

# Fastest Servers from Berlin with a load below 50%
- VPN_SERVER_FILTER=map(select(.City == "Berlin" and .Load < 50))

# Fastest Servers but from different countries
- VPN_SERVER_FILTER=group_by(.ExitCountry) | map(.[0]) | sort_by(.Score)

```

## Building

To build the image, the following command can be used (adapt tag name to your liking):

```sh
docker image build . -t protonvpn-docker
```
