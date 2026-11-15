#import <Foundation/Foundation.h>

// SpringBoard 侧唯一的面板入口：创建高层级窗口、铺应用列表、处理 scheme 指令。
@interface ADPanelController : NSObject

+ (instancetype)sharedController;

- (void)showPanelWithQuery:(NSString *)query;
- (void)hidePanel;
- (void)hidePanelWithCompletion:(void (^)(void))completion;

// appdrawer://show | appdrawer://close | appdrawer://open?bundle=xxx | appdrawer://search?q=xxx
- (void)handleURL:(NSURL *)URL;

@end
