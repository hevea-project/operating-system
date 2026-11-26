"""Labgrid power driver that controls a switch via the Home Assistant REST API.

Useful for Matter/ Zigbee plugs registered in Home Assistant (no Tasmota/YKUSH
hardware needed). Requires a long-lived access token from HA
(Profile -> Long-Lived Access Tokens).
"""

import attr
import requests
from labgrid.driver import Driver
from labgrid.target import target_factory


@target_factory.reg_driver
@attr.s(eq=False)
class HomeAssistantPowerDriver(Driver):
    """Power driver backed by a Home Assistant switch entity."""

    ha_url = attr.ib(validator=attr.validators.instance_of(str))
    ha_token = attr.ib(validator=attr.validators.instance_of(str))
    entity = attr.ib(validator=attr.validators.instance_of(str))

    def __attrs_post_init__(self):
        super().__attrs_post_init__()
        self.ha_url = self.ha_url.rstrip("/")
        self._headers = {"Authorization": f"Bearer {self.ha_token}"}

    def _call(self, service: str):
        url = f"{self.ha_url}/api/services/switch/{service}"
        r = requests.post(
            url,
            headers=self._headers,
            json={"entity_id": self.entity},
            timeout=15,
        )
        r.raise_for_status()

    def on(self):
        self._call("turn_on")

    def off(self):
        self._call("turn_off")

    def get_status(self) -> str:
        r = requests.get(
            f"{self.ha_url}/api/states/{self.entity}",
            headers=self._headers,
            timeout=15,
        )
        r.raise_for_status()
        return r.json().get("state", "unknown")
