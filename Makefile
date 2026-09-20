# RegionCacheKeeper v1.2
# 自动缓存国区 IAP 商品 + 越狱检测屏蔽
# 基于 RegionCacheKeeper / 无根外币 / 1.17 版本三者原理融合
ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = RegionCacheKeeper
RegionCacheKeeper_FILES = Tweak.xm JBShield.m SK2Hook.m
RegionCacheKeeper_FRAMEWORKS = StoreKit Foundation UIKit
RegionCacheKeeper_CFLAGS = -fobjc-arc -Wno-visibility -Wno-unused-function
RegionCacheKeeper_LDFLAGS = -lsubstrate

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 SpringBoard" || true
