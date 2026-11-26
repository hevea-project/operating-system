#!/usr/bin/env python3
"""Onboard an already-booted RPi4 (or QEMU VM) through its gateway portal.

Standalone (no labgrid/pytest run needed) version of the commissioning e2e
flow: waits for the target, points the gateway at the host app, optionally
provisions WiFi through the portal, commissions the site, and verifies the
OpenVPN tunnel, the HA command_line login and a clean Settings -> Repairs.

Usage:
    venv/bin/python3 hevea_test/onboard_rpi4.py [--ip 192.168.1.150] [--wait-boot]
                                                [--no-wifi]

Env (same as the labgrid tests):
    LG_RPI_IP               target IP (default 192.168.1.150)
    HEVEA_GATEWAY_VM_URL    portal URL (default http://<ip>:9000)
    HEVEA_HA_VM_URL         HA URL (default http://<ip>)
    HEVEA_APP_URL           app URL from this host (default http://localhost:7030)
    HEVEA_VM_APP_ADDR       app URL as seen from the target (default: auto-detected)
    HEVEA_ADMIN_EMAIL / HEVEA_ADMIN_PASSWORD   app + HA credentials
    HEVEA_WIFI_SSID / HEVEA_WIFI_PASSWORD       lab WiFi to provision via the
                                                portal (skipped with --no-wifi
                                                or when unset)
"""

import argparse
import json
import logging
import os
import subprocess
import sys
import time

SCRIPT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, SCRIPT_DIR)  # allow `python3 hevea_test/onboard_rpi4.py`

# commission_common reads these at import time: set defaults first.
DEFAULT_IP = os.environ.get("LG_RPI_IP", "192.168.1.150")
os.environ.setdefault("HEVEA_GATEWAY_VM_URL", f"http://{DEFAULT_IP}:9000")
os.environ.setdefault("HEVEA_HA_VM_URL", f"http://{DEFAULT_IP}")

import requests  # noqa: E402

from hevea_test import commission_common as cc  # noqa: E402

_LOGGER = logging.getLogger("onboard")

SSH_KEY = os.path.join(SCRIPT_DIR, "hevea_test", "test_ssh_key")


class SSHDriver:
    """Minimal labgrid-like shell over ssh: run() returns
    (stdout_lines, stderr_lines, rc), run_check() returns stdout lines and
    raises on non-zero exit — the shapes commission_common expects."""

    def __init__(self, host, port=22222):
        self.host = host
        self.port = port
        self.base = [
            "ssh", "-i", SSH_KEY, "-p", str(port),
            "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
            "-o", "ConnectTimeout=10", "-o", "BatchMode=yes",
            f"root@{host}",
        ]

    def run(self, cmd, timeout=300):
        try:
            p = subprocess.run(self.base + [cmd], capture_output=True,
                               text=True, timeout=timeout)
            return p.stdout.splitlines(), p.stderr.splitlines(), p.returncode
        except subprocess.TimeoutExpired:
            return [], [f"timeout after {timeout}s"], 124

    def run_check(self, cmd, timeout=300):
        out, err, rc = self.run(cmd, timeout=timeout)
        if rc != 0:
            raise RuntimeError(f"command failed (rc={rc}): {cmd}\n{chr(10).join(err)}")
        return out

    def text(self, cmd, timeout=300):
        return "\n".join(self.run(cmd, timeout=timeout)[0])


def shell_json(driver):
    def get_json(cmd):
        return json.loads(driver.text(cmd))
    return get_json


def wait_ssh(driver, timeout=300):
    deadline = time.time() + timeout
    while time.time() < deadline:
        out, _, rc = driver.run("true", timeout=10)
        if rc == 0:
            _LOGGER.info("SSH up on %s", driver.host)
            return
        time.sleep(5)
    raise RuntimeError(f"SSH never came up on {driver.host}:{driver.port} "
                       f"(is the target booted? power it on via the HA switch)")


def wlan_iface(driver):
    out = driver.text("ip link show | awk -F': ' '{print $2}'")
    for name in out.split():
        if name.startswith("wlan"):
            return name
    return None


def provision_wifi(driver, ssid, password):
    """Submit the lab WiFi credentials through the gateway portal and wait
    until the wlan interface is connected with a default route."""
    wlan = wlan_iface(driver)
    if not wlan:
        _LOGGER.warning("no wlan interface on the target, skipping WiFi provisioning")
        return None
    r = requests.post(f"{cc.GATEWAY_VM_URL}/api/v1/networks",
                      json={"ssid": ssid, "password": password}, timeout=30)
    assert r.status_code == 201, f"POST /api/v1/networks: {r.status_code} {r.text[:200]}"
    net_id = r.json()["id"]
    r = requests.put(f"{cc.GATEWAY_VM_URL}/api/v1/networks/{net_id}",
                     json={"state": True}, timeout=30)
    assert r.status_code == 200, f"PUT /api/v1/networks/{net_id}: {r.status_code} {r.text[:200]}"
    _LOGGER.info("WiFi credentials submitted, connecting to SSID %s via %s", ssid, wlan)

    def wifi_up():
        ip = driver.text(f"ip -4 addr show {wlan} 2>/dev/null | grep inet")
        route = driver.text(f"ip route show default | grep {wlan}")
        return bool(ip.strip()) and bool(route.strip())
    cc.wait_for(wifi_up, timeout=180, interval=5,
                description=f"{wlan} connected with default route")
    return wlan


def assert_ap_down(driver, sj):
    """End state of a portal provisioning: the access point is down."""
    def ap_down():
        apps = sj("ha apps --raw-json")
        ap = next((a for a in apps.get("data", {}).get("addons", [])
                   if "access-point" in a.get("slug", "")), None)
        if ap and ap.get("state") in ("started", "starting"):
            return False
        return "none" in driver.text("pgrep -a hostapd 2>/dev/null || echo none")
    cc.wait_for(ap_down, timeout=180, interval=5,
                description="access point down after commissioning")


def assert_wlan_connected(driver, wlan, ssid):
    def ok():
        cur = driver.text(f"iw dev {wlan} link 2>/dev/null | grep SSID || true")
        ip = driver.text(f"ip -4 addr show {wlan} 2>/dev/null | grep inet")
        return ssid in cur and bool(ip.strip())
    cc.wait_for(ok, timeout=60, interval=5,
                description=f"{wlan} connected to {ssid}")


def commission_with_unlock(driver, sj, token, site_id):
    """POST /api/v1/commission; on 403 (endpoint locked) send SIGUSR1 to the
    gateway container (PID 1) to unlock it for 5 minutes and retry once."""
    try:
        cc.commission(driver, token, site_id)
        return
    except AssertionError as e:
        if "403" not in str(e):
            raise
    _LOGGER.info("commission locked (403), sending SIGUSR1 to the gateway container")
    container = cc.find_gateway_container(driver)
    driver.run(f"docker exec {container} kill -USR1 1")
    time.sleep(3)
    cc.commission(driver, token, site_id)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--ip", default=DEFAULT_IP, help="target IP (default LG_RPI_IP or 192.168.1.150)")
    ap.add_argument("--ssh-port", type=int, default=22222)
    ap.add_argument("--wait-boot", action="store_true",
                    help="wait for SSH to come up (target just power-cycled)")
    ap.add_argument("--no-wifi", action="store_true",
                    help="skip WiFi provisioning even if HEVEA_WIFI_SSID is set")
    args = ap.parse_args()

    logging.basicConfig(level=logging.INFO,
                        format="%(asctime)s %(levelname)s %(message)s")

    # recompute the portal/HA URLs for the chosen IP
    gw = f"http://{args.ip}:9000"
    ha = f"http://{args.ip}"
    os.environ["HEVEA_GATEWAY_VM_URL"] = os.environ.get("HEVEA_GATEWAY_VM_URL", gw) \
        if args.ip == DEFAULT_IP else gw
    cc.GATEWAY_VM_URL = os.environ["HEVEA_GATEWAY_VM_URL"]
    if args.ip != DEFAULT_IP or "HEVEA_HA_VM_URL" not in os.environ:
        os.environ["HEVEA_HA_VM_URL"] = ha
    cc.HA_VM_URL = os.environ["HEVEA_HA_VM_URL"]

    driver = SSHDriver(args.ip, args.ssh_port)
    sj = shell_json(driver)

    if args.wait_boot:
        wait_ssh(driver, timeout=300)
    else:
        wait_ssh(driver, timeout=30)

    _LOGGER.info("target %s up; waiting for Supervisor", args.ip)
    cc.wait_system_ready(driver)
    cc.wait_for(lambda: cc.find_gateway_slug(sj), timeout=600,
                description="gateway add-on installed")

    r = requests.get(f"{cc.GATEWAY_VM_URL}/", timeout=15)
    assert r.status_code == 200, f"portal not reachable: {r.status_code}"
    _LOGGER.info("portal answers on %s (status %s)", cc.GATEWAY_VM_URL, r.status_code)

    token, site_id = cc.app_login()
    _LOGGER.info("app login OK, site %s", site_id)

    local_app_addr = cc.resolve_app_addr(driver)
    cc.point_gateway_at_app(driver, sj, local_app_addr)
    cc.reset_ha_onboarding(driver)

    ssid = os.environ.get("HEVEA_WIFI_SSID", "")
    password = os.environ.get("HEVEA_WIFI_PASSWORD", "")
    wlan = None
    if ssid and password and not args.no_wifi:
        wlan = provision_wifi(driver, ssid, password)

    commission_with_unlock(driver, sj, token, site_id)
    _LOGGER.info("commission OK")

    cc.wait_for(lambda: cc.openvpn_addon_started(sj), timeout=180,
                description="OpenVPN add-on started")
    cc.assert_vpn_ping(driver)
    _LOGGER.info("VPN tunnel up")

    reason = cc.ha_auth_provider_missing_reason(driver)
    assert not reason, reason
    try:
        cc.wait_for(lambda: cc.ha_login_flow_ok(driver), timeout=90,
                    description="HA login with Hevea credentials")
    except BaseException:
        # The auth_providers block can be in configuration.yaml while HA core
        # was started before it was added and never reloaded it: one restart
        # makes HA load the command_line provider.
        _LOGGER.warning("login flow not ready yet, restarting HA core once and retrying")
        driver.run("ha core restart --no-progress 2>&1 || true")
        cc.wait_for(lambda: cc.ha_login_flow_ok(driver), timeout=240,
                    description="HA login with Hevea credentials after HA restart")
    cc.assert_ha_settings_clean()
    _LOGGER.info("HA command_line login OK, Settings -> Repairs clean")

    if wlan:
        assert_ap_down(driver, sj)
        assert_wlan_connected(driver, wlan, ssid)
        _LOGGER.info("access point down, %s connected to %s", wlan, ssid)

    print(f"ONBOARD_OK ip={args.ip} site={site_id} ha={cc.HA_VM_URL}")


if __name__ == "__main__":
    try:
        main()
    except SystemExit as e:
        sys.exit(e.code)
    except BaseException as e:  # pytest.fail raises a BaseException subclass
        _LOGGER.error("ONBOARD_FAILED: %s", e)
        sys.exit(1)
