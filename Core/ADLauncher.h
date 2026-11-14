#import <Foundation/Foundation.h>

// 打开一个已安装 App。
// 默认走 ScreenCore 的浮窗接口（SCFloatingSceneManager -sc_openSplitForBundleIdentifier:），
// 与 QuickLaunch 的做法一致；可透过偏好切回系统 LaunchServices。
BOOL ADOpenApplication(NSString *bundleIdentifier);
