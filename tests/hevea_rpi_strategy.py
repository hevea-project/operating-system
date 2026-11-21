"""Labgrid strategy for a physical Raspberry Pi 4 already booted with HAOS.

Unlike QEMUShellStrategy, this strategy does not boot anything: the RPi is
already running. It simply connects over SSH and provides a shell.
"""

import enum

import attr

from labgrid.driver import SSHDriver
from labgrid.strategy import Strategy, StrategyError
from labgrid.target import target_factory
from labgrid.step import step


class Status(enum.Enum):
    unknown = 0
    off = 1
    shell = 2


@target_factory.reg_driver
@attr.s(eq=False)
class RPiShellStrategy(Strategy):
    """Strategy for an already-booted physical RPi: connect via SSH and shell."""

    bindings = {
        "ssh": "SSHDriver",
        "shell": "CustomTimeoutShellDriver",
    }

    status = attr.ib(default=Status.unknown)

    @step(args=["status"])
    def transition(self, status, *, step):  # pylint: disable=redefined-outer-name
        if not isinstance(status, Status):
            status = Status[status]
        if status == Status.unknown:
            raise StrategyError(f"can not transition to {status}")
        elif status == self.status:
            step.skip("nothing to do")
            return
        elif status == Status.off:
            self.target.deactivate(self.ssh)
            self.target.deactivate(self.shell)
        elif status == Status.shell:
            self.target.activate(self.ssh)
            self.target.activate(self.shell)
        else:
            raise StrategyError(f"no transition found from {self.status} to {status}")
        self.status = status
