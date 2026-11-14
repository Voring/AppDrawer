#import <Foundation/Foundation.h>

#import "ADAppCatalog.h"
#import "ADPanelController.h"
#import "ADURLDispatchHooks.h"

__attribute__((constructor)) static void ADEntry(void) {
    @autoreleasepool {
        ADInstallURLDispatchHooks();
        // 触发单例初始化：注册 Darwin 通知观察者。
        (void)[ADPanelController sharedController];

        // 预热应用列表，第一次唤出面板时不用等枚举。
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
          [ADAppCatalog loadApplications];
        });
    }
}
