#import "ADLauncher.h"

#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <UIKit/UIKit.h>

#pragma mark - NSInvocation 参数填充（按真实类型，避免把 BOOL 当 void 或把结构体当指针）

static void ADSetObjectArgument(NSInvocation *invocation, NSUInteger index, id object) {
    id value = object;
    [invocation setArgument:&value atIndex:(NSInteger)index];
}

static void ADSetRectArgument(NSInvocation *invocation, NSUInteger index, CGRect rect) {
    CGRect value = rect;
    [invocation setArgument:&value atIndex:(NSInteger)index];
}

static void ADSetIntegerArgument(NSInvocation *invocation,
                                NSUInteger index,
                                NSMethodSignature *signature,
                                unsigned long long value) {
    const char *type = [signature getArgumentTypeAtIndex:index];
    switch (type[0]) {
        case 'Q': {
            unsigned long long v = value;
            [invocation setArgument:&v atIndex:(NSInteger)index];
            break;
        }
        case 'q': {
            long long v = (long long)value;
            [invocation setArgument:&v atIndex:(NSInteger)index];
            break;
        }
        case 'I': {
            unsigned int v = (unsigned int)value;
            [invocation setArgument:&v atIndex:(NSInteger)index];
            break;
        }
        case 'i': {
            int v = (int)value;
            [invocation setArgument:&v atIndex:(NSInteger)index];
            break;
        }
        case 'B': {
            BOOL v = value ? YES : NO;
            [invocation setArgument:&v atIndex:(NSInteger)index];
            break;
        }
        case 'c': {
            char v = value ? 1 : 0;
            [invocation setArgument:&v atIndex:(NSInteger)index];
            break;
        }
        default:
            break;
    }
}

// 返回 YES 表示方法确实被调用；返回类型为 BOOL 时取真实返回值。
static BOOL ADInvokeAndReadResult(NSInvocation *invocation, NSMethodSignature *signature) {
    [invocation invoke];

    const char *returnType = signature.methodReturnType;
    if (returnType[0] == 'v') {
        return YES;
    }
    if (returnType[0] == 'B' || returnType[0] == 'c') {
        BOOL result = NO;
        [invocation getReturnValue:&result];
        return result;
    }
    return YES;
}

#pragma mark - ScreenCore 共享实例

static id ADSharedInstanceForClass(Class cls) {
    static NSArray<NSString *> *sharedSelectors;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
      sharedSelectors = @[
          @"sc_sharedCoordinator",
          @"sc_sharedManager",
          @"sc_sharedController",
          @"sc_sharedDriver",
          @"sharedInstance",
          @"sharedManager",
          @"defaultManager"
      ];
    });

    for (NSString *selectorName in sharedSelectors) {
        SEL selector = NSSelectorFromString(selectorName);
        if (![cls respondsToSelector:selector]) {
            continue;
        }
        id instance = ((id (*)(id, SEL))objc_msgSend)(cls, selector);
        if (instance) {
            return instance;
        }
    }
    return nil;
}

static NSArray<NSString *> *ADSCCandidateClassNames(void) {
    static NSArray<NSString *> *classNames;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
      classNames = @[
          @"SCExternalLinkCoordinator",
          @"SCFloatingSceneManager",
          @"SCFloatingDockManager",
          @"SBIconController"
      ];
    });
    return classNames;
}

static CGRect ADSourceRect(void) {
    CGRect screenBounds = [UIScreen mainScreen].bounds;
    CGFloat width = CGRectGetWidth(screenBounds);
    CGFloat height = CGRectGetHeight(screenBounds);
    CGFloat side = 96.0;
    return CGRectMake(floor((width - side) / 2.0), floor(height * 0.28), side, side);
}

#pragma mark - ScreenCore 调用

static BOOL ADTryOpenSplit(id target, NSString *bundleIdentifier, CGRect rect, BOOL withRect) {
    NSString *selectorName = withRect ? @"sc_openSplitForBundleIdentifier:presentationSourceRect:"
                                     : @"sc_openSplitForBundleIdentifier:";
    SEL selector = NSSelectorFromString(selectorName);
    if (![target respondsToSelector:selector]) {
        return NO;
    }

    NSMethodSignature *signature = [target methodSignatureForSelector:selector];
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    invocation.target = target;
    invocation.selector = selector;

    ADSetObjectArgument(invocation, 2, bundleIdentifier);
    if (withRect) {
        ADSetRectArgument(invocation, 3, rect);
    }
    return ADInvokeAndReadResult(invocation, signature);
}

static BOOL ADTryRouteApplicationRequest(id target, NSString *bundleIdentifier) {
    SEL selector = NSSelectorFromString(@"sc_routeApplicationRequestForBundleIdentifier:options:origin:forward:");
    if (![target respondsToSelector:selector]) {
        return NO;
    }

    NSMethodSignature *signature = [target methodSignatureForSelector:selector];
    if (signature.numberOfArguments < 6) {
        return NO;
    }

    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    invocation.target = target;
    invocation.selector = selector;

    ADSetObjectArgument(invocation, 2, bundleIdentifier);
    ADSetObjectArgument(invocation, 3, @{});
    ADSetIntegerArgument(invocation, 4, signature, 0);
    ADSetIntegerArgument(invocation, 5, signature, 1);
    return ADInvokeAndReadResult(invocation, signature);
}

static BOOL ADTryScreenCoreFloating(NSString *bundleIdentifier) {
    CGRect sourceRect = ADSourceRect();

    for (NSString *className in ADSCCandidateClassNames()) {
        Class cls = NSClassFromString(className);
        if (!cls) {
            continue;
        }
        id instance = ADSharedInstanceForClass(cls);
        if (!instance) {
            continue;
        }

        if (ADTryOpenSplit(instance, bundleIdentifier, sourceRect, YES)) {
            return YES;
        }
        if (ADTryOpenSplit(instance, bundleIdentifier, CGRectZero, NO)) {
            return YES;
        }
        if (ADTryRouteApplicationRequest(instance, bundleIdentifier)) {
            return YES;
        }
    }
    return NO;
}

#pragma mark - LaunchServices

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

// 注意：ScreenCore 钩的是 openApplicationWithBundleID:（没有 ...Identifier 后缀）。
static BOOL ADTryLaunchServices(NSString *bundleIdentifier) {
    id workspace = ADDefaultWorkspace();
    if (!workspace) {
        return NO;
    }

    NSArray<NSString *> *selectors = @[
        @"openApplicationWithBundleID:",
        @"openApplicationWithBundleIdentifier:"
    ];
    for (NSString *selectorName in selectors) {
        SEL selector = NSSelectorFromString(selectorName);
        if (![workspace respondsToSelector:selector]) {
            continue;
        }
        Method method = class_getInstanceMethod(object_getClass(workspace), selector);
        const char *encoding = method ? method_getTypeEncoding(method) : NULL;
        if (encoding && (encoding[0] == 'B' || encoding[0] == 'c')) {
            ((BOOL (*)(id, SEL, id))objc_msgSend)(workspace, selector, bundleIdentifier);
        } else {
            ((void (*)(id, SEL, id))objc_msgSend)(workspace, selector, bundleIdentifier);
        }
        return YES;
    }

    SEL modernSelector = NSSelectorFromString(
        @"openApplicationWithBundleIdentifier:configuration:completionHandler:");
    if ([workspace respondsToSelector:modernSelector]) {
        ((void (*)(id, SEL, id, id, id))objc_msgSend)(workspace, modernSelector, bundleIdentifier, nil, nil);
        return YES;
    }

    return NO;
}

#pragma mark - SpringBoardServices（最后兜底）

static BOOL ADTrySpringBoardServices(NSString *bundleIdentifier) {
    typedef int (*LaunchFunction)(CFStringRef, BOOL);

    static LaunchFunction launchFunction;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
      void *handle = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices",
                            RTLD_LAZY);
      if (handle) {
          launchFunction = (LaunchFunction)dlsym(handle, "SBSLaunchApplicationWithIdentifier");
      }
      if (!launchFunction) {
          launchFunction = (LaunchFunction)dlsym(RLTD_DEFAULT, "SBSLaunchApplicationWithIdentifier");
      }
    });

    if (!launchFunction) {
        return NO;
    }
    return launchFunction((__bridge CFStringRef)bundleIdentifier, NO) == 0;
}

#pragma mark - 入口

BOOL ADOpenApplication(NSString *bundleIdentifier) {
    if (bundleIdentifier.length == 0) {
        return NO;
    }

    if (ADTryScreenCoreFloating(bundleIdentifier)) {
        // 只发一次请求：ScreenCore 建浮窗场景本身很重。
        return YES;
    }

    if (ADTryLaunchServices(bundleIdentifier)) {
        return YES;
    }
    return ADTrySpringBoardServices(bundleIdentifier);
}
