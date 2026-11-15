#import "ADURLDispatchHooks.h"

#import <CaptainHook/CaptainHook.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#import "../Shared/URLScheme/ADURLScheme.h"
#import "ADPanelController.h"

CHDeclareClass(SpringBoard);
CHDeclareClass(FBSystemService);
CHDeclareClass(LSApplicationWorkspace);

#pragma mark - 统一处理

static BOOL ADHandleURLIfMine(NSURL *URL) {
    if (!ADURLIsAppDrawerURL(URL)) {
        return NO;
    }
    // 不在 LaunchServices / 启动流程的调用栈里直接铺 UI，推到下一个主线程轮次。
    dispatch_async(dispatch_get_main_queue(), ^{
      [[ADPanelController sharedController] handleURL:URL];
    });
    return YES;
}

#pragma mark - SpringBoard URL 分发放型

CHOptimizedMethod2(self, BOOL, SpringBoard, application, UIApplication *, application, handleOpenURL, NSURL *, url) {
    if (ADHandleURLIfMine(url)) {
        return YES;
    }
    return CHSuper2(SpringBoard, application, application, handleOpenURL, url);
}

CHOptimizedMethod3(self, BOOL, SpringBoard, application, UIApplication *, application, openURL, NSURL *, url,
                   options, id, options) {
    if (ADHandleURLIfMine(url)) {
        return YES;
    }
    return CHSuper3(SpringBoard, application, application, openURL, url, options, options);
}

CHOptimizedMethod4(self, BOOL, SpringBoard, application, UIApplication *, application, openURL, NSURL *, url,
                   sourceApplication, id, source, annotation, id, annotation) {
    if (ADHandleURLIfMine(url)) {
        return YES;
    }
    return CHSuper4(SpringBoard, application, application, openURL, url, sourceApplication, source,
                    annotation, annotation);
}

CHOptimizedMethod1(self, BOOL, SpringBoard, applicationOpenURL, NSURL *, url) {
    if (ADHandleURLIfMine(url)) {
        return YES;
    }
    return CHSuper1(SpringBoard, applicationOpenURL, url);
}

CHOptimizedMethod2(self, BOOL, SpringBoard, applicationOpenURL, NSURL *, url, publicURLsOnly, BOOL, only) {
    if (ADHandleURLIfMine(url)) {
        return YES;
    }
    return CHSuper2(SpringBoard, applicationOpenURL, url, publicURLsOnly, only);
}

CHOptimizedMethod8(self, BOOL, SpringBoard, applicationOpenURL, NSURL *, url, withApplication, id, application,
                   sender, id, sender, publicURLsOnly, BOOL, only, animating, BOOL, animating,
                   needsConfirm, BOOL, confirm, options, id, options, windowContext, id, context) {
    if (ADHandleURLIfMine(url)) {
        return YES;
    }
    return CHSuper8(SpringBoard, applicationOpenURL, url, withApplication, application, sender, sender,
                    publicURLsOnly, only, animating, animating, needsConfirm, confirm, options, options,
                    windowContext, context);
}

#pragma mark - 快捷指令带 URL 的启动请求

CHOptimizedMethod5(self, void, FBSystemService, openApplication, id, application, withOptions, id, options,
                   originator, id, originator, requestID, unsigned int, requestID, completion, id, completion) {
    NSURL *URL = nil;
    @try {
        if ([options respondsToSelector:@selector(url)]) {
            id value = [options performSelector:@selector(url)];
            if ([value isKindOfClass:[NSURL class]]) {
                URL = value;
            }
        }
    } @catch (__unused NSException *exception) {
        URL = nil;
    }

    if (URL && ADHandleURLIfMine(URL)) {
        if (completion) {
            ((void (^)(id, id))completion)(nil, nil);
        }
        return;
    }

    CHSuper5(FBSystemService, openApplication, application, withOptions, options, originator, originator,
             requestID, requestID, completion, completion);
}

#pragma mark - LaunchServices 兜底

CHOptimizedMethod2(self, BOOL, LSApplicationWorkspace, openURL, NSURL *, URL, withOptions, id, options) {
    if (ADHandleURLIfMine(URL)) {
        return YES;
    }
    return CHSuper2(LSApplicationWorkspace, openURL, URL, withOptions, options);
}

CHOptimizedMethod2(self, BOOL, LSApplicationWorkspace, openSensitiveURL, NSURL *, URL, withOptions, id, options) {
    if (ADHandleURLIfMine(URL)) {
        return YES;
    }
    return CHSuper2(LSApplicationWorkspace, openSensitiveURL, URL, withOptions, options);
}

#pragma mark - 安装

void ADInstallURLDispatchHooks(void) {
    @autoreleasepool {
        Class boardClass = NSClassFromString(@"SpringBoard");
        if (boardClass) {
            CHLoadClass_(&SpringBoard$, boardClass);
            if ([boardClass instancesRespondToSelector:@selector(application:handleOpenURL:)]) {
                CHHook2(SpringBoard, application, handleOpenURL);
            }
            if ([boardClass instancesRespondToSelector:@selector(application:openURL:options:)]) {
                CHHook3(SpringBoard, application, openURL, options);
            }
            if ([boardClass instancesRespondToSelector:@selector(application:openURL:sourceApplication:annotation:)]) {
                CHHook4(SpringBoard, application, openURL, sourceApplication, annotation);
            }
            if ([boardClass instancesRespondToSelector:@selector(applicationOpenURL:)]) {
                CHHook1(SpringBoard, applicationOpenURL);
            }
            if ([boardClass instancesRespondToSelector:@selector(applicationOpenURL:publicURLsOnly:)]) {
                CHHook2(SpringBoard, applicationOpenURL, publicURLsOnly);
            }
            if ([boardClass
                    instancesRespondToSelector:@selector(applicationOpenURL:
                                                                 withApplication:
                                                                        sender:
                                                                publicURLsOnly:
                                                                     animating:
                                                                  needsConfirm:
                                                                       options:
                                                                 windowContext:)]) {
                CHHook8(SpringBoard, applicationOpenURL, withApplication, sender, publicURLsOnly,
                        animating, needsConfirm, options, windowContext);
            }
        }

        Class serviceClass = NSClassFromString(@"FBSystemService");
        if (serviceClass) {
            CHLoadClass_(&FBSystemService$, serviceClass);
            Method openMethod = class_getInstanceMethod(
                serviceClass, @selector(openApplication:withOptions:originator:requestID:completion:));
            if (openMethod && method_getNumberOfArguments(openMethod) == 7) {
                CHHook5(FBSystemService, openApplication, withOptions, originator, requestID, completion);
            }
        }

        Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
        if (workspaceClass) {
            CHLoadClass_(&LSApplicationWorkspace$, workspaceClass);
            if ([workspaceClass instancesRespondToSelector:@selector(openURL:withOptions:)]) {
                CHHook2(LSApplicationWorkspace, openURL, withOptions);
            }
            if ([workspaceClass instancesRespondToSelector:@selector(openSensitiveURL:withOptions:)]) {
                CHHook2(LSApplicationWorkspace, openSensitiveURL, withOptions);
            }
        }
    }
}
