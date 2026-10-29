################################################################################
#
# hevea-gateway
#
################################################################################

HEVEA_GATEWAY_VERSION = 1.0.0
HEVEA_GATEWAY_SITE = $(BR2_EXTERNAL_HAOS_PATH)/package/hevea-gateway
HEVEA_GATEWAY_SITE_METHOD = local

# Hevea add-on images (embedded in data partition for offline install)
HEVEA_ADDONS = gateway hassio-access-point hassio-openvpn
HEVEA_ADDON_TAG = 1.0.0

# Map buildroot arch to OCI platform arch for skopeo
ifeq ($(BR2_aarch64),y)
HEVEA_ADDON_OCI_ARCH = arm64
else ifeq ($(BR2_x86_64),y)
HEVEA_ADDON_OCI_ARCH = amd64
else
HEVEA_ADDON_OCI_ARCH = $(BR2_ARCH)
endif

# Directory where the add-on image tarballs are placed (consumed by
# create-data-partition.sh to embed them in data.ext4)
HEVEA_GATEWAY_IMGDIR = $(BINARIES_DIR)/hevea-gateway

define HEVEA_GATEWAY_BUILD_CMDS
	$(Q)mkdir -p $(@D)/images
	$(foreach addon,$(HEVEA_ADDONS),\
		echo "Downloading Hevea add-on image: ghcr.io/hevea-project/$(addon):$(HEVEA_ADDON_TAG) ($(HEVEA_ADDON_OCI_ARCH))"; \
		skopeo copy --override-arch $(HEVEA_ADDON_OCI_ARCH) \
			docker://ghcr.io/hevea-project/$(addon):$(HEVEA_ADDON_TAG) \
			oci-archive:$(@D)/images/$(addon).tar:ghcr.io/hevea-project/$(addon):$(HEVEA_ADDON_TAG); \
	)
	# Pre-install state for the data partition: the Supervisor cannot install
	# add-ons while the host is offline (its install job always pulls the
	# image from the registry), so the add-ons are baked as already installed.
	$(Q)python3 $(HEVEA_GATEWAY_PKGDIR)/craft-apps-json.py \
		$(HEVEA_GATEWAY_PKGDIR)/addons-repo $(@D)/apps.json
endef

define HEVEA_GATEWAY_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(HEVEA_GATEWAY_PKGDIR)/hevea-gateway.sh \
		$(TARGET_DIR)/usr/libexec/hevea-gateway.sh

	# Install the local add-on repository to the rootfs (used as
	# temporary offline fallback by hevea-gateway.sh). It goes to
	# /usr/share/hevea (not /opt/hevea): the HAOS post-build cleanup
	# (fix_rootfs) removes the whole /opt directory from the target rootfs.
	$(Q)mkdir -p $(TARGET_DIR)/usr/share/hevea/addons-repo
	$(Q)cp -r $(HEVEA_GATEWAY_PKGDIR)/addons-repo/* \
		$(TARGET_DIR)/usr/share/hevea/addons-repo/

	# Install the add-on image tarballs and the pre-install state for
	# create-data-partition.sh to pick up
	$(Q)mkdir -p $(HEVEA_GATEWAY_IMGDIR)
	$(Q)cp $(@D)/images/*.tar $(HEVEA_GATEWAY_IMGDIR)/
	$(Q)cp $(@D)/apps.json $(HEVEA_GATEWAY_IMGDIR)/
	$(Q)cp -r $(HEVEA_GATEWAY_PKGDIR)/addons-repo $(HEVEA_GATEWAY_IMGDIR)/
endef

define HEVEA_GATEWAY_INSTALL_INIT_SYSTEMD
	$(INSTALL) -D -m 0644 $(HEVEA_GATEWAY_PKGDIR)/hevea-gateway.service \
		$(TARGET_DIR)/usr/lib/systemd/system/hevea-gateway.service
endef

# Re-create the data partition once this package's image tarballs are
# installed to $(BINARIES_DIR): the hassio package creates data.ext4 during
# its own install, which runs before this package (it is a dependency), so
# the Hevea add-on images would be missing from the preloaded Docker store.
# create-data-partition.sh rebuilds data.ext4 from scratch, embedding both
# the HAOS system images (hassio build dir) and the Hevea add-on images
# ($(BINARIES_DIR)/hevea-gateway).
HEVEA_GATEWAY_INSTALL_IMAGES = YES

define HEVEA_GATEWAY_INSTALL_IMAGES_CMDS
	$(BR2_EXTERNAL_HAOS_PATH)/package/hassio/create-data-partition.sh \
		"$(BUILD_DIR)/hassio-$(HASSIO_VERSION)" "$(BINARIES_DIR)" \
		"$(HASSIO_VERSION_CHANNEL)" "$(DOCKER_ENGINE_VERSION)"
endef

$(eval $(generic-package))

# The images step embeds the tarballs installed by the target install:
# run it after (also with parallel make).
HEVEA_GATEWAY_TARGET_INSTALL_IMAGES: HEVEA_GATEWAY_TARGET_INSTALL_TARGET
