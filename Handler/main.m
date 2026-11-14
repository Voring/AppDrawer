//
//  main.m
//  AppDrawerURL
//
//  只负责“认领 appdrawer:// 这个 scheme”。
//  正常路径下 SpringBoard 内的分发型钩子会先把 URL 拦掉，这个 App 根本不会启动；
//  它只是 LaunchServices 查不到处理者、或分发型钩子没命中时的兜底：
//  收到 URL -> 写入共享请求文件 -> 发 Darwin 通知 -> 立刻退出，尽量不闪白屏。
//

#import <UIKit/UIKit.h>

#import "../Shared/URLScheme/ADURLScheme.h"

@interface ADURLHandlerDelegate : UIResponder <UIApplicationDelegate>
@end

@implementation ADURLHandlerDelegate

- (BOOL)handleURL:(NSURL *)URL {
    if (!ADURLIsAppDrawerURL(URL)) {
        return NO;
    }
    ADSubmitOpenRequest(URL);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.10 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                     exit(0);
                   });
    return YES;
}

- (BOOL)application:(UIApplication *)application
              openURL:(NSURL *)URL
              options:(NSDictionary<UIApplicationOpenURLOptionsKey, id> *)options {
    return [self handleURL:URL];
}

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary<UIApplicationLaunchOptionsKey, id> *)launchOptions {
    NSURL *launchURL = launchOptions[UIApplicationLaunchOptionsURLKey];
    if (launchURL && [self handleURL:launchURL]) {
        return YES;
    }

    // 没有任何 URL 被拉起时不要驻留。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.30 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                     exit(0);
                   });
    return YES;
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([ADURLHandlerDelegate class]));
    }
}
