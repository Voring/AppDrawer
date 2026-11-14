#import "ADLauncher.h"

#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>

#import "ADPrefs.h"

#pragma mark - 通用单参数调用（按真实返回类型派发，避免 void/BOOL 误判）

static BOOL ADInvokeSingleObjectMethod(id target, SEL selector, id argument) {
    if (!target || ![target respondsToSelector:selector]) {
        return NO;
    }

    Method method = class_getInstanceMethod(object_getClass(target), selector);
    const char *encoding = method ? method_getTypeEncoding(method) : NULL;
    if (!encoding) {
        return NO;
    }

    switch (encoding[0]) {
        case 'v':
            ((void (*)(id, SEL, id))objc_msgSend)(target, selector, argument);
            return YES;
        case 'B':
        case 'c':
            return ((BOOL (*)(id, SEL, id))objc_msgSend)(target, selector, argument);
        default:
            ((id (*)(id, SEL, id))objc_msgSend)(target, selector, argument);
            return YES;
    }
}

#pragma mark - ScreenCore 直连浮窗

static id ADSharedInstanceOfClass(Class cls) {
    static NSArray<NSString *> *sharedSelectors;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
      sharedSelectors = @[ @"sharedInstance", @"sharedManager", @"sc_sharedManager", @"defaultInstance" ];
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

static BOOL ADTryScreenCoreFloating(NSString *bundleIdentifier) {
    static NSArray<NSString *> *classNames;
    static NSArray<NSString *> *openSelectors;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
      classNames = @[
          @"SBIconController",
          @"SCFloatingSceneManager",
          @"SCExternalLinkCoordinator",
          @"SBApplicationController"
      ];
      openSelectors = @[
          @"sc_openSplitForBundleIdentifier:",
          @"sc_openTargetIdentifier:"
      ];
    });

    for (NSString *className in classNames) {
        Class cls = NSClassFromString(className);
        if (!cls) {
            continue;
        }

        id target = ADSharedInstanceOfClass(cls);
        if (!target) {
            continue;
        }

        for (NSString *selectorName in openSelectors) {
            SEL selector = NSSelectorFromString(selectorName);
            if ([target respondsToSelector:selector]) {
                ADInvokeSingleObjectMethod(target, selector, bundleIdentifier);
                return YES;
            }
        }
    }
    return NO;
}

#pragma mark - LaunchServices

static BOOL ADTryLaunchServices(NSString *bundleIdentifier) {
    Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    if (!workspaceClass) {
        return NO;
    }

    SEL defaultSelector = NSSelectorFromString(@"defaultWorkspace");
    if (![workspaceClass respondsToSelector:defaultSelector]) {
        return NO;
    }
    id workspace = ((id (*)(id, SEL))objc_msgSend)(workspaceClass, defaultSelector);
    if (!workspace) {
        return NO;
    }

    if ([workspace respondsToSelector:NSSelectorFromString(@"openApplicationWithBundleIdentifier:")]) {
        return ADInvokeSingleObjectMethod(workspace,
                                          NSSelectorFromString(@"openApplicationWithBundleIdentifier:"),
                                          bundleIdentifier);
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
          launchFunction = (LaunchFunction)dlsym(RTLD_DEFAULT, "SBSLaunchApplicationWithIdentifier");
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

    if (ADPrefForceScreenCoreFloating()) {
        if (ADTryScreenCoreFloating(bundleIdentifier)) {
            return YES;
        }
        return ADTryLaunchServices(bundleIdentifier) || ADTrySpringBoardServices(bundleIdentifier);
    }

    if (ADTryLaunchServices(bundleIdentifier)) {
        return YES;
    }
    if (ADTryScreenCoreFloating(bundleIdentifier)) {
        return YES;
    }
    return ADTrySpringBoardServices(bundleIdentifier);
}
