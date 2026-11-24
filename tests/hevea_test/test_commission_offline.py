"""E2E commissioning WITHOUT Internet access on the target.

Why this matters: on first boot the hevea-gateway bootstrap adds the add-on
repository and installs the Hevea add-ons, and the Supervisor pulls the Docker
images from ghcr.io — that part requires Internet. Commissioning itself
(gateway portal -> app API -> OpenVPN add-on configuration -> HA command_line
auth provider) only uses LAN addresses in our setup (app_addr and the OpenVPN
remote are the host's LAN IP), so it must work fully offline.

This module blocks all non-LAN egress on the target with iptables (plus
removing the default route), then re-runs the commissioning flow and asserts
that the VPN tunnel comes up and HA accepts the Hevea credentials. Internet is
restored in a finally block, even on failure.

Runs after test_commission_e2e.py (alphabetical order); the add-ons are
already installed by the bootstrap at that point.
"""

import logging
import os

import pytest

from hevea_test import commission_common as cc


_LOGGER = logging.getLogger(__name__)

# TEST-NET-2 address: never routed on the LAN, used to prove egress is blocked
EXTERNAL_TEST_IP = "198.51.100.1"


def _block_internet(shell):
    """Block all non-LAN egress on the target. Returns (gateway, iface, prefix)."""
    gw = "\n".join(shell.run_check("ip route show default | awk '{print $3}' | head -1")).strip()
    iface = "\n".join(shell.run_check("ip route show default | awk '{print $5}' | head -1")).strip()
    prefix = "\n".join(
        shell.run_check(f"ip -4 -o addr show dev {iface} | awk '{{print $4}}' | head -1")
    ).strip()
    assert iface and prefix, "no default route/interface found on target"
    _LOGGER.info("Blocking Internet on target: gw=%s iface=%s lan=%s", gw, iface, prefix)
    # Custom chain so teardown only removes our own rules. ESTABLISHED is
    # accepted first so the running SSH session (and NBD) survive the block.
    # All PRIVATE ranges stay reachable: the LAN (app, VPN server, NBD/PXE
    # server, gateway), the docker bridges (the Supervisor API answers on
    # 172.30.32.2) and the VPN tunnel itself (10.8.0.0/24). Only public
    # egress is dropped — that is "no Internet".
    shell.run_check("iptables -N HEVEA_OFFLINE 2>/dev/null || true")
    shell.run_check("iptables -F HEVEA_OFFLINE")
    shell.run_check("iptables -A HEVEA_OFFLINE -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT")
    shell.run_check("iptables -A HEVEA_OFFLINE -o lo -j ACCEPT")
    shell.run_check(f"iptables -A HEVEA_OFFLINE -d {prefix} -j ACCEPT")
    shell.run_check("iptables -A HEVEA_OFFLINE -d 10.0.0.0/8 -j ACCEPT")
    shell.run_check("iptables -A HEVEA_OFFLINE -d 172.16.0.0/12 -j ACCEPT")
    shell.run_check("iptables -A HEVEA_OFFLINE -d 192.168.0.0/16 -j ACCEPT")
    shell.run_check("iptables -A HEVEA_OFFLINE -d 169.254.0.0/16 -j ACCEPT")
    shell.run_check("iptables -A HEVEA_OFFLINE -j DROP")
    shell.run_check("iptables -C OUTPUT -j HEVEA_OFFLINE 2>/dev/null || iptables -I OUTPUT 1 -j HEVEA_OFFLINE")
    if gw:
        shell.run_check("ip route del default")
    return gw, iface, prefix


def _restore_internet(shell, gw, iface):
    """Remove the offline rules and put the default route back."""
    shell.run_check("iptables -D OUTPUT -j HEVEA_OFFLINE 2>/dev/null || true")
    shell.run_check("iptables -F HEVEA_OFFLINE 2>/dev/null || true")
    shell.run_check("iptables -X HEVEA_OFFLINE 2>/dev/null || true")
    if gw:
        shell.run(f"ip route add default via {gw} dev {iface} 2>/dev/null || true")
    out = shell.run_check("ip route show default | head -1")
    assert "\n".join(out).strip(), "default route not restored"
    out = shell.run_check("iptables -S OUTPUT | grep -c HEVEA_OFFLINE || true")
    assert "\n".join(out).strip() == "0", "HEVEA_OFFLINE rules still present in OUTPUT"
    _LOGGER.info("Internet restored on target (default via %s dev %s)", gw, iface)


def _assert_offline(shell, gw):
    """External egress must fail, LAN (gateway) must still work."""
    out = shell.run(f"ping -c 1 -W 2 {EXTERNAL_TEST_IP} >/dev/null 2>&1 && echo ONLINE || echo OFFLINE")
    text = "\n".join(out[0] if isinstance(out, tuple) else out)
    assert "OFFLINE" in text, f"target still reaches {EXTERNAL_TEST_IP} (egress not blocked?)"
    if gw:
        out = shell.run(f"ping -c 1 -W 2 {gw} >/dev/null 2>&1 && echo GW_OK || echo GW_FAIL")
        text = "\n".join(out[0] if isinstance(out, tuple) else out)
        assert "GW_OK" in text, f"LAN broken after offline block (gw {gw} unreachable)"
    _LOGGER.info("Target is offline (external %s unreachable, LAN gateway reachable)", EXTERNAL_TEST_IP)


@pytest.mark.timeout(900)
def test_commission_without_internet(shell, shell_json, app_token_and_site):
    """Commissioning succeeds with no Internet on the target.

    Preparation (pointing app_addr, resetting the HA onboarding) is done while
    still online — it is test-harness setup, not commissioning. The actual
    POST /api/v1/commission, the OpenVPN tunnel and the HA login all run with
    egress blocked.
    """
    token, site_id = app_token_and_site
    cc.wait_system_ready(shell)
    cc.wait_for(lambda: cc.find_gateway_slug(shell_json), timeout=600,
                description="gateway add-on installed")
    local_app_addr = os.environ.get("HEVEA_VM_APP_ADDR", "http://10.0.2.2:7030")
    cc.point_gateway_at_app(shell, shell_json, local_app_addr)
    cc.reset_ha_onboarding(shell)

    gw, iface, prefix = _block_internet(shell)
    try:
        _assert_offline(shell, gw)

        # The commissioning itself, fully offline
        cc.commission(shell, token, site_id)

        cc.wait_for(lambda: cc.openvpn_addon_started(shell_json), timeout=180,
                    description="OpenVPN add-on started (offline)")
        cc.assert_vpn_ping(shell)  # VPN IP 10.8.x.x + ping 10.8.0.1, offline
        _LOGGER.info("Offline commissioning + VPN OK (no Internet needed)")

        # HA login via the command_line provider: skipped when the deployed
        # gateway add-on image predates the shim/args fixes (image property,
        # orthogonal to connectivity — same skip as test_commission_e2e).
        reason = cc.ha_auth_provider_missing_reason(shell)
        if reason:
            _LOGGER.warning("Skipping offline HA login check: %s", reason)
            pytest.skip(reason)
        cc.wait_for(lambda: cc.ha_login_flow_ok(shell), timeout=180,
                    description="HA login with Hevea credentials (offline)")
        _LOGGER.info("Offline HA login OK: commissioning fully works without Internet")
    finally:
        _restore_internet(shell, gw, iface)
