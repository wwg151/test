export THEOS_PACKAGE_SCHEME = rootless
export ARCHS = arm64 arm64e
TARGET := iphone:clang:16.5:16.0
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = NotificationIsland
NotificationIsland_FILES = Tweak.xm
NotificationIsland_CFLAGS = -fobjc-arc -fblocks -I.
NotificationIsland_FRAMEWORKS = UIKit Foundation

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 SpringBoard"
