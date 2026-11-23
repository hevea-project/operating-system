"""Labgrid strategy for a physical RPi4 booted over PXE (no SD card).

Orchestration:
  off   -> power off via HA switch
  shell -> power on via HA switch, wait for SSH, provide shell

The RPi4 must have its EEPROM boot order set to network (or no SD inserted).
The host PC must run DHCP+TFTP+HTTP serving the HAOS RPi4 boot files.
"""

import enum
import socket
import time

import attr
from labgrid.resource import NetworkService
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
        "shell": "CustomTimeoutSSHDriver",
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
            # Poll the SSH port (dropbear on 22222) until it accepts TCP
            # before activating the SSH driver: a PXE boot can take much
            # longer than a fixed sleep (cold NBD image, slow TFTP, ...).
            net = self.target.get_resource(NetworkService)
            addr, port = net.address, net.port
            self.logger.info(
                "Waiting for RPi4 to PXE boot (SSH %s:%s, timeout %ss)...",
                addr, port, self.boot_timeout,
            )
            deadline = time.time() + self.boot_timeout
            while time.time() < deadline:
                try:
                    with socket.create_connection((addr, port), timeout=2):
                        break
                except OSError:
                    time.sleep(2)
            else:
                raise StrategyError(
                    f"SSH not reachable on {addr}:{port} after {self.boot_timeout}s "
                    "(check the pxe-server containers and that cmdline.txt points at "
                    "the current IP of this PC — restart the dnsmasq container if the "
                    "wired IP changed)"
                )
            self.target.activate(self.shell)

        self.status = status
