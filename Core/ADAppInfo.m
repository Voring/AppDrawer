#import "ADAppInfo.h"

#import <objc/message.h>

static NSCache<NSString *, UIImage *> *ADIconCache(void) {
    static NSCache *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
      cache = [[NSCache alloc] init];
      cache.countLimit = 512;
    });
    return cache;
}

static NSString *ADSearchKey(NSString *name, NSString *bundleIdentifier) {
    NSMutableString *latin = [name mutableCopy];
    if (latin.length) {
        CFStringTransform((__bridge CFMutableStringRef)latin, NULL,
                          kCFStringTransformMandarinLatin, false);
        CFStringTransform((__bridge CFMutableStringRef)latin, NULL,
                          kCFStringTransformStripDiacritics, false);
    }
    NSString *pinyin = [latin lowercaseString];

    NSMutableString *initials = [NSMutableString string];
    for (NSString *part in [pinyin componentsSeparatedByCharactersInSet:
                                   [NSCharacterSet whitespaceAndNewlineCharacterSet]]) {
        if (part.length) {
            [initials appendString:[part substringToIndex:1]];
        }
    }

    NSString *compactPinyin = [pinyin stringByReplacingOccurrencesOfString:@" " withString:@""];

    return [[NSString stringWithFormat:@"%@ %@ %@ %@ %@",
                                       name, pinyin, initials, compactPinyin, bundleIdentifier]
        lowercaseString];
}

@implementation ADAppInfo

- (instancetype)initWithProxy:(id)proxy
             bundleIdentifier:(NSString *)bundleIdentifier
                  displayName:(NSString *)displayName {
    self = [super init];
    if (self) {
        _applicationProxy = proxy;
        _bundleIdentifier = [bundleIdentifier copy];
        _displayName = [displayName copy];
        _searchKey = ADSearchKey(displayName ?: bundleIdentifier, bundleIdentifier);
    }
    return self;
}

- (UIImage *)_loadIconFromProxy {
    id proxy = self.applicationProxy;
    if (!proxy) {
        return nil;
    }

    NSData *data = nil;
    SEL dataSelector = NSSelectorFromString(@"iconDataForVariant:");
    if ([proxy respondsToSelector:dataSelector]) {
        typedef NSData *(*IconDataFunction)(id, SEL, unsigned int);
        IconDataFunction function = (IconDataFunction)[proxy methodForSelector:dataSelector];
        @try {
            for (unsigned int variant = 2; variant <= 3 && !data; variant++) {
                data = function(proxy, dataSelector, variant);
            }
        } @catch (__unused NSException *exception) {
            data = nil;
        }
    }

    if (data.length) {
        UIImage *image = [UIImage imageWithData:data];
        if (image) {
            return image;
        }
    }

    // SpringBoard 内可用的兜底私有方法
    SEL fallbackSelector = NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:format:scale:");
    if ([[UIImage class] respondsToSelector:fallbackSelector]) {
        typedef UIImage *(*IconFunction)(id, SEL, NSString *, int, double);
        IconFunction function = (IconFunction)[[UIImage class] methodForSelector:fallbackSelector];
        @try {
            return function([UIImage class], fallbackSelector, self.bundleIdentifier, 2, 0.0);
        } @catch (__unused NSException *exception) {
            return nil;
        }
    }
    return nil;
}

- (UIImage *)iconImage {
    UIImage *cached = [ADIconCache() objectForKey:self.bundleIdentifier];
    if (cached) {
        return cached;
    }

    UIImage *image = [self _loadIconFromProxy];
    if (image) {
        [ADIconCache() setObject:image forKey:self.bundleIdentifier];
    }
    return image;
}

@end
