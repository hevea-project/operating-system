"""Integration tests for the Hevea gateway bootstrap in HAOS.

These tests boot the HAOS QCOW2 image in QEMU and verify that:
- The image boots and the system becomes ready
- SSH access works (key injected via usb.img)
- The hevea-gateway systemd service ran successfully
- The Hevea add-on repository was added to the Supervisor store
- The Hevea add-ons (gateway, access-point, openvpn) are installed
"""

import logging
import os
from time import sleep

import pytest


_LOGGER = logging.getLogger(__name__)

# Slug of the Hevea add-on repository, derived from the URL
# (sha1 of the lowercased URL, first 8 hex chars) — same as in hevea-gateway.sh
HEVEA_REPO_URL = "https://github.com/hevea-project/hassio-apps"
HEVEA_REPO_SLUG = "f1b448f5"  # sha1 of lowercased URL, first 8 chars

HEVEA_ADDON_SLUGS = [
    "hassio-gateway",
    "hassio-access-point",
    "hassio-openvpn",
]

BOOTSTRAP_MARKER = "/mnt/overlay/etc/hevea-gateway.complete"


def _wait_for_system_ready(shell, shell_json, timeout=600):
    """Wait until the Supervisor and Home Assistant Core are ready."""
    def check_container_running(container_name):
        out = shell.run_check(
            f"docker container inspect -f '{{{{.State.Status}}}}' {container_name} || true"
        )
        return "running" in out

    elapsed = 0
    while elapsed < timeout:
        if check_container_running("homeassistant") and check_container_running("hassio_supervisor"):
            break
        sleep(5)
        elapsed += 5
    else:
        pytest.fail(f"Containers not running after {timeout}s")

    elapsed = 0
    while elapsed < timeout:
        output = "\n".join(shell.run_check("ha os info || true"))
        if "System is not ready" not in output and "connection refused" not in output:
            break
        sleep(5)
        elapsed += 5
    else:
        pytest.fail(f"System not ready after {timeout}s")


@pytest.mark.dependency()
@pytest.mark.timeout(900)
def test_boot_and_system_ready(shell, shell_json):
    """The image boots and the system becomes ready."""
    _LOGGER.info("Waiting for containers to start...")
    _wait_for_system_ready(shell, shell_json)

    os_info = shell_json("ha os info --no-progress --raw-json")
    assert os_info.get("result") == "ok", f"ha os info failed: {os_info}"
    version = os_info.get("data", {}).get("version")
    assert version, f"No version in os info: {os_info}"
    _LOGGER.info("HAOS version: %s", version)


def _is_qemu(strategy) -> bool:
    return hasattr(strategy, "qemu") or any(
        type(d).__name__ == "QEMUDriver" for d in strategy.target.drivers.values()
    )


@pytest.mark.dependency(depends=["test_boot_and_system_ready"])
def test_ssh_accessible(shell, strategy):
    """SSH daemon is running and authorized_keys is present.

    On QEMU, the key is injected via usb.img. On physical RPi, it must be
    added manually (or via usb.img mounted at boot).
    """
    output = shell.run_check("systemctl is-active sshd || systemctl is-active ssh || true")
    assert "active" in "\n".join(output), f"SSH daemon not active: {output}"

    if _is_qemu(strategy):
        # On QEMU, verify the USB image was mounted with our key
        output = shell.run_check(
            "find /mnt -name authorized_keys -exec cat {} \\; 2>/dev/null || echo 'NOT_FOUND'"
        )
        _LOGGER.info("authorized_keys content: %s", output)
        assert "NOT_FOUND" not in "\n".join(output), "authorized_keys not found (USB image not mounted?)"
        assert "hevea-test" in "\n".join(output), "Test SSH key not in authorized_keys"


@pytest.mark.dependency(depends=["test_boot_and_system_ready"])
@pytest.mark.timeout(600)
def test_gateway_service_ran(shell):
    """The hevea-gateway systemd service is active and completed its bootstrap."""
    # Check the service is active
    output = shell.run_check("systemctl is-active hevea-gateway.service || true")
    assert "active" in "\n".join(output), f"hevea-gateway.service not active: {output}"

    # Check the service ran without errors (check journal for the bootstrap completion)
    output = shell.run_check(
        "journalctl -u hevea-gateway.service --no-pager -n 50 || true"
    )
    _LOGGER.info("hevea-gateway.service logs:\n%s", "\n".join(output))

    # The bootstrap script creates a marker file on success (when online)
    # or logs completion. Check either the marker or the log message.
    marker = shell.run_check(f"test -f {BOOTSTRAP_MARKER} && echo EXISTS || echo MISSING")
    logs_contain_complete = "Bootstrap complete" in "\n".join(output)
    assert "EXISTS" in "\n".join(marker) or logs_contain_complete, (
        f"Bootstrap did not complete: marker={marker}, logs contain complete={logs_contain_complete}"
    )


@pytest.mark.dependency(depends=["test_gateway_service_ran"])
@pytest.mark.timeout(300)
def test_hevea_repo_added(shell_json):
    """The Hevea add-on repository was added to the Supervisor store."""
    repos = shell_json("ha store --raw-json")
    assert repos.get("result") == "ok", f"ha store failed: {repos}"

    repo_slugs = [
        r.get("slug")
        for r in repos.get("data", {}).get("repositories", [])
    ]
    _LOGGER.info("Repository slugs: %s", repo_slugs)
    assert HEVEA_REPO_SLUG in repo_slugs, (
        f"Hevea repository (slug {HEVEA_REPO_SLUG}) not found in store. "
        f"Available: {repo_slugs}"
    )


@pytest.mark.dependency(depends=["test_hevea_repo_added"])
def test_hevea_addons_installed(shell_json):
    """All three Hevea add-ons are installed in the Supervisor."""
    apps = shell_json("ha apps --raw-json")
    assert apps.get("result") == "ok", f"ha apps failed: {apps}"

    installed_slugs = [
        a.get("slug")
        for a in apps.get("data", {}).get("addons", [])
    ]
    _LOGGER.info("Installed add-on slugs: %s", installed_slugs)

    for addon_slug in HEVEA_ADDON_SLUGS:
        # The effective slug may be prefixed with the repo slug (e.g. f1b448f5_hassio-gateway)
        found = any(
            s == addon_slug or s.endswith("_" + addon_slug)
            for s in installed_slugs
        )
        assert found, (
            f"Add-on {addon_slug} not installed. "
            f"Installed slugs: {installed_slugs}"
        )


@pytest.mark.dependency(depends=["test_hevea_addons_installed"])
def test_gateway_addon_running(shell_json):
    """The Hevea Gateway add-on is running (state=started)."""
    apps = shell_json("ha apps --raw-json")
    addons = apps.get("data", {}).get("addons", [])

    gateway = next(
        (a for a in addons if a.get("slug", "").endswith("_hassio-gateway") or a.get("slug") == "hassio-gateway"),
        None,
    )
    assert gateway is not None, "Gateway add-on not found in installed add-ons"
    _LOGGER.info("Gateway add-on: %s", gateway)
    assert gateway.get("state") in ("started", "starting"), (
        f"Gateway add-on not running: state={gateway.get('state')}"
    )


@pytest.mark.dependency(depends=["test_boot_and_system_ready"])
def test_ha_api_reachable(shell):
    """Home Assistant API is reachable on port 80 (and redirect on 8123)."""
    output = shell.run_check("curl -s -o /dev/null -w '%{http_code}' http://localhost/api/onboarding || true")
    assert "200" in "\n".join(output), f"HA API not reachable on port 80: {output}"

    # Port 8123 should redirect to port 80
    redirect = shell.run_check(
        "curl -s -o /dev/null -w '%{http_code} %{redirect_url}' http://localhost:8123 || true"
    )
    _LOGGER.info("Port 8123 redirect: %s", redirect)
    assert "307" in "\n".join(redirect) or "302" in "\n".join(redirect) or "301" in "\n".join(redirect), (
        f"Port 8123 does not redirect: {redirect}"
    )


@pytest.mark.dependency(depends=["test_boot_and_system_ready"])
def test_no_failed_units(shell):
    """No systemd units are in failed state."""
    output = shell.run_check("systemctl --no-pager -l list-units --state=failed || true")
    assert "0 loaded units listed." in "\n".join(output), (
        f"Some units failed:\n{'\n'.join(output)}"
    )
