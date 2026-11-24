"""End-to-end commissioning test against the target (QEMU VM or physical RPi4).

Prerequisites:
- docker-compose stack running on the host (app on :7030)
- target booted (QEMU: hevea-strategy.yaml; RPi4: hevea-rpi-pxe-strategy.yaml)

The target reaches the host app via 10.0.2.2 (QEMU user-mode NAT) or
HEVEA_VM_APP_ADDR (RPi: the host's LAN IP); the gateway portal is reached from
the host at HEVEA_GATEWAY_VM_URL (localhost:19000 for QEMU hostfwd,
http://<rpi-ip>:9000 for the RPi).

Flow:
1. From the host: login to app -> get token + site_id (fixture app_token_and_site)
2. POST commission to the target's gateway
3. Verify inside the target: OpenVPN add-on configured and running, VPN IP assigned
4. Verify HA web UI accessible with the Hevea credentials

Shared helpers live in commission_common.py (also used by test_commission_offline.py).
"""

import logging
import os

import pytest

from hevea_test import commission_common as cc


_LOGGER = logging.getLogger(__name__)


@pytest.mark.timeout(600)
def test_commission_via_vm_gateway(shell, shell_json, app_token_and_site):
    """POST /api/v1/commission to the gateway on the target.

    First points the gateway's app_addr at the local docker-compose app
    via `hevea addon-options set` inside the gateway container.
    """
    token, site_id = app_token_and_site
    _LOGGER.info("Commissioning site %s via target gateway", site_id)

    cc.wait_system_ready(shell)
    local_app_addr = os.environ.get("HEVEA_VM_APP_ADDR", "http://10.0.2.2:7030")
    cc.point_gateway_at_app(shell, shell_json, local_app_addr)
    cc.reset_ha_onboarding(shell)
    cc.commission(shell, token, site_id)


@pytest.mark.timeout(300)
def test_openvpn_addon_configured(shell_json):
    """The OpenVPN add-on on the target received certificates and is running."""
    cc.wait_for(lambda: cc.openvpn_addon_started(shell_json), timeout=180,
                description="OpenVPN add-on started")


@pytest.mark.timeout(300)
def test_vpn_connectivity(shell):
    """The target has a VPN IP (10.8.0.x) and can ping the OpenVPN server."""
    cc.assert_vpn_ping(shell)


@pytest.mark.timeout(300)
def test_ha_login_with_hevea_credentials(shell):
    """HA web UI accepts the Hevea credentials via the command_line auth provider."""
    reason = cc.ha_auth_provider_missing_reason(shell)
    if reason:
        pytest.skip(reason)
    cc.wait_for(lambda: cc.ha_login_flow_ok(shell), timeout=180,
                description="HA login with Hevea credentials")
