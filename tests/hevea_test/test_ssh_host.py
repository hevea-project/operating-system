"""SSH connectivity tests from the host machine.

On QEMU: connects to localhost:22222 (hostfwd).
On physical RPi: connects to $RPI_IP:22222 (HAOS dropbear port).

These tests run on the host, not inside the target.
"""

import os
import subprocess

import pytest


SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
SSH_KEY = os.path.join(SCRIPT_DIR, "test_ssh_key")


def _get_ssh_target(strategy) -> tuple[str, int]:
    """Return (host, port) for SSH connection based on the strategy."""
    driver_names = [type(d).__name__ for d in strategy.target.drivers]
    if "QEMUDriver" in driver_names:
        return "127.0.0.1", 22222
    # Physical RPi running HAOS: dropbear listens on 22222 (same as QEMU image)
    rpi_ip = os.environ.get("LG_RPI_IP") or os.environ.get("RPI_IP", "192.168.1.100")
    return rpi_ip, 22222


def test_ssh_from_host(strategy):
    """SSH connection from the host works with the test key."""
    host, port = _get_ssh_target(strategy)

    result = subprocess.run(
        [
            "ssh",
            "-i", SSH_KEY,
            "-p", str(port),
            "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null",
            "-o", "ConnectTimeout=30",
            f"root@{host}",
            "echo SSH_OK",
        ],
        capture_output=True,
        text=True,
        timeout=60,
    )
    assert result.returncode == 0, (
        f"SSH connection failed (rc={result.returncode}):\n"
        f"stdout: {result.stdout}\nstderr: {result.stderr}"
    )
    assert "SSH_OK" in result.stdout, f"Unexpected output: {result.stdout}"
