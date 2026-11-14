#import "ADLauncher.h"

#import <objc/message.h>
#import <objc/runtime.h>
#import <UIKit/UIKit.h>

#import "ADPrefs.h"

#pragma mark - 参数写入（严格按签名类型，类型不符直接放弃调用）

static void ADSetObjectArgument(NSInvocation *invocation, NSUInteger index, id object) {
    id value = object;
    [invocation setArgument:&value atIndex:(NSInteger)index];
}

static void ADSetRectArgument(NSInvocation *invocation, NSUInteger index, CGRect rect) {
    CGRect value = rect;
    [invocation setArgument:&value atIndex:(NSInteger)index];
}

// 校验某个参数位是不是「对象」类型。
static BOOL ADArgumentIsObject(NSMethodSignature *signature, NSUInteger index) {
    if (index >= signature.numberOfArguments) {
        return NO;
    }
    const char *type = [signature getArgumentTypeAtIndex:index];
    if (!type) {
        return NO;
    }
    return type[0] == '@';
}

// 校验某个参数位是不是和 CGRect 尺寸一致的 C 结构体。
// 私有接口一旦按错误 ABI 传参，很容易把调用线程卡死，所以必须严格比对。
static BOOL ADArgumentIsRect(NSMethodSignature *signature, NSUInteger index) {
    if (index >= signature.numberOfArguments) {
        return NO;
    }
    const char *type = [signature getArgumentTypeAtIndex:index];
    if (!type || type[0] != '{') {
        return NO;
    }
    NSUInteger size = 0;
    NSGetSizeAndAlignment(type, &size, NULL);
    return size == sizeof(CGRect);
}

#pragma mark - ScreenCore 私有接口

// 与 QuickLaunch 相同的最小调用面：
//   [NSClassFromString(@"SCFloatingSceneManager") sc_sharedManager]
//   -sc_openSplitForBundleIdentifier:presentationSourceRect:
//   -sc_openSplitForBundleIdentifier:
// 只认这一个类和这一族 selector，不做候选类遍历，也不碰 sc_route... 那条路由。
static id ADScreenCoreManager(void) {
    Class managerClass = NSClassFromString(@"SCFloatingSceneManager");
    if (!managerClass) {
        return nil;
    }

    SEL selector = NSSelectorFromString(@"sc_sharedManager");
    if (![managerClass respondsToSelector:selector]) {
        return nil;
    }

    id manager = nil;
    @try {
        manager = ((id (*)(id, SEL))objc_msgSend)(managerClass, selector);
    } @catch (__unused NSException *exception) {
        return nil;
    }
    return manager;
}

static BOOL ADInvokeOpenSplit(id manager, NSString *bundleIdentifier, CGRect rect) {
    BOOL withRect = !CGRectIsEmpty(rect);
    NSString *selectorName = withRect ? @"sc_openSplitForBundleIdentifier:presentationSourceRect:"
                                     : @"sc_openSplitForBundleIdentifier:";
    SEL selector = NSSelectorFromString(selectorName);

    if (![manager respondsToSelector:selector]) {
        return NO;
    }

    NSMethodSignature *signature = [manager methodSignatureForSelector:selector];
    if (!signature) {
        return NO;
    }
    if (!ADArgumentIsObject(signature, 2)) {
        return NO;
    }
    if (withRect && !ADArgumentIsRect(signature, 3)) {
        return NO;
    }

    BOOL accepted = NO;
    @try {
        NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
        invocation.target = manager;
        invocation.selector = selector;
        ADSetObjectArgument(invocation, 2, bundleIdentifier);
        if (withRect) {
            ADSetRectArgument(invocation, 3, rect);
        }
        [invocation invoke];

        const char *returnType = signature.methodReturnType;
        if (returnType[0] == 'v') {
            accepted = YES;
        } else if (returnType[0] == 'B' || returnType[0] == 'c') {
            BOOL result = NO;
            [invocation getReturnValue:&result];
            accepted = result;
        } else {
            accepted = YES;
        }
    } @catch (__unused NSException *exception) {
        return NO;
    }
    return accepted;
}

// 浮窗展开动画的起点矩形，取屏幕中下部一小块。
static CGRect ADSourceRect(void) {
    CGRect screenBounds = [UIScreen mainScreen].bounds;
    CGFloat width = CGRectGetWidth(screenBounds);
    CGFloat height = CGRectGetHeight(screenBounds);
    CGFloat side = 88.0;
    return CGRectMake(floor((width - side) / 2.0),
                      floor(height * 0.30),
                      side,
                      side);
}

// ScreenCore 建场景只能在主线程做，且必须给足一个 runloop 间隔，
// 不能和面板收起动画挤在同一帧。
static BOOL ADTryScreenCoreFloating(NSString *bundleIdentifier) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
          ADTryScreenCoreFloating(bundleIdentifier);
        });
        return YES;
    }

    id manager = ADScreenCoreManager();
    if (!manager) {
        return NO;
    }

    if (ADInvokeOpenSplit(manager, bundleIdentifier, ADSourceRect())) {
        return YES;
    }
    // 带 rect 的版本不被接受时，退回不带 rect 的那条。
    return ADInvokeOpenSplit(manager, bundleIdentifier, CGRectZero);
}

#pragma mark - LaunchServices（仅作显式选择的备用路径）

static id ADDefaultWorkspace(void) {
    Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    if (!workspaceClass) {
        return nil;
    }
    SEL selector = NSSelectorFromString(@"defaultWorkspace");
    if (![workspaceClass respondsToSelector:selector]) {
        return nil;
    }
    return ((id (*)(id, SEL))objc_msgSend)(workspaceClass, selector);
}

static BOOL ADTryLaunchServices(NSString *bundleIdentifier) {
    id workspace = ADDefaultWorkspace();
    if (!workspace) {
        return NO;
    }

    // openApplicationWithBundleID: 会落到 ScreenCore 的 FBSystemService 链路，
    // 那条链路在 SpringBoard 内要同步等结果，容易把主线程按死。
    SEL selector = NSSelectorFromString(@"openApplicationWithBundleID:");
    if (![workspace respondsToSelector:selector]) {
        return NO;
    }

    @try {
        Method method = class_getInstanceMethod(object_getClass(workspace), selector);
        const char *encoding = method ? method_getTypeEncoding(method) : NULL;
        if (encoding && (encoding[0] == 'B' || encoding[0] == 'c')) {
            ((BOOL (*)(id, SEL, id))objc_msgSend)(workspace, selector, bundleIdentifier);
        } else {
            ((void (*)(id, SEL, id))objc_msgSend)(workspace, selector, bundleIdentifier);
        }
    } @catch (__unused NSException *exception) {
        return NO;
    }
    return YES;
}

#pragma mark - 入口

BOOL ADOpenApplication(NSString *bundleIdentifier) {
    if (bundleIdentifier.length == 0) {
        return NO;
    }

    if (ADPrefLauncherMode() == ADLauncherModeScreenCore) {
        // 与 QuickLaunch 一致：只走 ScreenCore 自己的浮窗接口，失败就什么都不做。
        // 不回落到 LaunchServices，避免同一个 App 被开两次、以及同步链路按死主线程。
        return ADTryScreenCoreFloating(bundleIdentifier);
    }

    return ADTryLaunchServices(bundleIdentifier);
}
