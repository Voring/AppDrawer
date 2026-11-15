#import "ADAppCatalog.h"

#import <objc/message.h>

#import "ADAppInfo.h"
#import "ADPrefs.h"

static NSArray<ADAppInfo *> *ADCachedApplications = nil;

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

static NSString *ADStringValue(id object, NSString *selectorName) {
    SEL selector = NSSelectorFromString(selectorName);
    if (!object || ![object respondsToSelector:selector]) {
        return nil;
    }
    id value = ((id (*)(id, SEL))objc_msgSend)(object, selector);
    return [value isKindOfClass:[NSString class]] ? value : nil;
}

static BOOL ADProxyIsHidden(id proxy) {
    NSArray *tags = nil;
    SEL selector = NSSelectorFromString(@"appTags");
    if ([proxy respondsToSelector:selector]) {
        id value = ((id (*)(id, SEL))objc_msgSend)(proxy, selector);
        if ([value isKindOfClass:[NSArray class]]) {
            tags = value;
        }
    }
    if (!tags) {
        // KVC 取未声明的 key 会抛，只有这一句需要兜底。
        @try {
            id value = [proxy valueForKey:@"tags"];
            if ([value isKindOfClass:[NSArray class]]) {
                tags = value;
            }
        } @catch (__unused NSException *exception) {
            tags = nil;
        }
    }

    for (NSString *tag in tags) {
        if (![tag isKindOfClass:[NSString class]]) {
            continue;
        }
        if ([tag isEqualToString:@"hidden"] || [tag isEqualToString:@"internal"] ||
            [tag isEqualToString:@"hidden-from-ui"]) {
            return YES;
        }
    }
    return NO;
}

@implementation ADAppCatalog

+ (NSArray<ADAppInfo *> *)cachedApplications {
    @synchronized(self) {
        return ADCachedApplications;
    }
}

+ (NSArray<ADAppInfo *> *)_enumerateApplications {
    NSMutableArray<ADAppInfo *> *applications = [NSMutableArray array];

    id workspace = ADDefaultWorkspace();
    SEL allSelector = NSSelectorFromString(@"allInstalledApplications");
    if (!workspace || ![workspace respondsToSelector:allSelector]) {
        return applications;
    }

    NSArray *proxies = nil;
    @try {
        proxies = ((id (*)(id, SEL))objc_msgSend)(workspace, allSelector);
    } @catch (__unused NSException *exception) {
        proxies = nil;
    }
    if (![proxies isKindOfClass:[NSArray class]]) {
        return applications;
    }

    BOOL showSystemApps = ADPrefShowSystemApps();
    NSMutableSet<NSString *> *seen = [NSMutableSet set];

    for (id proxy in proxies) {
        @autoreleasepool {
            NSString *bundleIdentifier = ADStringValue(proxy, @"bundleIdentifier");
            if (bundleIdentifier.length == 0) {
                continue;
            }
            if ([bundleIdentifier isEqualToString:@"com.voring.appdrawer.urlhandler"]) {
                continue;
            }
            if ([seen containsObject:bundleIdentifier]) {
                continue;
            }
            if (ADProxyIsHidden(proxy)) {
                continue;
            }

            NSString *type = ADStringValue(proxy, @"applicationType");
            // 取不到 applicationType 时兜底：系统 App 按 bundle id 前缀区分。
            BOOL included = type.length > 0
                                ? ([type isEqualToString:@"User"] ||
                                   (showSystemApps && [type isEqualToString:@"System"]))
                                : (showSystemApps || ![bundleIdentifier hasPrefix:@"com.apple."]);
            if (!included) {
                continue;
            }

            NSString *displayName = ADStringValue(proxy, @"localizedName");
            if (displayName.length == 0) {
                displayName = ADStringValue(proxy, @"itemName");
            }
            if (displayName.length == 0) {
                displayName = bundleIdentifier;
            }

            [seen addObject:bundleIdentifier];
            ADAppInfo *application = [[ADAppInfo alloc] initWithProxy:proxy
                                                     bundleIdentifier:bundleIdentifier
                                                          displayName:displayName];
            [applications addObject:application];
        }
    }

    [applications sortUsingComparator:^(ADAppInfo *lhs, ADAppInfo *rhs) {
      return [lhs.displayName localizedStandardCompare:rhs.displayName];
    }];

    return applications;
}

+ (NSArray<ADAppInfo *> *)loadApplications {
    NSArray<ADAppInfo *> *applications = [self _enumerateApplications];
    @synchronized(self) {
        if (applications.count > 0) {
            ADCachedApplications = applications;
        }
    }
    // 列表到手后立刻在后台预热图标：面板唤出时 cell 直接命中缓存，
    // 不会先画占位图再跳真图标（那正是「闪一下」的一部分）。
    [ADAppInfo preloadIconsForApplications:applications];
    return applications;
}

+ (void)reloadInBackgroundWithCompletion:(void (^)(NSArray<ADAppInfo *> *))completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      NSArray<ADAppInfo *> *applications = [self loadApplications];
      dispatch_async(dispatch_get_main_queue(), ^{
        if (completion) {
            completion(applications);
        }
      });
    });
}

@end
