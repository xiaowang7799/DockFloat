DEBUG = 0
FINALPACKAGE = 1

ARCHS = arm64 arm64e

include ../AxsDockFloatBuild.mk
include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = AxsDockFloatFlipswitch
AxsDockFloatFlipswitch_FILES = Switch.m
AxsDockFloatFlipswitch_FRAMEWORKS = UIKit
AxsDockFloatFlipswitch_LIBRARIES = flipswitch
AxsDockFloatFlipswitch_INSTALL_PATH = /Library/Switches

include $(THEOS_MAKE_PATH)/bundle.mk