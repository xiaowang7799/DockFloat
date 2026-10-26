include ../AxsDockFloatBuild.mk
include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = AxsDockFloatPrefs
AxsDockFloatPrefs_FILES = $(wildcard *.m) $(wildcard Resources/*.m)
AxsDockFloatPrefs_CFLAGS = -fobjc-arc -I../Sources
AxsDockFloatPrefs_FRAMEWORKS = UIKit Foundation CoreFoundation
AxsDockFloatPrefs_PRIVATE_FRAMEWORKS = Preferences
AxsDockFloatPrefs_INSTALL_PATH = /Library/PreferenceBundles

include $(THEOS_MAKE_PATH)/bundle.mk
