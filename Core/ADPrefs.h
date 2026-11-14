#import <UIKit/UIKit.h>

// 只读 /var/mobile/Library/Preferences/com.voring.appdrawer.plist，
// 改完不需要重装插件，重新唤起面板即可生效（必要时 respring）。
NSInteger ADPrefColumns(void);
CGFloat ADPrefPanelHeightPercent(void);
CGFloat ADPrefPanelCornerRadius(void);
BOOL ADPrefShowSystemApps(void);
BOOL ADPrefForceScreenCoreFloating(void);
// 默认 NO：不走 ScreenCore 私有接口，只走系统 LaunchServices 链路。
BOOL ADPrefUseScreenCorePrivateAPI(void);
UIBlurEffectStyle ADPrefBlurStyle(void);
