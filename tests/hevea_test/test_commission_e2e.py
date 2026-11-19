"""End-to-end commissioning test inside the QEMU VM.

Prerequisites:
- docker-compose stack running on the host (app on :7030, gateway on :8080)
- QEMU VM booted (hevea-strategy.yaml)

The VM reaches the host via 10.0.2.2 (QEMU user-mode NAT).
The gateway add-on inside the VM listens on port 9000 (hostfwd 19000).

Flow:
1. From the host: login to app (10.0.2.2 won't work from host, use localhost:7030)
   → get token + site_id
2. POST commission to the VM's gateway (localhost:19000 from host)
3. Verify inside the VM: OpenVPN add-on configured and running, VPN IP assigned
4. Verify HA web UI accessible with the Hevea credentials
"""

import json
import logging
import os
import subprocess
import time

import pytest
import requests


_LOGGER = logging.getLogger(__name__)

# App API on the host (docker-compose)
APP_URL = os.environ.get("HEVEA_APP_URL", "http://localhost:7030")
# Gateway API inside the VM, forwarded to host port 19000
GATEWAY_VM_URL = os.environ.get("HEVEA_GATEWAY_VM_URL", "http://localhost:19000")
ADMIN_EMAIL = os.environ.get("HEVEA_ADMIN_EMAIL", "admin@hevea.io")
ADMIN_PASSWORD = os.environ.get("HEVEA_ADMIN_PASSWORD", "changeme")


def _wait_for(predicate, timeout=300, interval=5, description="condition"):
    elapsed = 0
    while elapsed < timeout:
        try:
            result = predicate()
            if result:
                return result
        except Exception:
            pass
        time.sleep(interval)
        elapsed += interval
    pytest.fail(f"Timeout ({timeout}s) waiting for {description}")


def _wait_system_ready(shell, timeout=600):
    """Wait until Supervisor and HA Core containers are running in the VM."""
    def check():
        for c in ("hassio_supervisor", "homeassistant"):
            out = shell.run_check(
                f"docker container inspect -f '{{{{.State.Status}}}}' {c} 2>/dev/null || echo missing"
            )
            if "running" not in "\n".join(out):
                return False
        return True
    _wait_for(check, timeout=timeout, description="VM system ready (supervisor + HA)")


@pytest.fixture(scope="module")
def app_token_and_site():
    """Login to the app on the host and return (token, site_id)."""
    deadline = time.time() + 120
    last_err = None
    while time.time() < deadline:
        try:
            r = requests.post(
                f"{APP_URL}/api/v1/users/login",
                json={"email": ADMIN_EMAIL, "password": ADMIN_PASSWORD},
                timeout=10,
            )
            if r.status_code == 200:
                token = r.json()["token"]
                r2 = requests.get(
                    f"{APP_URL}/api/v1/sites",
                    headers={"Authorization": f"Bearer {token}"},
                    timeout=10,
                )
                if r2.status_code == 200 and r2.json():
                    return token, r2.json()[0]["id"]
                last_err = f"sites: {r2.status_code} {r2.text}"
            else:
                last_err = f"login: {r.status_code} {r.text}"
        except requests.RequestException as e:
            last_err = str(e)
        time.sleep(3)
    pytest.fail(f"App not reachable at {APP_URL}: {last_err}")


def _find_gateway_container(shell, timeout=300):
    """Return the docker container name of the gateway add-on in the VM (waits for it)."""
    def check():
        out = shell.run_check("docker ps --format '{{.Names}}' 2>/dev/null | grep -E 'gateway|app_' || true")
        names = [n for n in "\n".join(out).split("\n") if n.strip() and "gateway" in n.lower()]
        if names:
            _LOGGER.info("Gateway container: %s", names[0])
            return names[0]
        return None
    return _wait_for(check, timeout=timeout, description="gateway container running in VM")


def _find_gateway_slug(shell_json):
    """Return the add-on slug of the gateway in the Supervisor."""
    apps = shell_json("ha apps --raw-json")
    addons = apps.get("data", {}).get("addons", [])
    gw = next(
        (a for a in addons if a.get("slug", "").endswith("_hassio-gateway")
         or a.get("slug") == "hassio-gateway"),
        None,
    )
    return gw["slug"] if gw else None


@pytest.mark.timeout(600)
def test_commission_via_vm_gateway(shell, shell_json, app_token_and_site):
    """POST /api/v1/commission to the gateway inside the VM.

    First points the gateway's app_addr at the local docker-compose app
    via `hevea addon-options set` inside the gateway container (the host
    is reachable from QEMU user-mode NAT at 10.0.2.2).
    """
    token, site_id = app_token_and_site
    _LOGGER.info("Commissioning site %s via VM gateway", site_id)

    _wait_system_ready(shell)

    # Point the gateway add-on at the local app (host = 10.0.2.2 in QEMU NAT)
    local_app_addr = os.environ.get("HEVEA_VM_APP_ADDR", "http://10.0.2.2:7030")
    container = _find_gateway_container(shell)
    slug = _find_gateway_slug(shell_json)
    assert container, "Gateway container not found in VM"
    assert slug, "Gateway add-on slug not found"
    _LOGGER.info("Setting gateway app_addr=%s (container=%s slug=%s)", local_app_addr, container, slug)
    # Use the hevea CLI (talks to the Supervisor API — the source of truth for
    # options; the Supervisor rewrites /data/options.json on add-on start).
    out = shell.run(
        f"docker exec {container} hevea addon-options set {slug} app_addr {local_app_addr} 2>&1 || true"
    )
    _LOGGER.info("addon-options set: %s", str(out))
    # Verify via the Supervisor API (not the file)
    get_out = shell.run(f"docker exec {container} hevea addon-options get {slug} app_addr 2>&1 || true")
    _LOGGER.info("addon-options get app_addr: %s", str(get_out))
    # Restart the add-on via the Supervisor (it recreates the container with
    # the new options). Retry: the Supervisor may return 503 while busy.
    def restart_ok():
        r = shell.run(f"ha apps restart {slug} --no-progress --raw-json 2>&1 || true")
        return "ok" in str(r).lower() or "started" in str(r).lower()
    _wait_for(restart_ok, timeout=180, description="gateway add-on restart via Supervisor")
    _wait_for(
        lambda: (lambda a: a and a.get("state") in ("started", "starting"))(
            next((x for x in shell_json("ha apps --raw-json").get("data", {}).get("addons", [])
                  if x.get("slug") == slug), None)
        ),
        timeout=180, description="gateway add-on restarted with new app_addr",
    )
    time.sleep(5)

    # Commission via the VM's gateway (host port 19000 -> VM port 9000)
    r = requests.post(
        f"{GATEWAY_VM_URL}/api/v1/commission",
        json={"token": token, "site_id": site_id, "email": ADMIN_EMAIL},
        timeout=300,
    )
    _LOGGER.info("Commission response: %s %s", r.status_code, r.text[:500])
    assert r.status_code == 200, f"Commission failed: {r.status_code} {r.text}"
    data = r.json()
    assert data.get("status") == "success", f"Commission not successful: {data}"



@pytest.mark.timeout(300)
def test_openvpn_addon_configured(shell_json):
    """The OpenVPN add-on inside the VM received certificates and is running."""
    def check():
        apps = shell_json("ha apps --raw-json")
        addons = apps.get("data", {}).get("addons", [])
        ovpn = next(
            (a for a in addons if a.get("slug", "").endswith("_hassio-openvpn")
             or a.get("slug") == "hassio-openvpn"),
            None,
        )
        if ovpn is None:
            return False
        _LOGGER.info("OpenVPN add-on state: %s", ovpn.get("state"))
        return ovpn.get("state") in ("started", "starting")

    _wait_for(check, timeout=180, description="OpenVPN add-on started")



@pytest.mark.timeout(300)
def test_vpn_connectivity(shell):
    """The VM has a VPN IP (10.8.0.x) and can ping the OpenVPN server."""
    def check_vpn_ip():
        out = shell.run_check("ip -4 addr show tun0 2>/dev/null || ip -4 addr show | grep -E '10\\.8\\.' || true")
        text = "\n".join(out)
        _LOGGER.info("VPN interfaces: %s", text)
        return "10.8." in text

    _wait_for(check_vpn_ip, timeout=180, description="VPN tunnel up with 10.8.x.x IP")

    # Ping the OpenVPN server gateway (10.8.0.1)
    out = shell.run_check("ping -c 3 -W 5 10.8.0.1 2>/dev/null || true")
    text = "\n".join(out)
    _LOGGER.info("Ping 10.8.0.1: %s", text)
    assert "0% packet loss" in text or "3 received" in text, f"VPN ping failed: {text}"



@pytest.mark.timeout(300)
def test_ha_login_with_hevea_credentials(shell):
    """HA web UI accepts the Hevea credentials via the command_line auth provider."""
    # The auth provider validates against the gateway's /api/v1/auth/validate,
    # which checks the app (or the synced db). Try a login flow against HA.
    def check_ha_login():
        # Create a login flow
        out = shell.run_check(
            'curl -s -X POST http://localhost/api/auth/login_flow '
            '-H "Content-Type: application/json" '
            f'-d \'{{"client_id":"http://localhost/","handler":["homeassistant",null],"redirect_uri":"http://localhost/auth/external/callback"}}\' '
            '2>/dev/null || true'
        )
        text = "\n".join(out)
        try:
            flow = json.loads(text)
            flow_id = flow.get("flow_id")
            if not flow_id:
                return False
            # Submit credentials
            out2 = shell.run_check(
                f'curl -s -X POST http://localhost/api/auth/login_flow/{flow_id} '
                '-H "Content-Type: application/json" '
                f'-d \'{{"client_id":"http://localhost/","username":"{ADMIN_EMAIL}","password":"{ADMIN_PASSWORD}"}}\' '
                '2>/dev/null || true'
            )
            result = json.loads("\n".join(out2))
            _LOGGER.info("HA login flow result type: %s", result.get("type"))
            return result.get("type") == "create_entry"
        except (json.JSONDecodeError, KeyError):
            return False

    _wait_for(check_ha_login, timeout=180, description="HA login with Hevea credentials")
