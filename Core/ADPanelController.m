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
// 1.1.9：窗口优先创建成 SpringBoard 的 SBWindow 实例（SBTransientOverlayWindow >
// SBWindow > SBFWindow > 裸 UIWindow 依次尝试），并把每一步的结果写进 diag。
// 原因：1.1.7 尝试过 SBWindow，但真机日志显示最后回落成裸 UIWindow，
// 而失败原因只 NSLog 到了系统日志、没进 diag，等于白试一次。
// 注意：仍然是「我们自己新建一个窗口实例」，不是把面板塞进 SpringBoard 现有
// 的 key window。
static NSString *const ADPanelTraitsRole = @"SBTraitsParticipantRoleTransientOverlay";
static NSString *const ADPanelDebugName = @"AppDrawerPanel";

static void ADAppendDiagLine(NSString *line);

// 窗口创建过程的诊断记录，创建完成后一次性写进 diag。
static NSMutableString *ADWindowDiagLog(void) {
    static NSMutableString *log;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
      log = [NSMutableString string];
    });
    return log;
}

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

// 运行时在目标基类之上注册我们自己的 ADPanelWindow 子类。
static Class ADPanelWindowClassForBase(Class base) {
    static NSMutableDictionary<NSString *, id> *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
      cache = [NSMutableDictionary dictionary];
    });
    if (!base) {
        return Nil;
    }
    NSString *key = NSStringFromClass(base);
    id cached = cache[key];
    if (cached) {
        return [cached isKindOfClass:[NSNull class]] ? Nil : cached;
    }
    static NSUInteger serial = 0;
    NSString *name = [NSString stringWithFormat:@"ADPanelWindow_%lu", (unsigned long)++serial];
    Class cls = objc_allocateClassPair(base, name.UTF8String, 0);
    if (!cls) {
        cache[key] = [NSNull null];
        return Nil;
    }
    class_addMethod(cls, @selector(canBecomeKeyWindow), (IMP)ADWindowCanBecomeKeyIMP, "B@:");
    class_addMethod(cls, @selector(_canBecomeKeyWindow), (IMP)ADWindowCanBecomeKeyIMP, "B@:");
    objc_registerClassPair(cls);
    cache[key] = cls;
    return cls;
}

// 私有签名在 SDK 里没有声明，用 NSInvocation 统一调用，任何异常都不外泄。
static id ADInvokeInit(Class cls, SEL sel, NSArray *arguments, NSString **errorOut) {
    NSMethodSignature *signature = [cls instanceMethodSignatureForSelector:sel];
    if (!signature) {
        if (errorOut) {
            *errorOut = @"no such initializer";
        }
        return nil;
    }
    if (signature.numberOfArguments != arguments.count + 2) {
        if (errorOut) {
            *errorOut = [NSString stringWithFormat:@"arity %lu", (unsigned long)signature.numberOfArguments];
        }
        return nil;
    }
    id target = [cls alloc];
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    invocation.target = target;
    invocation.selector = sel;
    for (NSUInteger index = 0; index < arguments.count; index++) {
        id value = arguments[index];
        [invocation setArgument:&value atIndex:(NSInteger)(index + 2)];
    }
    @try {
        [invocation invoke];
    } @catch (NSException *exception) {
        if (errorOut) {
            *errorOut = exception.reason ?: exception.name;
        }
        return nil;
    }
    __unsafe_unretained id result = nil;
    [invocation getReturnValue:&result];
    return result;
}

static id ADLayoutStrategyForClass(Class cls) {
    SEL sel = NSSelectorFromString(@"defaultLayoutStrategy");
    if (!cls || ![cls respondsToSelector:sel]) {
        return nil;
    }
    @try {
        NSMethodSignature *signature = [cls methodSignatureForSelector:sel];
        if (!signature) {
            return nil;
        }
        NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
        invocation.target = cls;
        invocation.selector = sel;
        [invocation invoke];
        __unsafe_unretained id result = nil;
        [invocation getReturnValue:&result];
        return result;
    } @catch (NSException *exception) {
        return nil;
    }
}

static UIWindow *ADCreatePanelWindow(UIWindowScene *scene, UIViewController *controller) {
    NSMutableString *log = ADWindowDiagLog();
    [log setString:@""];

    NSString *layoutSelName = @"initWithWindowScene:rootViewController:layoutStrategy:role:debugName:";
    NSString *roleSelName = @"initWithWindowScene:rootViewController:role:debugName:";
    NSString *plainSelName = @"initWithWindowScene:rootViewController:";

    // SBFWindow 在 SpringBoardFoundation 里，是 SBWindow 的父类，一并兜底。
    NSArray<NSString *> *baseNames = @[ @"SBTransientOverlayWindow", @"SBWindow", @"SBFWindow" ];
    NSArray<NSString *> *roleValues = @[ ADPanelTraitsRole, @"" ];

    for (NSString *baseName in baseNames) {
        Class base = NSClassFromString(baseName);
        [log appendFormat:@"%@=%@;", baseName, base ? @"yes" : @"no"];
        if (!base || ![base isSubclassOfClass:[UIWindow class]]) {
            continue;
        }
        Class cls = ADPanelWindowClassForBase(base);
        [log appendFormat:@"pair(%@)=%@;", baseName, cls ? NSStringFromClass(cls) : @"nil"];
        if (!cls) {
            continue;
        }

        for (NSString *role in roleValues) {
            NSString *label = [NSString stringWithFormat:@"%@/role=%@", baseName, role.length ? role : @"nil"];

            NSString *error = nil;
            id window = ADInvokeInit(cls,
                                     NSSelectorFromString(layoutSelName),
                                     @[
                                        scene, controller, ADLayoutStrategyForClass(cls) ?: [NSNull null],
                                        role, ADPanelDebugName
                                     ],
                                     &error);
            if ([window isKindOfClass:[UIWindow class]]) {
                [log appendFormat:@"%@ layout->OK;", label];
                return (UIWindow *)window;
            }
            [log appendFormat:@"%@ layout->%@;", label, error ?: @"nil"];

            error = nil;
            window = ADInvokeInit(cls,
                                  NSSelectorFromString(roleSelName),
                                  @[ scene, controller, role, ADPanelDebugName ],
                                  &error);
            if ([window isKindOfClass:[UIWindow class]]) {
                [log appendFormat:@"%@ role->OK;", label];
                return (UIWindow *)window;
            }
            [log appendFormat:@"%@ role->%@;", label, error ?: @"nil"];
        }

        NSString *error = nil;
        id window = ADInvokeInit(cls, NSSelectorFromString(plainSelName), @[ scene, controller ], &error);
        if ([window isKindOfClass:[UIWindow class]]) {
            [log appendFormat:@"%@ plain->OK;", baseName];
            return (UIWindow *)window;
        }
        [log appendFormat:@"%@ plain->%@;", baseName, error ?: @"nil"];
    }

    [log appendString:@"fallback=plainUIWindow;"];
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

    NSMutableString *windowLog = ADWindowDiagLog();
    [windowLog setString:@""];
    _window = ADCreatePanelWindow(scene, _panel);
    ADAppendDiagLine([NSString stringWithFormat:@"[%@] stage=window class=%@ attempts=%@",
                                                [NSDate date], NSStringFromClass([_window class]),
                                                windowLog]);
    // 取当前方向的场景坐标：横竖屏在唤醒时判定一次，之后不做实时跟随。
    _window.frame = scene.coordinateSpace.bounds;
    // 1.0.7（键盘验收可用版本）就是这个层级；1.1.8 试过 998，日志显示键盘窗口
    // 反而彻底不出现，层级不是原因，回到基准值。
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
// 场景里所有窗口的层级 / hidden / key 一览：用来判断键盘窗口到底在不在、
// 是不是被我们的面板窗口压在下面。
static NSString *ADWindowSummary(UIWindowScene *scene, UIWindow *panelWindow) {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (UIWindow *window in scene.windows) {
        NSString *className = NSStringFromClass([window class]);
        if ([className rangeOfString:@"Keyboard" options:NSCaseInsensitiveSearch].location ==
            NSNotFound) {
            if (window != panelWindow) {
                continue;
            }
        }
        [names addObject:[NSString stringWithFormat:@"%@(level=%.0f,key=%d,hidden=%d)",
                                                    className,
                                                    window.windowLevel,
                                                    (int)window.isKeyWindow,
                                                    (int)window.isHidden]];
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

// 往 diag.txt 追加一行原始文本（超过 64KB 清空重写）。
static void ADAppendDiagLine(NSString *line) {
    NSString *directory = ADRequestDirectoryPath();
    [[NSFileManager defaultManager] createDirectoryAtPath:directory
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:NULL];
    NSString *path = [directory stringByAppendingPathComponent:@"diag.txt"];
    NSDictionary *attributes =
        [[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL];
    if ([attributes fileSize] > 64 * 1024) {
        [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
    }
    NSString *existing = [NSString stringWithContentsOfFile:path
                                                   encoding:NSUTF8StringEncoding
                                                      error:NULL] ?: @"";
    NSString *updated = [existing stringByAppendingFormat:@"%@\n", line];
    [updated writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
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
            NSStringFromClass([_window class]),
            (int)_window.isKeyWindow,
            (int)_window.isHidden,
            _window.windowLevel,
            NSStringFromCGRect(_window.frame),
            activation,
            (int)[_panel isSearchFieldFirstResponder],
            ADWindowSummary(scene, _window),
            searchFieldInfo];

        ADAppendDiagLine(line);
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
