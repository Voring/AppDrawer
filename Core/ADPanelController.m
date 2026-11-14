#import "ADPanelController.h"

#import <UIKit/UIKit.h>

#import "../Shared/URLScheme/ADURLScheme.h"
#import "ADAppCatalog.h"
#import "ADLauncher.h"
#import "ADPanelViewController.h"

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

// SpringBoard 的键盘（SBMedusaHostedKeyboardWindow）只跟「当前 key window 所在的场景」
// 走。自己新建一个 UIWindow 即使 canBecomeKeyWindow 返回 YES、isKeyWindow 为真，
// medusa 也不会把我们的输入框当成前台键盘焦点 —— 所以必须挂到 SpringBoard 自己的
// key window 上，键盘才有落点。
static UIWindow *ADHostWindow(UIWindowScene *scene) {
    UIWindow *keyWindow = nil;
    UIWindow *topWindow = nil;
    for (UIWindow *window in scene.windows) {
        if (window.isHidden || window.alpha <= 0.0) {
            continue;
        }
        if (window.isKeyWindow) {
            keyWindow = window;
            break;
        }
        if (!topWindow || window.windowLevel > topWindow.windowLevel) {
            topWindow = window;
        }
    }
    return keyWindow ?: topWindow;
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
    // 承载面板的容器：加在 SpringBoard key window 上，随窗口尺寸走。
    UIView *_containerView;
    UIWindow *_hostWindow;
    UIViewController *_hostViewController;
    BOOL _visible;
    // 收起动画的「代次」：每次 show/hide 都自增，过期的延时清理直接作废。
    NSUInteger _teardownToken;
    // 键盘是否已经真的弹出来过。弹出来之后就不再重聚焦，
    // 否则用户按第三方输入法的「收起键盘」会被我们的重试立刻顶回去（要点两次）。
    BOOL _keyboardShown;
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
        [center addObserver:self
                   selector:@selector(_handleKeyboardWillShow:)
                       name:UIKeyboardWillShowNotification
                     object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)_handleKeyboardWillShow:(NSNotification *)notification {
    if (!_visible || !_panel) {
        return;
    }
    _keyboardShown = YES;
    [self _logStage:@"keyboard-will-show"];
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
    UIWindow *hostWindow = scene ? ADHostWindow(scene) : nil;
    if (!hostWindow) {
        return;
    }

    // 先清掉任何残留状态，避免上一次异常留下半吊子面板。
    [self _teardownPanelSynchronously];

    _hostWindow = hostWindow;
    _hostViewController = hostWindow.rootViewController;

    _containerView = [[UIView alloc] initWithFrame:hostWindow.bounds];
    _containerView.backgroundColor = [UIColor clearColor];
    _containerView.opaque = NO;
    _containerView.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                                      UIViewAutoresizingFlexibleHeight;
    [hostWindow addSubview:_containerView];

    _panel = [[ADPanelViewController alloc] init];
    __weak typeof(self) weakSelf = self;
    _panel.onRequestClose = ^{
      [weakSelf hidePanel];
    };
    _panel.onRequestOpenApplication = ^(NSString *bundleIdentifier) {
      [weakSelf openApplication:bundleIdentifier];
    };

    // 面板作为子控制器挂在同一个宿主上：键盘焦点、场景、屏幕圆角全部跟系统一致。
    if (_hostViewController) {
        [_hostViewController addChildViewController:_panel];
    }
    _panel.view.frame = _containerView.bounds;
    _panel.view.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                                   UIViewAutoresizingFlexibleHeight;
    [_containerView addSubview:_panel.view];
    if (_hostViewController) {
        [_panel didMoveToParentViewController:_hostViewController];
    }

    _visible = YES;
    _keyboardShown = NO;

    [_panel setApplications:[ADAppCatalog cachedApplications]];
    [_panel setQuery:query];
    [_panel.view setNeedsLayout];
    [_panel.view layoutIfNeeded];
    [_panel animateIn];

    [self _refreshApplications];
    [self _scheduleKeyboardRetries];
    [self _logStage:@"show"];
}

// 键盘没上来时，在头两秒里补几次聚焦。
// 这里不再抢 key window —— 宿主窗口本来就是 SpringBoard 的 key window，
// 抢来抢去只会和系统/第三方输入法打架（表现为「收起键盘要点两次」）。
- (void)_scheduleKeyboardRetries {
    NSArray<NSNumber *> *delays = @[@0.20, @0.45, @0.80, @1.30, @2.00];
    __weak typeof(self) weakSelf = self;

    for (NSNumber *number in delays) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(number.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
                         ADPanelController *strongSelf = weakSelf;
                         if (!strongSelf || !strongSelf->_visible || !strongSelf->_panel) {
                             return;
                         }
                         // 键盘已经出来过就不再来回重聚焦：会和用户主动收起键盘打架。
                         if (strongSelf->_keyboardShown) {
                             return;
                         }
                         // 已经是第一响应者时再调 becomeFirstResponder 是空操作，
                         // 键盘不会被重新呈现，所以先 resign 再聚焦。
                         if ([strongSelf->_panel isSearchFieldFirstResponder]) {
                             [strongSelf->_panel.view endEditing:YES];
                         }
                         [strongSelf->_panel focusSearchField];
                         [strongSelf _logStage:[NSString stringWithFormat:@"retry-%@s", number]];
                       });
    }
}

- (void)openApplication:(NSString *)bundleIdentifier {
    if (bundleIdentifier.length == 0) {
        return;
    }
    // 先把覆盖层无条件摘掉，再隔一个 runloop 发跳转；
    // ScreenCore 建浮窗场景不能和「面板收起」挤在同一帧。
    // 这条路径不做收起动画：动画期间残留的视图会干扰 SC 建浮窗。
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

// 同步、幂等地把面板从视图层级和控制器树上摘掉。
// 关键：清理动作不挂在动画 completion 上，主线程被卡住时也能保证覆盖层移除。
- (void)_teardownPanelSynchronously {
    _teardownToken++;
    _keyboardShown = NO;
    if (_panel) {
        [_panel.view endEditing:YES];
        [_panel willMoveToParentViewController:nil];
        // resign 第一响应者之后再拆视图，避免键盘残留在别的窗口上。
        if (_panel.view.isFirstResponder) {
            [_panel.view resignFirstResponder];
        }
        [_panel.view removeFromSuperview];
        [_panel removeFromParentViewController];
        _panel = nil;
    }
    if (_containerView) {
        [_containerView removeFromSuperview];
        _containerView = nil;
    }
    _hostViewController = nil;
    _hostWindow = nil;
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

// 追加式日志，真机排查时用 Filza 打开
// /var/mobile/Library/Preferences/com.voring.appdrawer/diag.txt 即可。
// 只覆盖写会丢掉关键时序（比如键盘是在面板摘掉之后才弹的），所以改成按阶段追加。
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
                [names addObject:[NSString stringWithFormat:@"%@(level=%.0f,key=%d,hidden=%d)",
                                                            className,
                                                            window.windowLevel,
                                                            (int)window.isKeyWindow,
                                                            (int)window.isHidden]];
            }
        }
    }
    return names.count ? [names componentsJoinedByString:@"|"] : @"none";
}

- (UISearchBar *)_panelSearchBar {
    if (!_panel) {
        return nil;
    }
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:_panel.view];
    while (queue.count > 0) {
        UIView *view = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if ([view isKindOfClass:[UISearchBar class]]) {
            return (UISearchBar *)view;
        }
        for (UIView *child in view.subviews) {
            [queue addObject:child];
        }
    }
    return nil;
}

- (void)_logStage:(NSString *)stage {
    @autoreleasepool {
        UIWindowScene *scene = _hostWindow.windowScene;
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

        NSString *searchFieldInfo = @"none";
        UISearchBar *searchBar = [self _panelSearchBar];
        if (searchBar) {
            UITextField *field = searchBar.searchTextField;
            searchFieldInfo = [NSString stringWithFormat:
                @"frame=%@,inHostWindow=%d,alpha=%.2f,hidden=%d,enabled=%d",
                NSStringFromCGRect(field.frame),
                (int)(field.window != nil),
                field.alpha, (int)field.isHidden, (int)field.enabled];
        }

        NSString *line = [NSString stringWithFormat:
            @"[%@] stage=%@ visible=%d hostWindow=%@ hostIsKey=%d hostLevel=%.0f "
            @"container=%@ panel=%d bounds=%.0fx%.0f scene=%@ responder=%d "
            @"keyboardWindows=%@ searchField=%@",
            [NSDate date],
            stage,
            (int)_visible,
            NSStringFromClass([_hostWindow class]),
            (int)_hostWindow.isKeyWindow,
            _hostWindow.windowLevel,
            NSStringFromCGRect(_containerView.frame),
            (int)(_panel != nil),
            CGRectGetWidth(_containerView.bounds),
            CGRectGetHeight(_containerView.bounds),
            activation,
            (int)[_panel isSearchFieldFirstResponder],
            ADKeyboardWindowSummary(),
            searchFieldInfo];

        NSString *directory = ADRequestDirectoryPath();
        [[NSFileManager defaultManager] createDirectoryAtPath:directory
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:NULL];
        NSString *path = [directory stringByAppendingPathComponent:@"diag.txt"];
        NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path
                                                                                   error:NULL];
        if ([attributes fileSize] > 64 * 1024) {
            [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
        }
        NSString *existing = [NSString stringWithContentsOfFile:path
                                                       encoding:NSUTF8StringEncoding
                                                          error:NULL] ?: @"";
        NSString *updated = [existing stringByAppendingFormat:@"%@\n", line];
        [updated writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
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
