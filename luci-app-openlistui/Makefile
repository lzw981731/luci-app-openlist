include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-openlistui
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

PKG_LICENSE:=MIT
PKG_MAINTAINER:=Drfccv
PKG_BUILD_DEPENDS:=luci-base/host
HOST_BUILD_DEPENDS:=luci-base/host

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-openlistui
	SECTION:=luci
	CATEGORY:=LuCI
	SUBMENU:=3. Applications
	TITLE:=LuCI Support for OpenList UI
	DEPENDS:=+openlist +luci-base +luci-lib-jsonc +luci-lib-nixio +curl +wget +unzip +busybox
	PKGARCH:=all
endef

define Package/luci-app-openlistui/description
	A web interface for managing OpenList file management service
endef

# Conffiles declaration for UCI configuration preservation
define Package/luci-app-openlistui/conffiles
/etc/config/openlistui
endef

define Package/luci-app-openlistui/postinst
#!/bin/sh
# Standard LuCI cache clearing and service restart
if [ -z "$${IPKG_INSTROOT}" ]; then
	echo "Installing/Upgrading luci-app-openlistui..."
	
	# Detect service state for restoration
	SERVICE_ENABLED=0
	SERVICE_RUNNING=0
	
	if [ -f /tmp/openlistui-upgrade-state ]; then
		echo "Restoring service state from upgrade..."
		. /tmp/openlistui-upgrade-state
		rm -f /tmp/openlistui-upgrade-state
		SERVICE_ENABLED=$${SERVICE_WAS_ENABLED}
		SERVICE_RUNNING=$${SERVICE_WAS_RUNNING}
	elif [ -f /etc/config/openlistui ]; then
		echo "Detecting current service state..."
		if [ -x /etc/init.d/openlistui ]; then
			/etc/init.d/openlistui enabled >/dev/null 2>&1 && SERVICE_ENABLED=1
			/etc/init.d/openlistui running >/dev/null 2>&1 && SERVICE_RUNNING=1
		fi
	else
		echo "Fresh installation detected"
	fi
	
	# Clear LuCI cache
	echo "Clearing LuCI cache..."
	rm -rf /tmp/luci-indexcache /tmp/luci-modulecache/ 2>/dev/null || true
	
	# Rebuild LuCI index
	if [ -x /usr/bin/lua ]; then
		lua -e "require('luci.dispatcher').build_url()" 2>/dev/null || true
	fi
	
	# Configuration is now handled by conffiles mechanism
	# No manual backup/restore needed - opkg handles this automatically
	
	# Restore service state after upgrade
	if [ -x /etc/init.d/openlistui ]; then
		if [ "$${SERVICE_ENABLED}" = "1" ]; then
			/etc/init.d/openlistui enable 2>/dev/null || true
			if [ "$${SERVICE_RUNNING}" = "1" ]; then
				echo "Restarting OpenListUI service after upgrade..."
				/etc/init.d/openlistui restart 2>/dev/null || true
			fi
		fi
	fi
	
	# Ensure killall is available for service management
	if ! command -v killall >/dev/null 2>&1; then
		echo "Warning: killall command not found. Service management may be affected."
	fi
	
	# Restart rpcd and uhttpd to ensure proper LuCI functionality
	echo "Restarting LuCI services..."
	/etc/init.d/rpcd restart 2>/dev/null || true
	/etc/init.d/uhttpd restart 2>/dev/null || true
	
	echo "Installation/upgrade completed successfully"
fi
exit 0
endef

define Package/luci-app-openlistui/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	# Detect if this is an upgrade or removal
	if [ "$${PKG_UPGRADE}" = "1" ]; then
		echo "Upgrading luci-app-openlistui - preserving service state"
		
		# Store current service state for restoration after upgrade
		if [ -x /etc/init.d/openlistui ]; then
			if /etc/init.d/openlistui enabled >/dev/null 2>&1; then
				echo "SERVICE_WAS_ENABLED=1" > /tmp/openlistui-upgrade-state
			else
				echo "SERVICE_WAS_ENABLED=0" > /tmp/openlistui-upgrade-state
			fi
			
			if /etc/init.d/openlistui running >/dev/null 2>&1; then
				echo "SERVICE_WAS_RUNNING=1" >> /tmp/openlistui-upgrade-state
			else
				echo "SERVICE_WAS_RUNNING=0" >> /tmp/openlistui-upgrade-state
			fi
		fi
		
		# Configuration is now handled by conffiles mechanism
		# No manual backup needed - opkg handles this automatically
		
	else
		echo "Removing luci-app-openlistui - stopping service"
		if [ -x /etc/init.d/openlistui ]; then
			/etc/init.d/openlistui disable 2>/dev/null || true
			/etc/init.d/openlistui stop 2>/dev/null || true
		fi
		
		# Clean up temporary files on removal
		rm -f /tmp/openlistui-upgrade-state
	fi
}
endef

define Build/Prepare
endef

define Build/Configure
endef

define Build/Compile
endef

define Package/luci-app-openlistui/install
	# 创建基本目录结构
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/controller
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/view/openlistui
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/model/cbi/openlistui
	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/openlistui
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d

	# 安装控制器文件
	$(INSTALL_DATA) ./luasrc/controller/openlistui.lua $(1)/usr/lib/lua/luci/controller/openlistui.lua
	
	# 安装 CBI 模型文件
	if [ -d "./luasrc/model/cbi/openlistui" ]; then \
		$(INSTALL_DATA) ./luasrc/model/cbi/openlistui/*.lua $(1)/usr/lib/lua/luci/model/cbi/openlistui/ 2>/dev/null || true; \
	fi
	
	# 安装视图文件
	if [ -d "./luasrc/view/openlistui" ]; then \
		$(INSTALL_DATA) ./luasrc/view/openlistui/*.htm $(1)/usr/lib/lua/luci/view/openlistui/ 2>/dev/null || true; \
	fi
	
	# 安装 JavaScript 模块文件 (LuCI2)
	if [ -d "./htdocs/luci-static/resources/view/openlistui" ]; then \
		$(INSTALL_DATA) ./htdocs/luci-static/resources/view/openlistui/*.js $(1)/www/luci-static/resources/view/openlistui/ 2>/dev/null || true; \
	fi
	
	# 安装初始化脚本和配置文件
	$(INSTALL_BIN) ./root/etc/init.d/openlistui $(1)/etc/init.d/openlistui
	$(INSTALL_DATA) ./root/etc/config/openlistui $(1)/etc/config/openlistui
	
	# 安装 UCI 默认脚本
	$(INSTALL_BIN) ./root/etc/uci-defaults/40_luci-openlistui $(1)/etc/uci-defaults/40_luci-openlistui
	
	# 安装 ACL 配置文件
	$(INSTALL_DATA) ./root/usr/share/rpcd/acl.d/luci-app-openlistui.json $(1)/usr/share/rpcd/acl.d/luci-app-openlistui.json
	
	# 编译并安装翻译文件
	if [ -d "./po" ]; then \
		for lang in ./po/*/; do \
			if [ -d "$$$$lang" ]; then \
				langcode=$$$$(basename "$$$$lang"); \
				$(INSTALL_DIR) $(1)/usr/lib/lua/luci/i18n; \
				if [ -f "$$$$lang/openlistui.po" ]; then \
					if [ -x "$(STAGING_DIR_HOSTPKG)/bin/po2lmo" ]; then \
						$(STAGING_DIR_HOSTPKG)/bin/po2lmo "$$$$lang/openlistui.po" $(1)/usr/lib/lua/luci/i18n/openlistui.$$$$langcode.lmo; \
					elif [ -x "$(STAGING_DIR_HOST)/bin/po2lmo" ]; then \
						$(STAGING_DIR_HOST)/bin/po2lmo "$$$$lang/openlistui.po" $(1)/usr/lib/lua/luci/i18n/openlistui.$$$$langcode.lmo; \
					else \
						echo "Warning: po2lmo not found, skipping translation compilation"; \
					fi; \
				fi; \
			fi; \
		done; \
	fi
endef

$(eval $(call BuildPackage,luci-app-openlistui))
