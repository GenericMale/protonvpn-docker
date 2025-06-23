#!/usr/bin/env python

import asyncio
import getpass
import json
import os
import sys

# proton creates Proton dir below xdg basedirs on import
os.environ["XDG_RUNTIME_DIR"] = os.environ["XDG_CONFIG_HOME"] = os.environ["XDG_CACHE_HOME"] = "/etc/openvpn"

from proton.vpn.core.api import ProtonVPNAPI
from proton.vpn.core.session_holder import ClientTypeMetadata

async def main():
    user_pass_file = os.environ.get("OPENVPN_USER_PASS_FILE", "/etc/openvpn/protonvpn.auth")
    server_file = os.environ.get("PROTON_SERVER_FILE", "/etc/openvpn/servers.json")
    username = os.environ.get("PROTON_USER")
    password = os.environ.get("PROTON_PASS")
    twofa_code = os.environ.get("PROTON_2FA")

    try:
        api = ProtonVPNAPI(ClientTypeMetadata(type="protonvpn-docker", version="99.99.99"))
        if not api.is_user_logged_in():
            if not username:
                username = input("Proton Username: ")

            if not password:
                password = getpass.getpass()

            login = await api.login(username, password)

            if login.twofa_required:
                if not twofa_code:
                    twofa_code = input("2FA code: ")

                login = await api.submit_2fa_code(twofa_code)
            
            if not login.success:
                sys.exit("Error: Authentication failed.")

        with open(user_pass_file, "w", encoding="utf-8") as f:
            vpn_credentials = api.account_data.vpn_credentials.userpass_credentials
            f.write(f"{vpn_credentials.username}\n{vpn_credentials.password}")

        with open(server_file, "w", encoding="utf-8") as f:
            json.dump(api.server_list.to_dict(), f)

    except Exception as e:
        sys.exit(f"Error: {e}")

if __name__ == "__main__":
    asyncio.run(main())
