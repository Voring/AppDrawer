#import <UIKit/UIKit.h>

// 只读 /var/mobile/Library/Preferences/com.voring.appdrawer.plist，
// 改完不需要重装插件，重新唤起面板即可生效（必要时 respring）。

typedef enum : NSInteger {
    ADLauncherModeScreenCore = 0,  // 默认：ScreenCore 浮窗接口
    ADLauncherModeLaunchServices = 1,  // 备用：系统跳转链路
} ADLauncherMode;

NSInteger ADPrefColumns(void);
CGFloat ADPrefPanelCornerRadius(void);
BOOL ADPrefShowSystemApps(void);
// LauncherMode：0 = ScreenCore 浮窗接口（默认），1 = LaunchServices。
ADLauncherMode ADPrefLauncherMode(void);
