#import "ADPanelController.h"

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#import "../Shared/URLScheme/ADURLScheme.h"
#import "ADAppCatalog.h"
#import "ADLauncher.h"
#import "ADPanelViewController.h"

// 重写版（1.3.0）：
// 1) 面板窗口仍然用「自己新建一个 SpringBoard 窗口实例」的方式，绝不嵌进 SpringBoard 的 key window。
// 2) 窗口优先挂到「真正持有键盘窗口的那个场景」，这样 becomeFirstResponder 之后系统才愿意
//    在这个场景里建立文本输入会话；找不到键盘场景时退回窗口最多的场景（SpringBoard 主场景）。
// 3) 面板窗口尺寸取所挂场景的坐标空间，横屏时自然得到 852×393。
// 4) 不做任何同步磁盘写入：诊断行改为后台队列、定长环形（最多 24 行），且只在唤出时写。

static NSString *const ADPanelTraitsRole = @"SBTraitsParticipantRoleTransientOverlay";
static NSString *const ADPanelDebugName = @"AppDrawerPanel";

#pragma mark - 诊断（后台、定长、绝不阻塞主线程）

static void ADDiagLine(NSString *line) {
    if (line.length == 0) {
        return;
    }
    static dispatch_queue_t queue;
    static NSMutableArray<NSString *> *lines;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
      queue = dispatch_queue_create("com.voring.appdrawer.panel.diag", DISPATCH_QUEUE_SERIAL);
      lines = [NSMutableArray array];
    });
    dispatch_async(queue, ^{
      [lines addObject:line];
      while (lines.count > 24) {
          [lines removeObjectAtIndex:0];
      }
      NSString *directory = ADRequestDirectoryPath();
      [[NSFileManager defaultManager] createDirectoryAtPath:directory
                                withIntermediateDirectories:YES
                                                 attributes:nil
                                                      error:NULL];
      NSString *path = [directory stringByAppendingPathComponent:@"diag.txt"];
      [[lines componentsJoinedByString:@"\n"] writeToFile:path
                                               atomically:YES
                                                 encoding:NSUTF8StringEncoding
                                                    error:NULL];
    });
}

#pragma mark - 窗口

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

// 在目标基类之上注册我们自己的子类，逐个缓存，避免重复注册同名类。
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

// 私有初始化器在 SDK 里没有声明，统一走 NSInvocation，异常不外泄。
static id ADInvokeInit(Class cls, SEL sel, NSArray *arguments) {
    NSMethodSignature *signature = [cls instanceMethodSignatureForSelector:sel];
    if (!signature || signature.numberOfArguments != arguments.count + 2) {
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
    } @catch (__unused NSException *exception) {
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
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static UIWindow *ADCreatePanelWindow(UIWindowScene *scene, UIViewController *controller) {
    SEL layoutSel = NSSelectorFromString(@"initWithWindowScene:rootViewController:layoutStrategy:role:debugName:");
    SEL roleSel = NSSelectorFromString(@"initWithWindowScene:rootViewController:role:debugName:");
    SEL plainSel = NSSelectorFromString(@"initWithWindowScene:rootViewController:");

    NSArray<NSString *> *baseNames = @[ @"SBTransientOverlayWindow", @"SBWindow", @"SBFWindow" ];
    NSArray<NSString *> *roleValues = @[ ADPanelTraitsRole, @"" ];

    for (NSString *baseName in baseNames) {
        Class base = NSClassFromString(baseName);
        if (!base || ![base isSubclassOfClass:[UIWindow class]]) {
            continue;
        }
        Class cls = ADPanelWindowClassForBase(base);
        if (!cls) {
            continue;
        }

        for (NSString *role in roleValues) {
            id layoutStrategy = ADLayoutStrategyForClass(cls);
            NSArray *layoutArguments = @[
                scene, controller, layoutStrategy ?: [NSNull null], role, ADPanelDebugName
            ];
            id window = ADInvokeInit(cls, layoutSel, layoutArguments);
            if ([window isKindOfClass:[UIWindow class]]) {
                return (UIWindow *)window;
            }

            id roleWindow = ADInvokeInit(cls, roleSel, @[ scene, controller, role, ADPanelDebugName ]);
            if ([roleWindow isKindOfClass:[UIWindow class]]) {
                return (UIWindow *)roleWindow;
            }
        }

        id plainWindow = ADInvokeInit(cls, plainSel, @[ scene, controller ]);
        if ([plainWindow isKindOfClass:[UIWindow class]]) {
            return (UIWindow *)plainWindow;
        }
    }

    return [[ADPanelPlainWindow alloc] initWithWindowScene:scene];
}

#pragma mark - 场景选择

static BOOL ADSceneHasKeyboardWindow(UIWindowScene *scene) {
    for (UIWindow *window in scene.windows) {
        NSString *name = NSStringFromClass([window class]);
        if ([name rangeOfString:@"Keyboard" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            return YES;
        }
    }
    return NO;
}

// 优先：真正挂着键盘窗口的场景（键盘只会在它自己所属的场景里被宿主化）。
// 其次：窗口最多的场景（SpringBoard 主场景）。
// 最后：任意 foreground active 的窗口场景。
static UIWindowScene *ADPanelHostWindowScene(void) {
    UIWindowScene *busiest = nil;
    UIWindowScene *foreground = nil;
    NSUInteger busiestCount = 0;

    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) {
            continue;
        }
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        if (ADSceneHasKeyboardWindow(windowScene)) {
            return windowScene;
        }
        if (!foreground && windowScene.activationState == UISceneActivationStateForegroundActive) {
            foreground = windowScene;
        }
        NSUInteger count = windowScene.windows.count;
        if (count > busiestCount) {
            busiestCount = count;
            busiest = windowScene;
        }
    }
    return busiest ?: foreground;
}

#pragma mark - 工具

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

#pragma mark - 控制器

@implementation ADPanelController {
    ADPanelViewController *_panel;
    UIWindow *_window;
    BOOL _visible;
    NSUInteger _teardownToken;
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

    UIWindowScene *scene = ADPanelHostWindowScene();
    if (!scene) {
        return;
    }

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
    _window.frame = scene.coordinateSpace.bounds;
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
    [self _scheduleKeyboardFocus];
    ADDiagLine([NSString stringWithFormat:@"[%@] show win=%@ frame=%@ sceneHasKeyboard=%d",
                                          [NSDate date],
                                          NSStringFromClass([_window class]),
                                          NSStringFromCGRect(_window.frame),
                                          (int)ADSceneHasKeyboardWindow(scene)]);
}

// 唤出后头两秒里反复把 key 抢回来并重聚焦；键盘通知一到就停手。
- (void)_scheduleKeyboardFocus {
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
                       });
    }
}

- (void)openApplication:(NSString *)bundleIdentifier {
    if (bundleIdentifier.length == 0) {
        return;
    }
    // 先摘覆盖层，再隔一个 runloop 交给 ScreenCore 建浮窗。
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
