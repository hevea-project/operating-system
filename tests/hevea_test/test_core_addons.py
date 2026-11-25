"""E2E tests for the pre-installed official add-ons (core repository):
OpenThread Border Router (Thread USB dongle) and Matter server.

The add-ons are baked into the data partition at image build time (see
buildroot-external/package/hevea-gateway: core-repo/ + craft-apps-json.py),
so they are installed already at the first offline boot. hevea-gateway.sh
configures the OTBR with the dongle device (and the backbone interface) at
first boot; the Matter server needs no configuration (boot: auto).
"""

import logging

import pytest

from hevea_test import commission_common as cc


_LOGGER = logging.getLogger(__name__)

OTBR = "core_openthread_border_router"
MATTER = "core_matter_server"


def _shell_text(shell, cmd):
    out = shell.run(cmd)
    lines = out[0] if isinstance(out, tuple) else out
    return "\n".join(lines)


def _addon(shell_json, slug):
    apps = shell_json("ha apps --raw-json")
    return next((a for a in apps.get("data", {}).get("addons", [])
                 if a.get("slug") == slug), None)


def _running(shell_json, slug):
    ap = _addon(shell_json, slug)
    return ap is not None and ap.get("state") in ("started", "starting")


def _dongle_device(shell):
    """The Thread dongle device path on the target, or None (QEMU has none)."""
    out = _shell_text(
        shell,
        "ls /dev/serial/by-id/ 2>/dev/null; ls /dev/ttyACM0 /dev/ttyUSB0 2>/dev/null",
    )
    for line in out.splitlines():
        line = line.strip()
        if line.startswith("/dev/"):
            return line
    return None


@pytest.mark.timeout(300)
def test_core_addons_installed(shell_json):
    """Both official add-ons are pre-installed in the image (offline first boot)."""
    def both_installed():
        aps = [_addon(shell_json, slug) for slug in (OTBR, MATTER)]
        if any(a is None for a in aps):
            return False
        for a in aps:
            _LOGGER.info("%s installed, version %s", a.get("slug"), a.get("version"))
        return True
    # wait_for tolerates transient `ha` CLI failures (hassio_cli restarting)
    cc.wait_for(both_installed, timeout=180,
                description="core add-ons (OTBR + Matter) installed")


# Note: the Matter server needs no first-boot configuration (boot: auto,
# network-only). Its installation is asserted by test_core_addons_installed.
# Whether it stays up depends on reaching the DCL (on.dcl.csa-iot.org) for
# its vendor/certificate sync, which is environmental — out of scope here.


@pytest.mark.timeout(300)
def test_otbr_configured_and_thread_up(shell, shell_json):
    """RPi4 + dongle only: the first-boot bootstrap configured the OTBR with the
    dongle device, and the Thread network is up (ot-ctl state is
    leader/router/child, not detached/disabled)."""
    dongle = _dongle_device(shell)
    if not dongle:
        pytest.skip("no Thread USB dongle on this target (QEMU has no ttyACM/ttyUSB)")
    cc.wait_system_ready(shell)

    ap = _addon(shell_json, OTBR)
    assert ap is not None, f"{OTBR} not installed (image missing the pre-install state?)"

    # Configured with the dongle device by hevea-gateway.sh at first boot
    info = shell_json(f"ha apps info {OTBR} --raw-json")
    opts = info.get("data", {}).get("options", {})
    _LOGGER.info("OTBR options: %s", opts)
    assert opts.get("device") == dongle, \
        f"OTBR device {opts.get('device')!r} != dongle {dongle!r}"
    assert opts.get("backbone_interface"), "OTBR backbone_interface not set"

    # The add-on is running
    cc.wait_for(lambda: _running(shell_json, OTBR), timeout=180,
                description="OTBR add-on started")

    # The Thread network is functional: ot-ctl state is an attached role
    def thread_up():
        out = _shell_text(
            shell, f"docker exec app_{OTBR} ot-ctl state 2>/dev/null | head -1"
        ).strip()
        _LOGGER.info("ot-ctl state: %s", out)
        return out in ("leader", "router", "child")
    cc.wait_for(thread_up, timeout=180, interval=10,
                description="Thread network up (ot-ctl state leader/router/child)")
