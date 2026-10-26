include $(TOPDIR)/rules.mk

LUCI_NAME:=luci-app-shoulderkop
LUCI_TITLE:=Shoulderkop — subscription for Podkop
LUCI_DESCRIPTION:=LuCI page for shoulderkop: paste a subscription URL, pick a mode \
(obhod BS / home internet) and let it fill podkop sections.
LUCI_DEPENDS:=+shoulderkop
LUCI_PKGARCH:=all

PKG_MAINTAINER:=shoulderkop
PKG_LICENSE:=MIT
PKG_VERSION:=0.4.7
PKG_RELEASE:=1

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature