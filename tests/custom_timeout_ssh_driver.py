"""SSH driver with a config-customizable default command timeout.

On physical targets (RPi4) there is no serial/QEMU console, so ShellDriver
(which binds on a ConsoleProtocol) cannot be used. SSHDriver is a
CommandProtocol and provides run/run_check directly, so it serves as the
shell. This subclass only makes the default command timeout configurable,
mirroring CustomTimeoutShellDriver.
"""

import attr

from labgrid import target_factory
from labgrid.driver import SSHDriver


@target_factory.reg_driver
@attr.s(eq=False)
class CustomTimeoutSSHDriver(SSHDriver):
    """SSHDriver with a config-customizable timeout for run and run_check."""

    command_timeout = attr.ib(default=30, validator=attr.validators.instance_of(int))

    def run(self, cmd, codec="utf-8", decodeerrors="strict", timeout=None):
        return super().run(
            cmd, codec=codec, decodeerrors=decodeerrors,
            timeout=timeout if timeout is not None else self.command_timeout,
        )

    def run_check(self, cmd, *, timeout=None, codec="utf-8", decodeerrors="strict"):
        return super().run_check(
            cmd, codec=codec, decodeerrors=decodeerrors,
            timeout=timeout if timeout is not None else self.command_timeout,
        )
