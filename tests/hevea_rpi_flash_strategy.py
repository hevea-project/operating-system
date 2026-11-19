"""Labgrid strategy for a physical Raspberry Pi 4 with USB OTG flash.

Orchestration:
  off   -> power off the RPi (via HA switch)
  flash -> remove SD requirement: power the RPi over USB-C only, run rpiboot
           to flash the image, then power cycle
  shell -> power on, wait for SSH, provide shell

Requires on the host:
  - usbboot (github.com/raspberrypi/usbboot): rpiboot binary in PATH
  - the HAOS RPi4 image at ../output_rpi4/images/haos_rpi4-18.4.img
"""

import enum
import os
import subprocess
import time

import attr
from labgrid.strategy import Strategy, StrategyError
from labgrid.target import target_factory
from labgrid.step import step


class Status(enum.Enum):
    unknown = 0
    off = 1
    flashed = 2
    shell = 3


@target_factory.reg_driver
@attr.s(eq=False)
class RPiFlashStrategy(Strategy):
    """Strategy: power off -> flash via USB OTG -> power on -> SSH shell."""

    bindings = {
        "power": "HomeAssistantPowerDriver",
        "ssh": "SSHDriver",
        "shell": "CustomTimeoutShellDriver",
    }

    image_path = attr.ib(default="../output_rpi4/images/haos_rpi4-18.4.img")
    status = attr.ib(default=Status.unknown)

    def _flash(self):
        """Flash the image via rpiboot (RPi4 in USB device mode, no SD)."""
        if not os.path.exists(self.image_path):
            raise StrategyError(f"Image not found: {self.image_path}")
        self.logger.info("Flashing %s via rpiboot...", self.image_path)
        result = subprocess.run(
            ["sudo", "rpiboot", "-d", os.path.dirname(self.image_path)],
            capture_output=True, text=True, timeout=300,
        )
        # rpiboot with a directory flashes all .img files in it
        if result.returncode != 0:
            # Fallback: dd directly if rpiboot fails (SD exposed as /dev/sdX)
            self.logger.warning("rpiboot failed: %s", result.stderr)
            raise StrategyError(f"rpiboot failed: {result.stderr}")
        self.logger.info("Flash complete")

    @step(args=["status"])
    def transition(self, status, *, step):
        if not isinstance(status, Status):
            status = Status[status]
        if status == Status.unknown:
            raise StrategyError(f"cannot transition to {status}")
        if status == self.status:
            step.skip("nothing to do")
            return

        if status == Status.off:
            self.target.activate(self.power)
            self.power.off()
            time.sleep(2)

        elif status == Status.flashed:
            if self.status == Status.unknown:
                self.transition(Status.off, step=step)
            self._flash()

        elif status == Status.shell:
            if self.status != Status.flashed:
                self.transition(Status.flashed, step=step)
            self.power.on()
            # Wait for SSH to come up
            time.sleep(30)
            self.target.activate(self.ssh)
            self.target.activate(self.shell)

        self.status = status
