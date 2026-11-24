"""E2E tests around Internet independence of commissioning.

Real flow being modeled (see pkg/gateway/wifi.go, onboarding.go):
1. First boot with NO Internet: the Hevea add-on images are baked into the
   image's data partition (hevea-gateway.mk: skopeo tarballs embedded by
   create-data-partition.sh) and apps.json marks them installed, so the
   Supervisor starts them from the local docker store without pulling from
   ghcr.io. The gateway portal (port 9000) and the access point come up
   offline. The bootstrap does not set its completion marker while GitHub is
   unreachable, so it re-runs on the next online boot.
2. The user enters the site WiFi credentials in the portal (POST
   /api/v1/networks + PUT /api/v1/networks/{id} state=true): the RPi joins the
   WiFi via NetworkManager and gets Internet through it.
3. Commissioning (POST /api/v1/commission -> site config zip from the app ->
   OpenVPN add-on -> VPN tunnel -> HA first boot) then runs; the VPN tunnel
   is what provides Internet egress afterwards.

Tests:
- test_offline_first_boot_wifi_provisioning: blocks public egress + default
  route as soon as the shell is up (public allowed only via wlan0), verifies
  the portal answers offline, provisions the WiFi from the env vars, checks
  Internet comes back via wlan0, then runs the full commissioning. RPi4 only
  (needs a wlan interface); needs HEVEA_WIFI_SSID / HEVEA_WIFI_PASSWORD.
- test_commission_without_internet: blocks ALL public egress (even via
  wlan0), then commissions fully offline — in the lab the app and VPN server
  are on the host LAN, so commissioning only needs private addresses.

All blocks are lifted in finally blocks, even on failure.
"""

import logging
import os

import pytest
import requests

from hevea_test import commission_common as cc


_LOGGER = logging.getLogger(__name__)

# Public addresses used to prove egress is blocked / restored
EXTERNAL_PING_IP = "8.8.8.8"
EXTERNAL_URL = "https://github.com/hevea-project/hassio-apps"

PRIVATE_RANGES = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16"]


def _shell_text(shell, cmd):
    out = shell.run(cmd)
    lines = out[0] if isinstance(out, tuple) else out
    return "\n".join(lines)


def _default_route(shell):
    """(gateway, iface) of the current default route, or ("", "")."""
    gw = _shell_text(shell, "ip route show default | awk '{print $3}' | head -1").strip()
    iface = _shell_text(shell, "ip route show default | awk '{print $5}' | head -1").strip()
    return gw, iface


def _install_offline_chain(shell, allow_public_iface=None):
    """iptables chain HEVEA_OFFLINE: lo + private ranges always allowed,
    public egress dropped except on allow_public_iface (e.g. wlan0)."""
    shell.run_check("iptables -N HEVEA_OFFLINE 2>/dev/null || true")
    shell.run_check("iptables -F HEVEA_OFFLINE")
    shell.run_check("iptables -A HEVEA_OFFLINE -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT")
    shell.run_check("iptables -A HEVEA_OFFLINE -o lo -j ACCEPT")
    for net in PRIVATE_RANGES:
        shell.run_check(f"iptables -A HEVEA_OFFLINE -d {net} -j ACCEPT")
    if allow_public_iface:
        shell.run_check(f"iptables -A HEVEA_OFFLINE -o {allow_public_iface} -j ACCEPT")
    shell.run_check("iptables -A HEVEA_OFFLINE -j DROP")
    shell.run_check("iptables -C OUTPUT -j HEVEA_OFFLINE 2>/dev/null || iptables -I OUTPUT 1 -j HEVEA_OFFLINE")


def _remove_offline_chain(shell):
    shell.run_check("iptables -D OUTPUT -j HEVEA_OFFLINE 2>/dev/null || true")
    shell.run_check("iptables -F HEVEA_OFFLINE 2>/dev/null || true")
    shell.run_check("iptables -X HEVEA_OFFLINE 2>/dev/null || true")
    left = _shell_text(shell, "iptables -S OUTPUT | grep -c HEVEA_OFFLINE || true").strip()
    assert left == "0", "HEVEA_OFFLINE rules still present in OUTPUT"


def _block_internet(shell, allow_public_iface=None, delete_default_route=True):
    """Block public egress. Returns (gw, iface) of the removed default route."""
    gw, iface = _default_route(shell)
    _install_offline_chain(shell, allow_public_iface)
    if delete_default_route and gw:
        shell.run_check("ip route del default")
    _LOGGER.info("Internet blocked (gw=%s iface=%s, public allowed via %s)",
                 gw, iface, allow_public_iface or "nothing")
    return gw, iface


def _restore_internet(shell, gw, iface):
    _remove_offline_chain(shell)
    if gw and iface:
        shell.run(f"ip route add default via {gw} dev {iface} 2>/dev/null || true")
    out = _shell_text(shell, "ip route show default | head -1").strip()
    assert out, "default route not restored"
    _LOGGER.info("Internet restored (default via %s dev %s)", gw, iface)


def _public_reachable(shell):
    return "0% packet loss" in _shell_text(
        shell, f"ping -c 1 -W 3 {EXTERNAL_PING_IP} 2>/dev/null || true"
    ) or "200" in _shell_text(
        shell, f"curl -s -m 8 -o /dev/null -w '%{{http_code}}' {EXTERNAL_URL} 2>/dev/null || echo 000"
    )


def _assert_offline(shell, gw):
    assert not _public_reachable(shell), "public egress still works (block failed?)"
    if gw:
        out = _shell_text(shell, f"ping -c 1 -W 2 {gw} >/dev/null 2>&1 && echo GW_OK || echo GW_FAIL")
        assert "GW_OK" in out, f"LAN broken after offline block (gw {gw} unreachable)"
    _LOGGER.info("Target is offline: public unreachable, LAN gateway reachable")


def _assert_online(shell):
    cc.wait_for(lambda: _public_reachable(shell), timeout=60,
                interval=5, description="public egress works (via WiFi)")
    _LOGGER.info("Target is online again (public egress via WiFi)")


def _wlan_iface(shell):
    out = _shell_text(shell, "ip link show | awk -F': ' '{print $2}'")
    for name in out.split():
        if name.startswith("wlan"):
            return name
    return None


@pytest.mark.timeout(900)
def test_offline_first_boot_wifi_provisioning(shell, shell_json, app_token_and_site):
    """Offline first boot -> WiFi provisioning via the portal -> online ->
    commissioning. RPi4 only (needs a wlan interface)."""
    ssid = os.environ.get("HEVEA_WIFI_SSID", "")
    password = os.environ.get("HEVEA_WIFI_PASSWORD", "")
    if not ssid or not password:
        pytest.skip("HEVEA_WIFI_SSID / HEVEA_WIFI_PASSWORD not set (lab WiFi credentials)")
    wlan = _wlan_iface(shell)
    if not wlan:
        pytest.skip("no wlan interface on this target (QEMU has no WiFi chipset)")

    # Block Internet as early as possible: the add-on images are baked in the
    # image, so the gateway must come up offline from the local docker store.
    gw, iface = _block_internet(shell, allow_public_iface=wlan)
    try:
        _assert_offline(shell, gw)

        # Supervisor + gateway add-on come up offline (baked images, no pull)
        cc.wait_system_ready(shell)
        cc.wait_for(lambda: cc.find_gateway_slug(shell_json), timeout=600,
                    description="gateway add-on installed (offline, baked image)")
        def gw_started():
            apps = shell_json("ha apps --raw-json")
            gw = next((a for a in apps.get("data", {}).get("addons", [])
                       if a.get("slug", "").endswith("_hassio-gateway")), None)
            return gw and gw.get("state") in ("started", "starting")
        cc.wait_for(gw_started, timeout=300, description="gateway add-on started offline")

        # The portal answers while offline (reached over the LAN from the host)
        r = requests.get(f"{cc.GATEWAY_VM_URL}/", timeout=15)
        assert r.status_code == 200, f"portal not reachable offline: {r.status_code}"
        _LOGGER.info("Gateway portal answers while offline (status %s)", r.status_code)

        # User enters the WiFi credentials in the portal
        r = requests.post(f"{cc.GATEWAY_VM_URL}/api/v1/networks",
                          json={"ssid": ssid, "password": password}, timeout=30)
        assert r.status_code == 201, f"POST /api/v1/networks: {r.status_code} {r.text[:200]}"
        net_id = r.json()["id"]
        r = requests.put(f"{cc.GATEWAY_VM_URL}/api/v1/networks/{net_id}",
                         json={"state": True}, timeout=30)
        assert r.status_code == 200, f"PUT /api/v1/networks/{net_id}: {r.status_code} {r.text[:200]}"
        _LOGGER.info("WiFi credentials submitted, connecting to SSID %s via %s", ssid, wlan)

        # RPi joins the WiFi: wlan0 gets an IP and the default route
        def wifi_up():
            ip = _shell_text(shell, f"ip -4 addr show {wlan} 2>/dev/null | grep inet")
            route = _shell_text(shell, f"ip route show default | grep {wlan}")
            return bool(ip.strip()) and bool(route.strip())
        cc.wait_for(wifi_up, timeout=180, interval=5, description=f"{wlan} connected with default route")

        # Internet is back, via the WiFi
        _assert_online(shell)

        # Commissioning now runs (online via WiFi, app on the LAN)
        token, site_id = app_token_and_site
        local_app_addr = os.environ.get("HEVEA_VM_APP_ADDR", "http://10.0.2.2:7030")
        cc.point_gateway_at_app(shell, shell_json, local_app_addr)
        cc.reset_ha_onboarding(shell)
        cc.commission(shell, token, site_id)
        cc.wait_for(lambda: cc.openvpn_addon_started(shell_json), timeout=180,
                    description="OpenVPN add-on started")
        cc.assert_vpn_ping(shell)
        reason = cc.ha_auth_provider_missing_reason(shell)
        if reason:
            pytest.skip(reason)
        cc.wait_for(lambda: cc.ha_login_flow_ok(shell), timeout=180,
                    description="HA login with Hevea credentials")
        _LOGGER.info("Offline-boot -> WiFi provisioning -> commissioning: OK")
    finally:
        _restore_internet(shell, gw, iface)


@pytest.mark.timeout(900)
def test_commission_without_internet(shell, shell_json, app_token_and_site):
    """Commissioning succeeds with ALL public egress blocked on the target.

    Preparation (pointing app_addr, resetting the HA onboarding) is done while
    still online — it is test-harness setup, not commissioning. The actual
    POST /api/v1/commission, the OpenVPN tunnel and the HA login all run with
    egress blocked; in the lab, app + VPN server are on the host LAN.
    """
    token, site_id = app_token_and_site
    cc.wait_system_ready(shell)
    cc.wait_for(lambda: cc.find_gateway_slug(shell_json), timeout=600,
                description="gateway add-on installed")
    local_app_addr = os.environ.get("HEVEA_VM_APP_ADDR", "http://10.0.2.2:7030")
    cc.point_gateway_at_app(shell, shell_json, local_app_addr)
    cc.reset_ha_onboarding(shell)

    gw, iface = _block_internet(shell)  # no allow_public_iface: full block
    try:
        _assert_offline(shell, gw)

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
