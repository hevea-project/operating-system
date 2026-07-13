################################################################################
#
# hevea-bootstrap
#
################################################################################

HEVEA_BOOTSTRAP_VERSION = 1.0.0
HEVEA_BOOTSTRAP_SITE = $(BR2_EXTERNAL_HAOS_PATH)/package/hevea-bootstrap
HEVEA_BOOTSTRAP_SITE_METHOD = local

define HEVEA_BOOTSTRAP_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(HEVEA_BOOTSTRAP_PKGDIR)/hevea-bootstrap.sh \
		$(TARGET_DIR)/usr/libexec/hevea-bootstrap.sh
endef

define HEVEA_BOOTSTRAP_INSTALL_INIT_SYSTEMD
	$(INSTALL) -D -m 0644 $(HEVEA_BOOTSTRAP_PKGDIR)/hevea-bootstrap.service \
		$(TARGET_DIR)/usr/lib/systemd/system/hevea-bootstrap.service
endef

$(eval $(generic-package))
