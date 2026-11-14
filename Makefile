export PACKAGE_VERSION := 1.3.7
export ARCHS := arm64e
export TARGET := iphone:clang:16.5:16.0
export THEOS_PACKAGE_SCHEME ?= roothide

INSTALL_TARGET_PROCESSES := SpringBoard

SUBPROJECTS += Core
SUBPROJECTS += Handler

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/aggregate.mk
