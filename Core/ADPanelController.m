#import "ADPanelController.h"

#import <UIKit/UIKit.h>

#import "../Shared/URLScheme/ADURLScheme.h"
#import "ADAppCatalog.h"
#import "ADLauncher.h"
#import "ADPanelViewController.h"

#pragma mark - 面板窗口

@interface ADPanelWindow : UIWindow
@end

@implementation ADPanelWindow

- (BOOL)canBecomeKeyWindow {
    return YES;
}

@end

#pragma mark - 工具

static UIWindowScene *ADActiveWindowScene(void) {
    UIApplication *application = [UIApplication sharedApplication];
    UIWindowScene *fallback = nil;
    for (UIScene *scene in application.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) {
            continue;
        }
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        if (!fallback) {
            fallback = windowScene;
        }
        if (windowScene.activationState == UISceneActivationStateForegroundActive) {
            return windowScene;
        }
    }
    return fallback;
}

static NSString *ADURLQueryValue(NSURL *URL, NSString *name) {
    NSURLComponents *components = [NSURLComponents componentsWithURL:URL
                                              resolvingAgainstBaseURL:NO];
    for (NSURLQueryItem *item in components.queryItems) {
        if ([item.name caseInsensitiveCompare:name] == NSOrderedSame) {
            return item.value;
        }
    }
    return nil;
}

static void ADOpenRequestCallback(CFNotificationCenterRef center,
                                  void *observer,
                                  CFStringRef name,
                                  const void *object,
                                  CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
      NSURL *URL = ADConsumeOpenRequest();
      if (URL) {
          [[ADPanelController sharedController] handleURL:URL];
      }
    });
}

#pragma mark - 控制器

@implementation ADPanelController {
    ADPanelViewController *_panel;
    ADPanelWindow *_window;
    BOOL _visible;
    // 收起动画的「代次」：每次 show/hide 都自增，过期的延时清理直接作废。
    NSUInteger _teardownToken;
}

+ (instancetype)sharedController {
    static ADPanelController *controller;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
      controller = [[ADPanelController alloc] init];
    });
    return controller;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        (__bridge const void *)self,
                                        ADOpenRequestCallback,
                                        (__bridge CFStringRef)ADOpenRequestNotification,
                                        NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);

        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        [center addObserver:self
                   selector:@selector(_handleForegroundLoss:)
                       name:UIApplicationWillResignActiveNotification
                     object:nil];
        [center addObserver:self
                   selector:@selector(_handleForegroundLoss:)
                       name:UISceneDidDisconnectNotification
                     object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (BOOL)isPanelVisible {
    return _visible;
}

#pragma mark - 展示 / 收起

- (void)showPanelWithQuery:(NSString *)query {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
          [self showPanelWithQuery:query];
        });
        return;
    }
    [self _showPanelWithQuery:query];
}

- (void)_showPanelWithQuery:(NSString *)query {
    if (_visible && _panel) {
        [_panel setQuery:query];
        [self _refreshApplications];
        return;
    }

    UIWindowScene *scene = ADActiveWindowScene();
    if (!scene) {
        return;
    }

    // 先清掉任何残留状态，避免上一次异常留下半吊子面板。
    [self _teardownPanelSynchronously];

    _panel = [[ADPanelViewController alloc] init];
    __weak typeof(self) weakSelf = self;
    _panel.onRequestClose = ^{
      [weakSelf hidePanel];
    };
    _panel.onRequestOpenApplication = ^(NSString *bundleIdentifier) {
      [weakSelf openApplication:bundleIdentifier];
    };

    _window = [[ADPanelWindow alloc] initWithWindowScene:scene];
    _window.frame = scene.coordinateSpace.bounds;
    _window.windowLevel = 10000001.0;
    _window.backgroundColor = [UIColor clearColor];
    _window.opaque = NO;
    _window.rootViewController = _panel;
    _window.hidden = NO;
    [_window makeKeyAndVisible];

    _visible = YES;

    [_panel setApplications:[ADAppCatalog cachedApplications]];
    [_panel setQuery:query];
    [_panel.view setNeedsLayout];
    [_panel.view layoutIfNeeded];
    [_panel animateIn];

    [self _refreshApplications];
    [self _scheduleKeyboardRetries];
}

// SpringBoard 会在场景激活时把自己的窗口重新设回 key window，
// 我们的搜索框即便拿到 first responder，窗口一旦丢 key，键盘就会被 UIKit 抑制。
// 所以在头两秒里反复把 key 抢回来并重新聚焦。
- (void)_scheduleKeyboardRetries {
    NSArray<NSNumber *> *delays = @[@0.20, @0.45, @0.80, @1.30, @2.00];
    __weak typeof(self) weakSelf = self;

    for (NSNumber *number in delays) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(number.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
                         ADPanelController *strongSelf = weakSelf;
                         if (!strongSelf || !strongSelf->_visible || !strongSelf->_panel ||
                             !strongSelf->_window) {
                             return;
                         }
                         [strongSelf->_window makeKeyWindow];
                         [strongSelf->_panel focusSearchField];
                         [strongSelf _writeDiagnostics:[NSString stringWithFormat:@"retry-%@s", number]];
                       });
    }
}

- (void)openApplication:(NSString *)bundleIdentifier {
    if (bundleIdentifier.length == 0) {
        return;
    }
    // 先把覆盖层无条件摘掉，再隔一个 runloop 发跳转；
    // ScreenCore 建浮窗场景不能和「面板收起」挤在同一帧。
    // 这条路径不做收起动画：动画期间残留的窗口会干扰 SC 建浮窗。
    [self _teardownPanelSynchronously];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.20 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                     ADOpenApplication(bundleIdentifier);
                   });
}

- (void)hidePanel {
    [self hidePanelWithCompletion:nil];
}

- (void)hidePanelWithCompletion:(void (^)(void))completion {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
          [self hidePanelWithCompletion:completion];
        });
        return;
    }

    if (!_visible || !_panel) {
        [self _teardownPanelSynchronously];
        if (completion) {
            completion();
        }
        return;
    }

    // Kayoko 式收起：0.33s 淡出，没有位移。
    // 但清理绝不依赖动画 completion —— 用代次 + 延时兜底同步摘除，
    // 即使主线程被打断，覆盖层也一定在 0.34s 内消失。
    [_panel animateOutWithCompletion:nil];

    NSUInteger token = ++_teardownToken;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.34 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                     if (token != _teardownToken) {
                         return;
                     }
                     [self _teardownPanelSynchronously];
                     if (completion) {
                         completion();
                     }
                   });
}

// 同步、幂等地把面板从事件链和窗口上摘掉。
// 关键：清理动作不挂在动画 completion 上，主线程被卡住时也能保证覆盖层移除。
- (void)_teardownPanelSynchronously {
    _teardownToken++;
    if (_panel) {
        [_panel.view endEditing:YES];
        [_panel.view removeFromSuperview];
        _panel = nil;
    }
    if (_window) {
        _window.hidden = YES;
        [_window resignKeyWindow];
        _window.rootViewController = nil;
        _window = nil;
    }
    _visible = NO;
}

- (void)_handleForegroundLoss:(NSNotification *)notification {
    // 锁屏、切后台、场景断开时无条件、同步摘掉面板，不允许它浮在所有界面之上。
    if (_visible) {
        [self _teardownPanelSynchronously];
    }
}

- (void)_refreshApplications {
    __weak typeof(self) weakSelf = self;
    [ADAppCatalog reloadInBackgroundWithCompletion:^(NSArray<ADAppInfo *> *applications) {
      ADPanelController *strongSelf = weakSelf;
      if (!strongSelf || !strongSelf->_visible || !strongSelf->_panel) {
          return;
      }
      if (applications.count == 0) {
          return;
      }
      [strongSelf->_panel setApplications:applications];
    }];
}

#pragma mark - 诊断

// 记录面板/键盘状态，真机排查时用 Filza 打开
// /var/mobile/Library/Preferences/com.voring.appdrawer/diag.txt 即可。
static NSString *ADKeyboardWindowSummary(void) {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) {
            continue;
        }
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            NSString *className = NSStringFromClass([window class]);
            if ([className rangeOfString:@"Keyboard" options:NSCaseInsensitiveSearch].location !=
                NSNotFound) {
                [names addObject:[NSString stringWithFormat:@"%@(key=%d,hidden=%d)",
                                                            className,
                                                            (int)window.isKeyWindow,
                                                            (int)window.isHidden]];
            }
        }
    }
    return names.count ? [names componentsJoinedByString:@"|"] : @"none";
}

- (void)_writeDiagnostics:(NSString *)stage {
    @autoreleasepool {
        UIWindowScene *scene = _window.windowScene;
        NSString *activation = @"unknown";
        switch (scene.activationState) {
            case UISceneActivationStateForegroundActive:
                activation = @"foregroundActive";
                break;
            case UISceneActivationStateForegroundInactive:
                activation = @"foregroundInactive";
                break;
            case UISceneActivationStateBackground:
                activation = @"background";
                break;
            case UISceneActivationStateUnattached:
                activation = @"unattached";
                break;
            default:
                break;
        }

        NSString *report = [NSString stringWithFormat:
            @"stage=%@\ntime=%@\nvisible=%d\npanelWindowClass=%@\npanelWindowIsKey=%d\n"
            @"sceneState=%@\nfirstResponder=%d\nkeyboardWindows=%@\n",
            stage,
            [NSDate date],
            (int)_visible,
            NSStringFromClass([_window class]),
            (int)_window.isKeyWindow,
            activation,
            (int)[_panel isSearchFieldFirstResponder],
            ADKeyboardWindowSummary()];

        NSString *directory = ADRequestDirectoryPath();
        [[NSFileManager defaultManager] createDirectoryAtPath:directory
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:NULL];
        [report writeToFile:[directory stringByAppendingPathComponent:@"diag.txt"]
                  atomically:YES
                    encoding:NSUTF8StringEncoding
                       error:NULL];
    }
}

#pragma mark - URL 指令

- (void)handleURL:(NSURL *)URL {
    if (!ADURLIsAppDrawerURL(URL)) {
        return;
    }

    NSString *host = [[URL host] lowercaseString] ?: @"";
    NSString *path = [URL path] ?: @"";

    if ([host isEqualToString:@"close"] || [path isEqualToString:@"/close"]) {
        [self hidePanel];
        return;
    }

    // 强制清理指令：无论面板处于什么状态，立刻摘掉。
    if ([host isEqualToString:@"reset"]) {
        [self _teardownPanelSynchronously];
        return;
    }

    if ([host isEqualToString:@"open"] || [path hasPrefix:@"/open"]) {
        NSString *bundleIdentifier = ADURLQueryValue(URL, @"bundle");
        if (bundleIdentifier.length == 0) {
            bundleIdentifier = ADURLQueryValue(URL, @"id");
        }
        if (bundleIdentifier.length == 0 && [host isEqualToString:@"open"] && path.length > 1) {
            bundleIdentifier = [path substringFromIndex:1];
        }
        if (bundleIdentifier.length) {
            [self openApplication:bundleIdentifier];
            return;
        }
    }

    NSString *query = ADURLQueryValue(URL, @"q");
    if (query.length == 0) {
        query = ADURLQueryValue(URL, @"query");
    }
    [self showPanelWithQuery:query];
}

@end
