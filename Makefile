# RegionCacheKeeper v1.5
# 切号(storefront 注入拉国区商品) + 无根外币(NSLocale/SKProduct 伪装)
# ObjC + Swift 混编; 无越狱屏蔽, 无界面, 安装即生效
ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = RegionCacheKeeper
RegionCacheKeeper_FILES = Tweak.xm
RegionCacheKeeper_FRAMEWORKS = StoreKit Foundation UIKit
RegionCacheKeeper_CFLAGS = -fobjc-arc -Wno-visibility -Wno-unused-function
RegionCacheKeeper_LDFLAGS = -lsubstrate

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 SpringBoard" || true
