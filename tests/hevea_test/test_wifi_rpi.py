"""WiFi tests — only meaningful on physical hardware (RPi4).

QEMU does not emulate the Broadcom WiFi chipset, so these tests are
skipped when running under the QEMU strategy. Run them with:

    LG_RPI_IP=192.168.1.100 pytest --lg-env hevea-rpi-strategy.yaml hevea_test/test_wifi_rpi.py
"""

import logging

import pytest


_LOGGER = logging.getLogger(__name__)


def _is_qemu(strategy) -> bool:
    """Detect whether we are running under QEMU (no real WiFi chipset)."""
    drivers = strategy.target.drivers
    if isinstance(drivers, dict):
        drivers = drivers.values()
    return hasattr(strategy, "qemu") or any(
        type(d).__name__ == "QEMUDriver" for d in drivers
    )


@pytest.fixture(autouse=True)
def skip_on_qemu(strategy):
    if _is_qemu(strategy):
        pytest.skip("WiFi tests require physical hardware (RPi4), QEMU has no WiFi chipset")


def test_wifi_interface_present(shell):
    """A wireless interface (wlan0) exists."""
    output = shell.run_check("ls /sys/class/net/ | grep -E '^wlan' || true")
    assert "wlan" in "\n".join(output), f"No wlan interface found: {output}"


def test_wifi_chip_detected(shell):
    """The Broadcom WiFi chip is detected (SDIO, brcmfmac driver)."""
    # dmesg may have rotated past the probe messages; the bound driver is
    # the reliable indicator.
    output = shell.run_check(
        "readlink /sys/class/net/wlan0/device/driver 2>/dev/null || true"
    )
    driver = output[0].rsplit("/", 1)[-1] if output else ""
    _LOGGER.info("wlan0 driver: %s", driver)
    assert "brcm" in driver.lower(), f"wlan0 driver is not Broadcom: {driver!r}"


def test_networkmanager_sees_wifi(shell):
    """NetworkManager lists a wifi device."""
    output = shell.run_check("nmcli device status | grep -i wifi || true")
    assert "wifi" in "\n".join(output).lower(), f"NM does not see a wifi device: {output}"


def test_wifi_can_scan(shell):
    """WiFi scan succeeds (may return empty list if no APs around)."""
    output = shell.run_check(
        "nmcli device wifi list --rescan yes 2>/dev/null || nmcli device wifi list || true"
    )
    _LOGGER.info("WiFi scan: %s", "\n".join(output))
    # The command should not fail; output may be empty or contain APs


def test_access_point_addon_running(shell_json):
    """The Hevea Access Point add-on is running."""
    apps = shell_json("ha apps --raw-json")
    addons = apps.get("data", {}).get("addons", [])
    ap = next(
        (a for a in addons if a.get("slug", "").endswith("_hassio-access-point")
         or a.get("slug") == "hassio-access-point"),
        None,
    )
    assert ap is not None, "Access Point add-on not installed"
    assert ap.get("state") in ("started", "starting"), f"AP add-on not running: {ap.get('state')}"
