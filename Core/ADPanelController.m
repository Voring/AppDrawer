#import "ADPanelController.h"

#import <CaptainHook/CaptainHook.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>

#import "../Shared/URLScheme/ADURLScheme.h"
#import "ADAppCatalog.h"
#import "ADLauncher.h"
#import "ADPanelViewController.h"

CHDeclareClass(UIWindow);

#pragma mark - 面板窗口

@interface ADPanelWindow : UIWindow
@end

@implementation ADPanelWindow

- (BOOL)canBecomeKeyWindow {
    return YES;
}

@end

#pragma mark - 工具

static ADPanelWindow *ADActivePanelWindow = nil;

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
    for (UIWindow *window in scene.windows) {
        if (window.isKeyWindow) {
            return window;
        }
    }
    return scene.windows.firstObject;
}

// 不用已废弃的 UIApplication.keyWindow，自己扫一遍 connectedScenes。
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

// SpringBoard 会时不时把自己的主窗口重新设成 key window，
// 面板窗口一旦丢 key，键盘就没有落点。这里在别的窗口抢 key 时把面板抢回来。
CHOptimizedMethod0(self, void, UIWindow, makeKeyWindow) {
    CHSuper0(UIWindow, makeKeyWindow);

    ADPanelWindow *panelWindow = ADActivePanelWindow;
    if (panelWindow && self != panelWindow && !panelWindow.hidden && [NSThread isMainThread]) {
        [panelWindow makeKeyWindow];
    }
}

static void ADAttemptPrivateKeyboardFocus(UIWindow *window) {
    id application = [UIApplication sharedApplication];
    NSArray<NSString *> *selectors = @[ @"_setKeyboardFocusWindow:", @"setKeyboardFocusWindow:" ];
    for (NSString *selectorName in selectors) {
        SEL selector = NSSelectorFromString(selectorName);
        if ([application respondsToSelector:selector]) {
            @try {
                ((void (*)(id, SEL, id))objc_msgSend)(application, selector, window);
            } @catch (__unused NSException *exception) {
            }
            return;
        }
    }
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
    ADPanelWindow *_window;
    ADPanelViewController *_panel;
    UIWindow *_previousKeyWindow;
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
        if (NSClassFromString(@"UIWindow")) {
            CHLoadClass(UIWindow);
            CHHook0(UIWindow, makeKeyWindow);
        }

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

    _previousKeyWindow = ADKeyWindowOfScene(scene);

    _window = [[ADPanelWindow alloc] initWithWindowScene:scene];
    _window.frame = scene.coordinateSpace.bounds;
    _window.windowLevel = 10000001.0;
    _window.backgroundColor = [UIColor clearColor];
    _window.opaque = NO;

    _panel = [[ADPanelViewController alloc] init];
    __weak typeof(self) weakSelf = self;
    _panel.onRequestClose = ^{
      [weakSelf hidePanel];
    };
    _panel.onRequestOpenApplication = ^(NSString *bundleIdentifier) {
      [weakSelf openApplication:bundleIdentifier];
    };

    _window.rootViewController = _panel;
    _window.hidden = NO;
    [_window makeKeyAndVisible];
    _visible = YES;
    ADActivePanelWindow = _window;

    ADAttemptPrivateKeyboardFocus(_window);

    [_panel setApplications:[ADAppCatalog cachedApplications]];
    [_panel setQuery:query];
    [_panel.view setNeedsLayout];
    [_panel.view layoutIfNeeded];
    [_panel animateIn];

    [self _refreshApplications];
    [self _writeDiagnostics:@"after-show"];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                     ADPanelController *strongSelf = weakSelf;
                     if (!strongSelf || !strongSelf->_visible || !strongSelf->_window) {
                         return;
                     }
                     [strongSelf->_window makeKeyWindow];
                     ADAttemptPrivateKeyboardFocus(strongSelf->_window);
                     [strongSelf->_panel focusSearchField];
                     [strongSelf _writeDiagnostics:@"0.5s-later"];
                   });
}

- (void)openApplication:(NSString *)bundleIdentifier {
    if (bundleIdentifier.length == 0) {
        return;
    }
    [self hidePanelWithCompletion:^{
      ADOpenApplication(bundleIdentifier);
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

      UIWindow *previousKeyWindow = strongSelf->_previousKeyWindow;
      ADActivePanelWindow = nil;
      strongSelf->_window.hidden = YES;
      [strongSelf->_window resignKeyWindow];
      strongSelf->_window.rootViewController = nil;
      strongSelf->_window = nil;
      strongSelf->_panel = nil;
      strongSelf->_previousKeyWindow = nil;

      if (previousKeyWindow) {
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
        UIWindow *applicationKeyWindow = ADApplicationKeyWindow();
        UIWindowScene *scene = _window.windowScene;
        UIWindow *sceneKeyWindow = nil;
        for (UIWindow *window in scene.windows) {
            if (window.isKeyWindow) {
                sceneKeyWindow = window;
            }
        }

        NSString *report = [NSString stringWithFormat:
            @"stage=%@\ntime=%@\npanelVisible=%d\nappKeyWindow=%@\npanelWindowIsKey=%d\npanelWindowHidden=%d\nsceneKeyWindow=%@\nsceneWindowCount=%lu\nsearchFieldFirstResponder=%d\n",
            stage,
            [NSDate date],
            (int)_visible,
            NSStringFromClass([applicationKeyWindow class]),
            (int)_window.isKeyWindow,
            (int)_window.hidden,
            NSStringFromClass([sceneKeyWindow class]),
            (unsigned long)scene.windows.count,
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
