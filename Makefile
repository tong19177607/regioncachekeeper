# RegionCacheKeeper v1.4
# 自动缓存国区 IAP 商品 + 越狱检测屏蔽 + StoreKit2 (Swift+ObjC 混编)
ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = RegionCacheKeeper
RegionCacheKeeper_FILES = Tweak.xm JBShield.m SK2Hook.m SK2SwiftHook.swift
RegionCacheKeeper_FRAMEWORKS = StoreKit Foundation UIKit
RegionCacheKeeper_CFLAGS = -fobjc-arc -Wno-visibility -Wno-unused-function
RegionCacheKeeper_LDFLAGS = -lsubstrate

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 SpringBoard" || true
