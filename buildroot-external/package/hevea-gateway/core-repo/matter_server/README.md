# Matter Server (vendored)

Vendored copy of the official add-on config
(`home-assistant/addons`, `matter_server/config.yaml`, version 9.3.0) used
to pre-install the add-on in the data partition under the built-in `core`
repository slug (`core_matter_server`). The image tarball
`ghcr.io/home-assistant/app-matter-server:9.3.0` is downloaded by
hevea-gateway.mk and embedded in the data partition.

The Matter server needs no device configuration at first boot (it runs over
the network) and has `boot: auto` by default, so installing it is enough.

When the official config changes, refresh this copy and bump the version in
../hevea-gateway.mk together.
