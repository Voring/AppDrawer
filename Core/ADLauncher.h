#import <Foundation/Foundation.h>

// 打开一个已安装 App。优先走系统 LaunchServices，
// 这样 ScreenCore 的“接管系统跳转”逻辑会像聚焦搜索一样把它变成浮窗。
BOOL ADOpenApplication(NSString *bundleIdentifier);
