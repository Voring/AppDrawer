#import "ADAppInfo.h"

#import <objc/message.h>

// 图标按「像素面积最大」挑选：LS 的 variant 编号在不同系统上含义并不固定，
// 逐个试再取最大的一张，才能保证 62pt 的格子拿到足够分辨率、不糊。
static const unsigned int kADIconMaxVariant = 4;
static const NSUInteger kADIconGoodEnoughArea = 150 * 150;

static NSCache<NSString *, UIImage *> *ADIconCache(void) {
    static NSCache *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
      cache = [[NSCache alloc] init];
      cache.countLimit = 512;
    });
    return cache;
}

static NSString *ADSearchKey(NSString *name) {
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

    // 只拼「名称 / 全拼 / 首字母 / 去空格全拼」四段，不再拼 bundle id。
    // 段之间用换行分隔：匹配时各段单独规范化、单独判断包含，
    // 避免删空格后首尾字母跨段粘连，拼出原文并不存在的子串（如 qsq + qingsongqian → qq）。
    return [[NSString stringWithFormat:@"%@\n%@\n%@\n%@",
                                       name, pinyin, initials, compactPinyin]
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
        _searchKey = ADSearchKey(displayName ?: bundleIdentifier);
    }
    return self;
}

#pragma mark - 图标加载

// 同样一张图，用像素尺寸而不是 UI 尺寸比较，避免 @2x/@3x 干扰。
static NSUInteger ADImagePixelArea(UIImage *image) {
    if (!image.CGImage) {
        return 0;
    }
    return CGImageGetWidth(image.CGImage) * CGImageGetHeight(image.CGImage);
}

- (UIImage *)_largestIconFromProxy {
    id proxy = self.applicationProxy;
    if (!proxy) {
        return nil;
    }

    SEL dataSelector = NSSelectorFromString(@"iconDataForVariant:");
    if (![proxy respondsToSelector:dataSelector]) {
        return nil;
    }

    typedef NSData *(*IconDataFunction)(id, SEL, unsigned int);
    IconDataFunction function = (IconDataFunction)[proxy methodForSelector:dataSelector];

    UIImage *largest = nil;
    NSUInteger largestArea = 0;
    for (unsigned int variant = 0; variant <= kADIconMaxVariant; variant++) {
        NSData *data = nil;
        @try {
            data = function(proxy, dataSelector, variant);
        } @catch (__unused NSException *exception) {
            data = nil;
        }
        if (data.length == 0) {
            continue;
        }
        UIImage *image = [UIImage imageWithData:data];
        NSUInteger area = ADImagePixelArea(image);
        if (area > largestArea) {
            largestArea = area;
            largest = image;
        }
        if (largestArea >= kADIconGoodEnoughArea) {
            break;
        }
    }
    return largest;
}

- (UIImage *)_iconFromSpringBoardAPI {
    SEL selector = NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:format:scale:");
    if (![[UIImage class] respondsToSelector:selector]) {
        return nil;
    }

    typedef UIImage *(*IconFunction)(id, SEL, NSString *, int, double);
    IconFunction function = (IconFunction)[[UIImage class] methodForSelector:selector];

    // scale 传真实屏幕倍数（3.0）而不是 0.0，才會拿 180px 的 @3x 图。
    CGFloat scale = [UIScreen mainScreen].scale;
    if (scale < 2.0) {
        scale = 3.0;
    }

    @try {
        UIImage *image = function([UIImage class], selector, self.bundleIdentifier, 2, scale);
        if (image) {
            return image;
        }
        return function([UIImage class], selector, self.bundleIdentifier, 0, scale);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

- (UIImage *)_loadIcon {
    UIImage *image = [self _largestIconFromProxy];
    if (ADImagePixelArea(image) >= kADIconGoodEnoughArea) {
        return image;
    }
    // LS 给的图不够大，退到 SpringBoard 自己的图标渲染接口。
    UIImage *springBoardImage = [self _iconFromSpringBoardAPI];
    if (ADImagePixelArea(springBoardImage) > ADImagePixelArea(image)) {
        return springBoardImage;
    }
    return image;
}

- (UIImage *)cachedIconImage {
    return [ADIconCache() objectForKey:self.bundleIdentifier];
}

- (UIImage *)iconImage {
    UIImage *cached = [self cachedIconImage];
    if (cached) {
        return cached;
    }

    UIImage *image = [self _loadIcon];
    if (image) {
        [ADIconCache() setObject:image forKey:self.bundleIdentifier];
    }
    return image;
}

+ (void)preloadIconsForApplications:(NSArray<ADAppInfo *> *)applications {
    if (applications.count == 0) {
        return;
    }
    // 低优先级串行队列：不跟 SpringBoard 抢 CPU，也不会把主线程顶住。
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
      queue = dispatch_queue_create("com.voring.appdrawer.iconpreload",
                                    dispatch_queue_attr_make_with_qos_class(
                                        DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
    });

    NSArray<ADAppInfo *> *snapshot = [applications copy];
    dispatch_async(queue, ^{
      @autoreleasepool {
        for (ADAppInfo *application in snapshot) {
            if ([ADIconCache() objectForKey:application.bundleIdentifier]) {
                continue;
            }
            (void)[application iconImage];
        }
      }
    });
}

@end
