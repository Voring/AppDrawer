#import "ADPanelController.h"

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#import "../Shared/URLScheme/ADURLScheme.h"
#import "ADAppCatalog.h"
#import "ADLauncher.h"
#import "ADPanelViewController.h"

#pragma mark - 面板窗口

// 独立面板窗口：1.0.3 起固定用这个，不再嵌进 SpringBoard 自己的窗口。
// 1.0.2 嵌进 SpringBoard key window 的那次导致主线程卡死 + 覆盖层永久残留，
// 不能再走。
//
// 1.1.7：窗口基类从裸 UIWindow 换成 SpringBoard 自己的 SBWindow（优先
// SBTransientOverlayWindow）。原因：SpringBoard 里键盘焦点由 traits participant
// 决定，裸 UIWindow 没有 participant，所以 medusa 永远不把
// SBMedusaHostedKeyboardWindow 显出来——日志里 isKey=1、responder=1 但键盘
// hidden=1 正是这个症状。
// 注意：这是「我们自己新建一个 SB 窗口实例」，不是把面板塞进 SpringBoard 现有
// 的 key window，后者才是 1.0.2 事故的来源。
static NSString *const ADPanelTraitsRole = @"SBTraitsParticipantRoleTransientOverlay";
static NSString *const ADPanelDebugName = @"AppDrawerPanel";

@interface ADPanelPlainWindow : UIWindow
@end

@implementation ADPanelPlainWindow
- (BOOL)canBecomeKeyWindow {
    return YES;
}
@end

static BOOL ADWindowCanBecomeKeyIMP(id self, SEL _cmd) {
    return YES;
}

// 运行时在 SBWindow 之上注册一个我们自己的子类（名字仍是 ADPanelWindow，
// 方便日志辨认），并允许它成为 key window。不改动系统类本身。
static Class ADPanelWindowClass(NSString **outBaseName) {
    static Class panelClass;
    static NSString *baseName;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
      Class base = NSClassFromString(@"SBTransientOverlayWindow");
      if (!base || ![base isSubclassOfClass:[UIWindow class]]) {
          base = NSClassFromString(@"SBWindow");
      }
      if (!base || ![base isSubclassOfClass:[UIWindow class]]) {
          base = [ADPanelPlainWindow class];
      }
      baseName = NSStringFromClass(base);
      Class cls = objc_allocateClassPair(base, "ADPanelWindow", 0);
      if (cls) {
          class_addMethod(cls, @selector(canBecomeKeyWindow), (IMP)ADWindowCanBecomeKeyIMP, "B@:");
          // SBWindow 内部用的是私有版本，也一并放行。
          class_addMethod(cls, @selector(_canBecomeKeyWindow), (IMP)ADWindowCanBecomeKeyIMP, "B@:");
          objc_registerClassPair(cls);
          panelClass = cls;
      }
    });
    if (outBaseName) {
        *outBaseName = baseName;
    }
    return panelClass;
}

// 按 SBWindow 的初始化签名依次尝试，任何一步失败都回落到裸 UIWindow。
// 这些私有签名在 SDK 里没有声明，只能用实例方法指针调用。
typedef id (*ADLayoutInitFn)(id, SEL, id, id, id, id, id);
typedef id (*ADRoleInitFn)(id, SEL, id, id, id, id);
typedef id (*ADSceneRoleInitFn)(id, SEL, id, id, id);
typedef id (*ADStrategyFn)(id, SEL);

static UIWindow *ADCreatePanelWindow(UIWindowScene *scene, UIViewController *controller) {
    Class cls = ADPanelWindowClass(NULL);
    if (cls && ![cls isSubclassOfClass:[ADPanelPlainWindow class]]) {
        SEL layoutSel = NSSelectorFromString(
            @"initWithWindowScene:rootViewController:layoutStrategy:role:debugName:");
        SEL roleSel = NSSelectorFromString(@"initWithWindowScene:rootViewController:role:debugName:");
        SEL sceneRoleSel = NSSelectorFromString(@"initWithWindowScene:role:debugName:");

        @try {
            if ([cls instancesRespondToSelector:layoutSel]) {
                id strategy = nil;
                SEL strategySel = NSSelectorFromString(@"defaultLayoutStrategy");
                if ([cls respondsToSelector:strategySel]) {
                    ADStrategyFn strategyFn = (ADStrategyFn)[cls methodForSelector:strategySel];
                    strategy = strategyFn(cls, strategySel);
                }
                ADLayoutInitFn initFn = (ADLayoutInitFn)[cls instanceMethodForSelector:layoutSel];
                UIWindow *window = initFn([cls alloc], layoutSel, scene, controller, strategy,
                                          ADPanelTraitsRole, ADPanelDebugName);
                if ([window isKindOfClass:[UIWindow class]]) {
                    return window;
                }
            }
        } @catch (NSException *exception) {
            NSLog(@"[AppDrawer] SBWindow layout init failed: %@", exception.reason);
        }

        @try {
            if ([cls instancesRespondToSelector:roleSel]) {
                ADRoleInitFn initFn = (ADRoleInitFn)[cls instanceMethodForSelector:roleSel];
                UIWindow *window = initFn([cls alloc], roleSel, scene, controller, ADPanelTraitsRole,
                                          ADPanelDebugName);
                if ([window isKindOfClass:[UIWindow class]]) {
                    return window;
                }
            }
        } @catch (NSException *exception) {
            NSLog(@"[AppDrawer] SBWindow role init failed: %@", exception.reason);
        }

        @try {
            if ([cls instancesRespondToSelector:sceneRoleSel]) {
                ADSceneRoleInitFn initFn = (ADSceneRoleInitFn)[cls instanceMethodForSelector:sceneRoleSel];
                UIWindow *window = initFn([cls alloc], sceneRoleSel, scene, ADPanelTraitsRole,
                                          ADPanelDebugName);
                if ([window isKindOfClass:[UIWindow class]]) {
                    window.rootViewController = controller;
                    return window;
                }
            }
        } @catch (NSException *exception) {
            NSLog(@"[AppDrawer] SBWindow scene init failed: %@", exception.reason);
        }
    }

    return [[ADPanelPlainWindow alloc] initWithWindowScene:scene];
}

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
    UIWindow *_window;
    BOOL _visible;
    // 收起动画的「代次」：每次 show/hide 都自增，过期的延时清理直接作废。
    NSUInteger _teardownToken;
    // 键盘是否已经真的弹出来过。弹出来之后就不再抢 key / 重聚焦，
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

    _window = ADCreatePanelWindow(scene, _panel);
    // 取当前方向的场景坐标：横竖屏在唤醒时判定一次，之后不做实时跟随。
    _window.frame = scene.coordinateSpace.bounds;
    // 1.0.7 键盘可用时就是这个层级，回退到它。
    _window.windowLevel = 10000001.0;
    _window.backgroundColor = [UIColor clearColor];
    _window.opaque = NO;
    _window.rootViewController = _panel;
    _window.hidden = NO;
    [_window makeKeyAndVisible];

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

// SpringBoard 会在场景激活时把自己的窗口重新设回 key window，
// 我们的搜索框即便拿到 first responder，窗口一旦丢 key，键盘就会被 UIKit 抑制。
// 所以在头两秒里反复把 key 抢回来并重新聚焦。
// 一旦 UIKeyboardWillShowNotification 到了（键盘真的弹出来了），就停止重试，
// 把控制权还给用户，避免和第三方输入法自带的「收起键盘」打架。
// —— 这一段与 1.0.7（键盘验收可用版本）逐行一致，不要加 resign 之类的额外动作。
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
                         if (strongSelf->_keyboardShown) {
                             return;
                         }
                         [strongSelf->_window makeKeyWindow];
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
    _keyboardShown = NO;
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

// 追加式日志，真机排查时用 Filza 打开
// /var/mobile/Library/Preferences/com.voring.appdrawer/diag.txt 即可。
// 覆盖写会丢掉时序（上一次就出现「键盘通知是在面板摘掉之后才到的」），所以按阶段追加。
// 窗口到底是 SB 窗口还是裸 UIWindow，以及有没有 traits participant。
static NSString *ADWindowKind(UIWindow *window) {
    if (!window) {
        return @"none";
    }
    Class sbWindowClass = NSClassFromString(@"SBWindow");
    if (sbWindowClass && [window isKindOfClass:sbWindowClass]) {
        NSString *traits = @"nil";
        @try {
            id participant = [window performSelector:@selector(_traitsParticipant)];
            if (participant) {
                traits = NSStringFromClass([participant class]);
            }
        } @catch (NSException *exception) {
        }
        return [NSString stringWithFormat:@"%@(SB,traits=%@)", NSStringFromClass([window class]),
                                          traits];
    }
    return [NSString stringWithFormat:@"%@(plainUIWindow)", NSStringFromClass([window class])];
}

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

        NSString *searchFieldInfo = @"none";
        UISearchBar *searchBar = [self _panelSearchBar];
        if (searchBar) {
            UITextField *field = searchBar.searchTextField;
            searchFieldInfo = [NSString stringWithFormat:
                @"frame=%@,inPanelWindow=%d,alpha=%.2f,hidden=%d,enabled=%d",
                NSStringFromCGRect(field.frame),
                (int)(field.window == _window),
                field.alpha, (int)field.isHidden, (int)field.enabled];
        }

        NSString *line = [NSString stringWithFormat:
            @"[%@] stage=%@ visible=%d panelWindow=%@ isKey=%d hidden=%d level=%.0f "
            @"frame=%@ scene=%@ responder=%d keyboardWindows=%@ searchField=%@",
            [NSDate date],
            stage,
            (int)_visible,
            ADWindowKind(_window),
            (int)_window.isKeyWindow,
            (int)_window.isHidden,
            _window.windowLevel,
            NSStringFromCGRect(_window.frame),
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
