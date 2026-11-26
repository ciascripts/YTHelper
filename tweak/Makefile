TARGET := iphone:clang:latest:15.0
ARCHS = arm64
INSTALL_TARGET_PROCESSES = YouTube

# Folder that holds the YTVideoOverlay checkout (for <YTVideoOverlay/Header.h>).
DEPS_DIR ?= $(THEOS_PROJECT_DIR)/../deps

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = YTHelper
$(TWEAK_NAME)_FILES = Ads.x Background.x Branding.x Settings.x Download.x YTHDownloader.m
$(TWEAK_NAME)_CFLAGS = -fobjc-arc -I$(DEPS_DIR)
$(TWEAK_NAME)_FRAMEWORKS = UIKit Foundation AVFoundation CoreMedia PhotosUI

include $(THEOS_MAKE_PATH)/tweak.mk
