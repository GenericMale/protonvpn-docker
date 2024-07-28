# ProtonVPN Docker Image

[![](https://img.shields.io/github/license/GenericMale/protonvpn-docker)](https://github.com/GenericMale/protonvpn-docker/blob/main/LICENSE)
[![](https://github.com/GenericMale/protonvpn-docker/actions/workflows/docker-publish.yml/badge.svg?label=build)](https://github.com/GenericMale/protonvpn-docker/actions/workflows/docker-publish.yml)
[![](https://ghcr-badge.egpl.dev/GenericMale/protonvpn-docker/tags?ignore=)](https://github.com/GenericMale/protonvpn-docker/pkgs/container/protonvpn-docker/versions)
[![](https://ghcr-badge.egpl.dev/GenericMale/protonvpn-docker/size)](https://github.com/users/GenericMale/packages/container/package/protonvpn-docker)

This Docker image provides a lightweight and secure solution to connect your containers to ProtonVPN.

## Features

- **Minimal Footprint:** Built on Alpine Linux for a compact image size.
- **Flexible Server Selection:** Use JQ filters for granular control over servers with random selection.
- **Automatic Server Rotation (Optional):** Schedule automatic reconnection to switch servers periodically.
- **Multi-Container Support:** Easily connect any number of containers to the VPN.
- **Kill Switch:** Disconnect containers on VPN drop.

## Usage

1. **Obtain OpenVPN Credentials:** Get your credentials from your ProtonVPN account: [https://account.proton.me/u/0/vpn/OpenVpnIKEv2](https://account.proton.me/u/0/vpn/OpenVpnIKEv2).
2. **Configure Credentials:** Choose one of the following methods:
   - **Secrets File:** Create a file containing your username and password on separate lines. Set the `AUTH_USER_PASS_FILE` environment variable to the file path.
   - **Environment Variables:** Define the `OPENVPN_USER` and `OPENVPN_PASS` environment variables with your credentials.
3. **Connect Containers:** Use the `network_mode: service:protonvpn` option in your Docker Compose configuration for containers requiring VPN access.

**Important Note on Port Mapping:**
Since containers share the network stack when using `network_mode`, the port mappings for services requiring external access need to be defined on the ProtonVPN container.

### Example Docker Compose File

```yaml
services:
    protonvpn:
        image: ghcr.io/genericmale/protonvpn-docker:latest
        restart: unless-stopped
        environment:
            - OPENVPN_USER_PASS_FILE=/run/secrets/protonvpn
            - VPN_RECONNECT=2:00
            - VPN_SERVER_COUNT=10
        ports:
            - 8118:8118 # Privoxy Port
        volumes:
            - /etc/localtime:/etc/localtime:ro
        devices:
            - /dev/net/tun
        cap_add:
            - NET_ADMIN
        secrets:
            - protonvpn
    privoxy:
        image: vimagick/privoxy:latest
        restart: unless-stopped
        network_mode: service:protonvpn
        depends_on:
          protonvpn:
            condition: service_healthy
secrets:
    protonvpn:
        file: protonvpn.auth
```

This configuration achieves the following:

- Uses `VPN_SERVER_COUNT=10` to randomly selects one of the 10 fastest servers.
- Schedules reconnection at 2:00 AM with `VPN_RECONNECT=2:00` to rotate servers.
- Runs a Privoxy container attached to the VPN network. (`network_mode: service:protonvpn`)
- Privoxy is not started until the VPN is connected with `depends_on` and `condition: service_healthy`.
- Exposes Privoxy's port (8118) for clients to connect to the VPN using Privoxy as a forward proxy.
  Notice the port mapping on the ProtonVPN container.

### Environment Variables

| Variable               | Default                     | Description                                                                                                                                  |
|------------------------|-----------------------------|----------------------------------------------------------------------------------------------------------------------------------------------|
| OPENVPN_USER_PASS_FILE | /etc/openvpn/protonvpn.auth | Path to a file containing your OpenVPN username and password on separate lines.                                                              |
| OPENVPN_USER           | *(undefined)*               | Username for authentication. Will be used to create `OPENVPN_USER_PASS_FILE` if it doesn't exist.                                            |
| OPENVPN_PASS           | *(undefined)*               | Password for authentication. Will be used to create `OPENVPN_USER_PASS_FILE` if it doesn't exist.                                            |
| PROTON_TIER            | 2                           | Your Proton Tier. Valid values: 0 (Free), 1 (Basic), 2 (Plus), 3 (Visionary)                                                                 |
| IP_CHECK_URL           | https://ifconfig.co/json    | URL to check for your new IP address after connecting to the VPN. Unset to disable.                                                          |                                                                                                                              
| VPN_SERVER_FILTER      | .                           | Optional JQ filter to apply to the server list returned by the API. By default, servers are ranked by their score (closest/fastest on top).  |
| VPN_SERVER_COUNT       | 1                           | Number of top servers (from the filtered list) to pass to OpenVPN. One server from this list will be randomly chosen for connection.         |
| VPN_RECONNECT          | *(undefined)*               | Optional time to schedule automatic reconnection. Either HH:MM for a daily reconnect at a fixed time, or a duration to wait (e.g. 30m, 12h). |
| VPN_KILL_SWITCH        | 1                           | When enabled (1), disconnects the network when the VPN drops. Set to 0 to disable.                                                           |

### JQ Filters for Advanced Server Selection

The `VPN_SERVER_FILTER` environment variable allows you to filter available ProtonVPN servers using JQ queries.

Some examples:

```yaml
# Fastest Servers from Germany
- VPN_SERVER_FILTER=map(select(.ExitCountry == "DE"))

# Servers with Lowest Load
- VPN_SERVER_FILTER=sort_by(.Load)

# Specific server
- VPN_SERVER_FILTER=map(select(.Name == "GR#3"))

# Fastest Servers from Berlin with Load <50%
- VPN_SERVER_FILTER=map(select(.City == "Berlin" and .Load < 50))

# Fastest Servers from Different Countries
- VPN_SERVER_FILTER=group_by(.ExitCountry) | map(.[0]) | sort_by(.Score)

```

## Building

To build the image, the following command can be used (adapt tag name to your liking):

```sh
docker image build . -t protonvpn-docker
```

## Additional Resources

- Docker Compose Overview: https://docs.docker.com/compose/
- ProtonVPN Documentation: https://protonvpn.com/support/linux-openvpn/
- OpenVPN Reference Manual: https://openvpn.net/community-resources/reference-manual-for-openvpn-2-6/
- JQ Manual: https://jqlang.github.io/jq/manual/
