TARGET := iphone:clang:16.5:15.0
ARCHS = arm64
THEOS_PACKAGE_SCHEME = rootless
INSTALL_TARGET_PROCESSES = Discord

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = ChangeEndpointVoice
ChangeEndpointVoice_FILES = Bridge.mm Voice.mm
ChangeEndpointVoice_CFLAGS = -fobjc-arc
ChangeEndpointVoice_FRAMEWORKS = Foundation AVFoundation
ChangeEndpointVoice_LDFLAGS = -Wl,-no_warn_inits

include $(THEOS_MAKE_PATH)/tweak.mk
