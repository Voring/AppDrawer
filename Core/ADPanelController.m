#import "ADPanelController.h"

#import <UIKit/UIKit.h>

#import "../Shared/URLScheme/ADURLScheme.h"
#import "ADAppCatalog.h"
#import "ADLauncher.h"
#import "ADPanelViewController.h"

#pragma mark - 面板窗口（仅在无法嵌入 SpringBoard 自己的窗口时使用）

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

static UIWindow *ADKeyWindowOfScene(UIWindowScene *scene) {
    UIWindow *candidate = nil;
    for (UIWindow *window in scene.windows) {
        if (window.hidden || window.alpha <= 0.01) {
            continue;
        }
        if (window.isKeyWindow) {
            return window;
        }
        if (!candidate) {
            candidate = window;
        }
    }
    return candidate ?: scene.windows.firstObject;
}

static UIWindow *ADApplicationKeyWindow(void) {
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (scene.activationState != UISceneActivationStateForegroundActive) {
            continue;
        }
        if (![scene isKindOfClass:[UIWindowScene class]]) {
            continue;
        }
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.isKeyWindow) {
                return window;
            }
        }
    }
    return nil;
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
    ADPanelWindow *_window;      // 独立窗口模式
    UIWindow *_hostWindow;       // 嵌入 SpringBoard 自身窗口模式
    BOOL _visible;
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
    }
    return self;
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

    UIWindow *hostWindow = ADKeyWindowOfScene(scene);

    _panel = [[ADPanelViewController alloc] init];
    __weak typeof(self) weakSelf = self;
    _panel.onRequestClose = ^{
      [weakSelf hidePanel];
    };
    _panel.onRequestOpenApplication = ^(NSString *bundleIdentifier) {
      [weakSelf openApplication:bundleIdentifier];
    };

    // 关键：优先把面板塞进 SpringBoard 自己的窗口。
    // 键盘(event)只认 key window，自己另开一个窗口在 SpringBoard 里迟早会丢 key，
    // 塞进系统窗口最省事，也不会和 ScreenCore 抢窗口层级。
    if ([self _embedPanelIntoWindow:hostWindow]) {
        _hostWindow = hostWindow;
    } else {
        [self _presentInOwnWindowWithScene:scene];
    }

    _visible = YES;

    [_panel setApplications:[ADAppCatalog cachedApplications]];
    [_panel setQuery:query];
    [_panel.view setNeedsLayout];
    [_panel.view layoutIfNeeded];
    [_panel animateIn];

    [self _refreshApplications];
    [self _writeDiagnostics:@"after-show"];

    // 等面板真正上屏再叫键盘，避免 SpringBoard 把 firstResponder 重置掉。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                     ADPanelController *strongSelf = weakSelf;
                     if (!strongSelf || !strongSelf->_visible || !strongSelf->_panel) {
                         return;
                     }
                     [strongSelf->_panel.view.window makeKeyWindow];
                     [strongSelf->_panel focusSearchField];
                     [strongSelf _writeDiagnostics:@"0.25s-later"];
                   });
}

- (BOOL)_embedPanelIntoWindow:(UIWindow *)window {
    if (!window || window.hidden) {
        return NO;
    }
    CGRect bounds = window.bounds;
    if (CGRectGetWidth(bounds) < 1.0 || CGRectGetHeight(bounds) < 1.0) {
        return NO;
    }

    UIView *panelView = _panel.view;
    panelView.frame = bounds;
    panelView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [window addSubview:panelView];
    return YES;
}

- (void)_presentInOwnWindowWithScene:(UIWindowScene *)scene {
    _window = [[ADPanelWindow alloc] initWithWindowScene:scene];
    _window.frame = scene.coordinateSpace.bounds;
    _window.windowLevel = 10000001.0;
    _window.backgroundColor = [UIColor clearColor];
    _window.opaque = NO;
    _window.rootViewController = _panel;
    _window.hidden = NO;
    [_window makeKeyAndVisible];
}

- (void)openApplication:(NSString *)bundleIdentifier {
    if (bundleIdentifier.length == 0) {
        return;
    }
    [self hidePanelWithCompletion:^{
      // 面板收起动画跑完再发跳转请求：ScreenCore 建浮窗场景本身很重，
      // 和收起动画挤在同一个 runloop 里就会卡住 SpringBoard。
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
                     dispatch_get_main_queue(), ^{
                       ADOpenApplication(bundleIdentifier);
                     });
    }];
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
        if (completion) {
            completion();
        }
        return;
    }

    _visible = NO;
    ADPanelViewController *panel = _panel;
    __weak typeof(self) weakSelf = self;

    [panel animateOutWithCompletion:^{
      ADPanelController *strongSelf = weakSelf;
      if (!strongSelf) {
          if (completion) {
              completion();
          }
          return;
      }

      [panel.view removeFromSuperview];

      UIWindow *previousKeyWindow = nil;
      if (strongSelf->_window) {
          previousKeyWindow = ADKeyWindowOfScene(strongSelf->_window.windowScene);
          strongSelf->_window.hidden = YES;
          [strongSelf->_window resignKeyWindow];
          strongSelf->_window.rootViewController = nil;
          strongSelf->_window = nil;
      }
      strongSelf->_hostWindow = nil;
      strongSelf->_panel = nil;

      if (previousKeyWindow && !previousKeyWindow.isKeyWindow) {
          [previousKeyWindow makeKeyWindow];
      }
      if (completion) {
          completion();
      }
    }];
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

// 面板 / 键盘状态写盘，真机出问题时可以直接用 Filza 打开查看。
- (void)_writeDiagnostics:(NSString *)stage {
    @autoreleasepool {
        UIWindow *panelWindow = _panel.view.window;
        UIWindow *applicationKeyWindow = ADApplicationKeyWindow();

        NSString *report = [NSString stringWithFormat:
            @"stage=%@\ntime=%@\npanelVisible=%d\nhostMode=%@\npanelWindowClass=%@\npanelWindowIsKey=%d\nappKeyWindow=%@\nsearchFieldFirstResponder=%d\n",
            stage,
            [NSDate date],
            (int)_visible,
            _hostWindow ? @"embedded" : @"own-window",
            NSStringFromClass([panelWindow class]),
            (int)panelWindow.isKeyWindow,
            NSStringFromClass([applicationKeyWindow class]),
            (int)[_panel isSearchFieldFirstResponder]];

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
