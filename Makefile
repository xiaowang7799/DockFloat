DEBUG = 0
FINALPACKAGE = 1

ARCHS = arm64 arm64e

# Share the SDK and deployment targets with the PreferenceBundle.
include AxsDockFloatBuild.mk
include $(THEOS)/makefiles/common.mk

TWEAK_NAME = AxsDockFloat
AxsDockFloat_FILES = $(wildcard Hooks/*.xm Sources/*.m)
AxsDockFloat_CFLAGS = -fobjc-arc -I./Headers -I./Sources
AxsDockFloat_FRAMEWORKS = UIKit Foundation CoreFoundation QuartzCore
AxsDockFloat_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += AxsDockFloatPrefs
SUBPROJECTS += AxsDockFloatFlipswitch
include $(THEOS_MAKE_PATH)/aggregate.mk
