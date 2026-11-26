# OpenThread Border Router (vendored)

Vendored copy of the official add-on config
(`home-assistant/addons`, `openthread_border_router/config.yaml`, version
3.4.0) used to pre-install the add-on in the data partition under the
built-in `core` repository slug (`core_openthread_border_router`), the same
way the Hevea add-ons are pre-installed under the Hevea repository slug.

The image tarball `ghcr.io/home-assistant/app-openthread-border-router:3.4.0`
is downloaded by hevea-gateway.mk and embedded in the data partition.

When the official config changes, refresh this copy and bump
HEVEA_OTBR_VERSION in ../hevea-gateway.mk together.
