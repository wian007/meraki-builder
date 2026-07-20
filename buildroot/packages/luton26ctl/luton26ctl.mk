################################################################################
#
# luton26ctl
#
################################################################################

LUTON26CTL_VERSION = 0.1
LUTON26CTL_SITE = package/luton26ctl
LUTON26CTL_SITE_METHOD = local
LUTON26CTL_INSTALL_TARGET = YES

define LUTON26CTL_BUILD_CMDS
$(MAKE) CC="$(TARGET_CC)" LD="$(TARGET_LD)" -C $(@D) all
endef

define LUTON26CTL_INSTALL_TARGET_CMDS
$(INSTALL) -D -m 0755 $(@D)/luton26ctl $(TARGET_DIR)/bin
endef

$(eval $(generic-package))
