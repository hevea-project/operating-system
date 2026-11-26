import json
import logging
import os

from labgrid.driver import ShellDriver, SSHDriver
from labgrid.exceptions import NoDriverFoundError
import pytest


logger = logging.getLogger(__name__)


def _get_shell(target, strategy):
    """Return the shell driver: ShellDriver on QEMU (console), SSHDriver on
    physical targets (no console available)."""
    strategy.transition("shell")
    try:
        return target.get_driver(ShellDriver, activate=False)
    except NoDriverFoundError:
        return target.get_driver(SSHDriver, activate=False)


def _has_qemu(strategy) -> bool:
    """Whether the current target uses the QEMU driver (vs physical hardware)."""
    drivers = strategy.target.drivers
    if isinstance(drivers, dict):
        drivers = drivers.values()
    return hasattr(strategy, "qemu") or any(
        type(d).__name__ == "QEMUDriver" for d in drivers
    )


@pytest.fixture(scope="function")
def without_internet(strategy):
    if not _has_qemu(strategy):
        pytest.skip("without_internet only applies to QEMU targets")
    default_nic = strategy.qemu.nic
    if strategy.status.name == "shell":
        strategy.transition("off")
    strategy.qemu.nic = "user,net=192.168.76.0/24,dhcpstart=192.168.76.10,restrict=yes"
    strategy.transition("shell")
    yield
    strategy.transition("off")
    strategy.qemu.nic = default_nic


@pytest.fixture(autouse=True, scope="module")
def restart_qemu(strategy):
    """Use fresh QEMU instance for each module (QEMU targets only)."""
    if not _has_qemu(strategy):
        return
    if strategy.status.name == "shell":
        logger.info("Restarting QEMU before %s module tests.", strategy.target.name)
        strategy.transition("off")
        strategy.transition("shell")


@pytest.hookimpl
def pytest_runtest_setup(item):
    log_dir = item.config.option.lg_log

    if not log_dir:
        return

    logging_plugin = item.config.pluginmanager.get_plugin("logging-plugin")
    log_name = item.nodeid.replace(".py::", "/")
    logging_plugin.set_log_path(os.path.join(log_dir, f"{log_name}.log"))


@pytest.fixture(scope="module")
def app_token_and_site():
    """Login to the app on the host and return (token, site_id)."""
    from hevea_test import commission_common
    return commission_common.app_login()


@pytest.fixture
def shell(target, strategy):
    """Fixture for accessing shell (ShellDriver on QEMU, SSHDriver on RPi)."""
    return _get_shell(target, strategy)


@pytest.fixture
def shell_json(target, strategy) -> callable:
    """Fixture for running CLI commands returning JSON string as output."""
    shell = _get_shell(target, strategy)

    def get_json_response(command, *, timeout=None) -> dict:
        return json.loads("\n".join(shell.run_check(command, timeout=timeout)))

    return get_json_response
