#import <Foundation/Foundation.h>

#import "ADAppCatalog.h"
#import "ADAppInfo.h"
#import "ADPanelController.h"
#import "ADURLDispatchHooks.h"

__attribute__((constructor)) static void ADEntry(void) {
    @autoreleasepool {
        // 主线程先把屏幕倍数缓存好，后台图标队列不再碰 UIScreen。
        ADCacheScreenScale();
        ADInstallURLDispatchHooks();
        // 触发单例初始化（挂前台丢失 / 键盘观察者）。
        (void)[ADPanelController sharedController];

        // 预热应用列表，第一次唤出面板时不用等枚举。
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
          [ADAppCatalog loadApplications];
        });
    }
}
