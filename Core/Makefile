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
# 面板高度系数：1.0 = 初版高度；0.889 = 初版再抬高 1/3；0.667 = 缩小 1/3。
AppDrawer_CFLAGS += -DAD_PANEL_HEIGHT_REDUCTION=1.0

AppDrawer_FRAMEWORKS := UIKit
AppDrawer_FRAMEWORKS += CoreGraphics
AppDrawer_FRAMEWORKS += QuartzCore

AppDrawer_LIBRARIES := substrate

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk
