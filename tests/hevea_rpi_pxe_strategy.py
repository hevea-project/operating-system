"""Labgrid strategy for a physical RPi4 booted over PXE (no SD card).

Orchestration:
  off   -> power off via HA switch
  shell -> power on via HA switch, wait for SSH, provide shell

The RPi4 must have its EEPROM boot order set to network (or no SD inserted).
The host PC must run DHCP+TFTP+HTTP serving the HAOS RPi4 boot files.
"""

import enum
import time

import attr
from labgrid.strategy import Strategy, StrategyError
from labgrid.target import target_factory
from labgrid.step import step


class Status(enum.Enum):
    unknown = 0
    off = 1
    shell = 2


@target_factory.reg_driver
@attr.s(eq=False)
class RPiPXEStrategy(Strategy):
    """Strategy: power off -> power on (PXE boot) -> wait SSH -> shell."""

    bindings = {
        "power": "HomeAssistantPowerDriver",
        "ssh": "SSHDriver",
        "shell": "CustomTimeoutShellDriver",
    }

    status = attr.ib(default=Status.unknown)
    boot_timeout = attr.ib(default=300)

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
            time.sleep(3)

        elif status == Status.shell:
            if self.status == Status.unknown:
                self.transition(Status.off, step=step)
            self.target.activate(self.power)
            self.power.on()
            self.logger.info("Waiting for RPi4 to PXE boot and SSH to come up...")
            time.sleep(60)  # PXE boot takes longer than SD
            self.target.activate(self.ssh)
            self.target.activate(self.shell)

        self.status = status
