TWEAK_NAME := AppDrawer

AppDrawer_FILES := ADEntry.m
AppDrawer_FILES += ADAppInfo.m
AppDrawer_FILES += ADAppCatalog.m
AppDrawer_FILES += ADAppCell.m
AppDrawer_FILES += ADPanelViewController.m
AppDrawer_FILES += ADPanelController.m
AppDrawer_FILES += ADLauncher.m
AppDrawer_FILES += ADPrefs.m
AppDrawer_FILES += ADURLDispatchHooks.m
AppDrawer_FILES += ../Shared/URLScheme/ADURLScheme.m

AppDrawer_CFLAGS := -fobjc-arc
AppDrawer_CFLAGS += -I../Shared/URLScheme

AppDrawer_FRAMEWORKS := UIKit
AppDrawer_FRAMEWORKS += CoreGraphics
AppDrawer_FRAMEWORKS += QuartzCore

AppDrawer_LIBRARIES := substrate

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk
