"""Shared helpers for the commissioning e2e tests (online and offline).

Prerequisites:
- docker-compose stack running on the host (app on :7030)
- target booted (QEMU VM via hevea-strategy.yaml, or physical RPi4 via
  hevea-rpi-pxe-strategy.yaml)

The target reaches the host app at:
- 10.0.2.2:7030  (QEMU user-mode NAT)
- HEVEA_VM_APP_ADDR (physical RPi: the host's LAN IP)
and the gateway portal is reached from the host at HEVEA_GATEWAY_VM_URL
(localhost:19000 for QEMU hostfwd, http://<rpi-ip>:9000 for the RPi).
"""

import json
import logging
import os
import time

import pytest
import requests


_LOGGER = logging.getLogger(__name__)

# App API on the host (docker-compose)
APP_URL = os.environ.get("HEVEA_APP_URL", "http://localhost:7030")
# Gateway API of the target, as seen from the host running pytest
GATEWAY_VM_URL = os.environ.get("HEVEA_GATEWAY_VM_URL", "http://localhost:19000")
ADMIN_EMAIL = os.environ.get("HEVEA_ADMIN_EMAIL", "admin@hevea.io")
ADMIN_PASSWORD = os.environ.get("HEVEA_ADMIN_PASSWORD", "changeme")


def wait_for(predicate, timeout=300, interval=5, description="condition"):
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


def app_login():
    """Login to the app and return (token, site_id).

    Creates the test site if the stack is fresh (no site yet).

    Tries APP_URL first, then falls back to http://localhost:7030 (the docker
    stack runs on the pytest host, so localhost always works there — APP_URL
    may point at a stale interface IP, e.g. an unplugged USB dongle).
    """
    candidates = [APP_URL]
    if APP_URL != "http://localhost:7030":
        candidates.append("http://localhost:7030")
    deadline = time.time() + 120
    last_err = None
    while time.time() < deadline:
        for base in candidates:
            try:
                r = requests.post(
                    f"{base}/api/v1/users/login",
                    json={"email": ADMIN_EMAIL, "password": ADMIN_PASSWORD},
                    timeout=10,
                )
                if r.status_code == 200:
                    token = r.json()["token"]
                    r2 = requests.get(
                        f"{base}/api/v1/sites",
                        headers={"Authorization": f"Bearer {token}"},
                        timeout=10,
                    )
                    if r2.status_code == 200 and r2.json():
                        return token, r2.json()[0]["id"]
                    if r2.status_code == 200:
                        r3 = requests.post(
                            f"{base}/api/v1/sites",
                            headers={"Authorization": f"Bearer {token}"},
                            json={"name": "hevea-labgrid-test"},
                            timeout=10,
                        )
                        if r3.status_code in (200, 201) and r3.json().get("id"):
                            _LOGGER.info("Created test site %s", r3.json()["id"])
                            return token, r3.json()["id"]
                        last_err = f"site create: {r3.status_code} {r3.text}"
                    else:
                        last_err = f"sites: {r2.status_code} {r2.text}"
                else:
                    last_err = f"login: {r.status_code} {r.text}"
            except requests.RequestException as e:
                last_err = str(e)
        time.sleep(3)
    pytest.fail(f"App not reachable at {candidates}: {last_err}")


def wait_system_ready(shell, timeout=600):
    """Wait until the Supervisor API answers on the target (containers may be
    'running' but the API not ready yet)."""
    def check():
        out = shell.run(
            "ha banner >/dev/null 2>&1 && echo OK || echo NOT_READY"
        )
        return "OK" in str(out)
    wait_for(check, timeout=timeout, description="target Supervisor API ready")


def find_gateway_container(shell, timeout=300):
    """Return the docker container name of the gateway add-on (waits for it)."""
    def check():
        out = shell.run_check("docker ps --format '{{.Names}}' 2>/dev/null | grep -E 'gateway|app_' || true")
        names = [n for n in "\n".join(out).split("\n") if n.strip() and "gateway" in n.lower()]
        if names:
            _LOGGER.info("Gateway container: %s", names[0])
            return names[0]
        return None
    return wait_for(check, timeout=timeout, description="gateway container running on target")


def find_gateway_slug(shell_json):
    """Return the add-on slug of the gateway in the Supervisor."""
    apps = shell_json("ha apps --raw-json")
    addons = apps.get("data", {}).get("addons", [])
    gw = next(
        (a for a in addons if a.get("slug", "").endswith("_hassio-gateway")
         or a.get("slug") == "hassio-gateway"),
        None,
    )
    return gw["slug"] if gw else None


def point_gateway_at_app(shell, shell_json, local_app_addr):
    """Point the gateway add-on's app_addr at the local app and restart it."""
    container = find_gateway_container(shell)
    slug = find_gateway_slug(shell_json)
    assert container, "Gateway container not found on target"
    assert slug, "Gateway add-on slug not found"
    _LOGGER.info("Setting gateway app_addr=%s (container=%s slug=%s)", local_app_addr, container, slug)
    # Use the hevea CLI (talks to the Supervisor API — the source of truth for
    # options; the Supervisor rewrites /data/options.json on add-on start).
    out = shell.run(
        f"docker exec {container} hevea addon-options set {slug} app_addr {local_app_addr} 2>&1 || true"
    )
    _LOGGER.info("addon-options set: %s", str(out))
    get_out = shell.run(f"docker exec {container} hevea addon-options get {slug} app_addr 2>&1 || true")
    _LOGGER.info("addon-options get app_addr: %s", str(get_out))
    # Restart the add-on via the Supervisor (it recreates the container with
    # the new options). Retry: the Supervisor may return 503 while busy.
    def restart_ok():
        r = shell.run(f"ha apps restart {slug} --no-progress --raw-json 2>&1 || true")
        return "ok" in str(r).lower() or "started" in str(r).lower()
    wait_for(restart_ok, timeout=180, description="gateway add-on restart via Supervisor")
    wait_for(
        lambda: (lambda a: a and a.get("state") in ("started", "starting"))(
            next((x for x in shell_json("ha apps --raw-json").get("data", {}).get("addons", [])
                  if x.get("slug") == slug), None)
        ),
        timeout=180, description="gateway add-on restarted with new app_addr",
    )
    time.sleep(5)


def _ha_api_code(shell):
    # NB: use shell.run, not run_check: when the connection is refused
    # curl exits non-zero and run_check would raise, hiding the "000".
    # curl -w '%{http_code}' prints 000 by itself on failure.
    out = shell.run(
        "curl -s -o /dev/null -w '%{http_code}' -m 5 http://localhost/api/ 2>/dev/null"
    )
    lines = out[0] if isinstance(out, tuple) else out
    return "\n".join(lines).strip() if lines else "000"


def _ha_running(shell):
    return _ha_api_code(shell) in ("200", "401")  # 401 = "API running." without credentials


def reset_ha_onboarding(shell):
    """Reset the Home Assistant onboarding so commissioning can run again on a
    reused (already commissioned) image: without this the gateway refuses with
    409 HA_ALREADY_ONBOARDED. Stops HA Core first: it re-saves .storage/auth on
    shutdown, which would resurrect the existing user."""
    wait_for(lambda: _ha_running(shell), timeout=180, description="HA Core up before onboarding reset")

    def _stop_ha():
        code = _ha_api_code(shell)
        if code == "000":
            return True
        out = shell.run("ha core stop --no-progress 2>&1 || true")
        _LOGGER.info("ha core stop (api=%s): %s", code, str(out)[:200])
        return False

    wait_for(_stop_ha, timeout=180, description="HA Core stopped", interval=5)
    # HA Core is stopped at this point, so docker exec would fail: remove the
    # files from the host side (the HA config dir is mounted under /mnt/data).
    shell.run_check(
        "rm -rf /mnt/data/supervisor/homeassistant/.storage/onboarding "
        "/mnt/data/supervisor/homeassistant/.storage/auth "
        "/mnt/data/supervisor/homeassistant/.storage/auth_provider.homeassistant "
        "/mnt/data/supervisor/homeassistant/.storage/person"
    )

    def _start_ha():
        if _ha_running(shell):
            return True
        shell.run("ha core start --no-progress 2>&1 || true")
        return False

    wait_for(_start_ha, timeout=180, description="HA Core restarted after onboarding reset", interval=5)

    def _onboarding_reset():
        out = shell.run_check(
            "curl -s -m 5 http://localhost/api/onboarding 2>/dev/null | grep -q '\"step\":\"user\",\"done\":false' && echo yes || echo no"
        )
        return "yes" in "\n".join(out)

    wait_for(_onboarding_reset, timeout=60, description="HA onboarding user step reset")


def commission(shell, token, site_id):
    """POST /api/v1/commission to the target's gateway portal (from the host)."""
    r = requests.post(
        f"{GATEWAY_VM_URL}/api/v1/commission",
        json={"token": token, "site_id": site_id, "email": ADMIN_EMAIL},
        timeout=300,
    )
    _LOGGER.info("Commission response: %s %s", r.status_code, r.text[:500])
    assert r.status_code == 200, f"Commission failed: {r.status_code} {r.text}"
    data = r.json()
    assert data.get("status") == "success", f"Commission not successful: {data}"
    return data


def openvpn_addon_started(shell_json):
    """Whether the OpenVPN add-on is started in the Supervisor."""
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


def vpn_tunnel_up(shell):
    """Whether the target has a VPN IP (10.8.x.x)."""
    out = shell.run_check("ip -4 addr show tun0 2>/dev/null || ip -4 addr show | grep -E '10\\.8\\.' || true")
    text = "\n".join(out)
    _LOGGER.info("VPN interfaces: %s", text)
    return "10.8." in text


def assert_vpn_ping(shell):
    """Ping the OpenVPN server gateway (10.8.0.1) from the target."""
    try:
        wait_for(lambda: vpn_tunnel_up(shell), timeout=180, description="VPN tunnel up with 10.8.x.x IP")
    except Exception:
        ovpn_container = shell.run("docker ps --format '{{.Names}}' | grep -i openvpn || echo NONE")
        cname = "\n".join(ovpn_container).strip() or "NONE"
        logs = shell.run(f"docker logs --tail 30 {cname} 2>&1 || true")
        ip_out = shell.run("ip -4 addr 2>/dev/null | grep inet || true")
        print(f"\n===== VPN DEBUG container={cname} =====")
        print("LOGS:", logs)
        print("IP:", ip_out)
        print("========================================\n")
        raise
    out = shell.run_check("ping -c 3 -W 5 10.8.0.1 2>/dev/null || true")
    text = "\n".join(out)
    _LOGGER.info("Ping 10.8.0.1: %s", text)
    assert "0% packet loss" in text or "3 received" in text, f"VPN ping failed: {text}"


def ha_auth_provider_missing_reason(shell):
    """Why the HA command_line auth provider cannot work on this target, or None.

    The provider (hevea-auth.py shim + auth_providers entry) is installed by
    the gateway through the homeassistant_config:rw map. If the add-on image
    predates the map or the args fix, the shim/args are missing.
    """
    shim = shell.run("docker exec homeassistant test -f /config/hevea-auth.py && echo OK || echo MISSING")
    if "MISSING" in str(shim):
        return ("hevea-auth.py shim not installed (gateway add-on needs "
                "homeassistant_config:rw map — rebuild the OS image or "
                "reinstall the gateway add-on from the updated repository)")
    # HA unpacks the provider's args with *config[CONF_ARGS] and crashes when
    # the key is absent: the gateway add-on image must include the args fix.
    args = shell.run(
        "docker exec homeassistant sh -c \"grep -A3 'type: command_line' /config/configuration.yaml | grep -q 'args:' && echo OK || echo MISSING\""
    )
    if "MISSING" in str(args):
        return ("command_line provider lacks args (gateway add-on image "
                "predates the args fix — redeploy the add-on from the "
                "updated repository)")
    return None


def ha_login_flow_ok(shell):
    """Run a HA login flow with the Hevea credentials (command_line provider).

    Returns True when HA answers type=create_entry.
    """
    out = shell.run_check(
        'curl -s -X POST http://localhost/auth/login_flow '
        '-H "Content-Type: application/json" '
        '-d \'{"client_id":"http://localhost/","handler":["command_line",null],"redirect_uri":"http://localhost/auth/external/callback"}\' '
        '2>/dev/null || true'
    )
    text = "\n".join(out)
    try:
        flow = json.loads(text)
        flow_id = flow.get("flow_id")
        if not flow_id:
            return False
        out2 = shell.run_check(
            f'curl -s -X POST http://localhost/auth/login_flow/{flow_id} '
            '-H "Content-Type: application/json" '
            f'-d \'{{"client_id":"http://localhost/","username":"{ADMIN_EMAIL}","password":"{ADMIN_PASSWORD}"}}\' '
            '2>/dev/null || true'
        )
        result = json.loads("\n".join(out2))
        _LOGGER.info("HA login flow result type: %s", result.get("type"))
        return result.get("type") == "create_entry"
    except (json.JSONDecodeError, KeyError):
        return False
