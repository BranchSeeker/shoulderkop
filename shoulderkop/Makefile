include $(TOPDIR)/rules.mk

PKG_NAME:=shoulderkop
PKG_VERSION:=0.4.7
PKG_RELEASE:=1

PKG_LICENSE:=MIT
PKG_MAINTAINER:=shoulderkop

include $(INCLUDE_DIR)/package.mk

define Package/shoulderkop
  SECTION:=net
  CATEGORY:=Network
  TITLE:=Subscription manager for podkop
  DEPENDS:=+ucode +ucode-mod-fs +ucode-mod-uci +curl +ca-bundle
  PKGARCH:=all
endef

define Package/shoulderkop/description
  Shoulderkop downloads an Xray-JSON subscription (Remnawave/Happ) or a list of
  vless:// links, converts nodes to sing-box outbounds and fills podkop sections
  automatically. Two modes: "obhod BS" (whole LAN via proxy, RKN lists direct)
  and "home internet" (YouTube + EU sections via proxy, everything else direct).

  Needs podkop > 0.7.24 at runtime (not a build dependency: podkop is not in the
  official feeds). Nodes with the xhttp transport require
  sing-box > 1.14.1-extended-2.7.2.
endef

define Package/shoulderkop/conffiles
/etc/config/shoulderkop
endef

define Package/shoulderkop/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	# reinstal поверх удалённого пакета: apk оставляет защищённый /etc/init.d/*.apk-new
	[ -f /etc/init.d/shoulderkop.apk-new ] && mv -f /etc/init.d/shoulderkop.apk-new /etc/init.d/shoulderkop
	/etc/init.d/shoulderkop enable >/dev/null 2>&1
	/etc/init.d/shoulderkop restart >/dev/null 2>&1
}
exit 0
endef

define Package/shoulderkop/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	# reinstal поверх удалённого пакета: apk оставляет защищённый /etc/init.d/*.apk-new
	[ -f /etc/init.d/shoulderkop.apk-new ] && mv -f /etc/init.d/shoulderkop.apk-new /etc/init.d/shoulderkop
	/usr/bin/shoulderkop schedule off >/dev/null 2>&1
	/etc/init.d/shoulderkop disable >/dev/null 2>&1
	rm -f /etc/init.d/shoulderkop
}
exit 0
endef

define Build/Compile
endef

define Package/shoulderkop/install
	$(INSTALL_DIR) \
		$(1)/etc/config \
		$(1)/etc/init.d \
		$(1)/etc/hotplug.d/iface \
		$(1)/usr/bin \
		$(1)/usr/lib/shoulderkop

	$(INSTALL_CONF) ./files/etc/config/shoulderkop $(1)/etc/config/shoulderkop
	$(INSTALL_BIN)  ./files/etc/init.d/shoulderkop $(1)/etc/init.d/shoulderkop
	$(INSTALL_BIN)  ./files/usr/bin/shoulderkop $(1)/usr/bin/shoulderkop
	$(INSTALL_BIN)  ./files/etc/hotplug.d/iface/99-shoulderkop $(1)/etc/hotplug.d/iface/99-shoulderkop
	$(INSTALL_DATA) ./files/usr/lib/shoulderkop/*.uc $(1)/usr/lib/shoulderkop/
endef

$(eval $(call BuildPackage,shoulderkop))