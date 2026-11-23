#import "ADAppInfo.h"

#import <objc/message.h>

// 图标按「像素面积最大」挑选：LS 的 variant 编号在不同系统上含义并不固定，
// 逐个试再取最大的一张，才能保证 62pt 的格子拿到足够分辨率、不糊。
// +[UIScreen mainScreen] 只能在主线程访问：这里存一份主线程写好的倍数，后台只读。
static CGFloat ADScreenScale = 3.0;

void ADCacheScreenScale(void) {
    if (![NSThread isMainThread]) {
        return;
    }
    CGFloat scale = 0.0;
    @try {
        scale = [UIScreen mainScreen].scale;
    } @catch (__unused NSException *exception) {
        scale = 0.0;
    }
    if (scale >= 1.0) {
        ADScreenScale = scale;
    }
}

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
    CGFloat scale = ADScreenScale;
    NSString *bundleIdentifier = self.bundleIdentifier;

    __block UIImage *result = nil;
    void (^fetch)(void) = ^{
        @try {
            UIImage *image = function([UIImage class], selector, bundleIdentifier, 2, scale);
            if (!image) {
                image = function([UIImage class], selector, bundleIdentifier, 0, scale);
            }
            result = image;
        } @catch (__unused NSException *exception) {
            result = nil;
        }
    };

    // 这个接口内部会在 dispatch_once 里调 +[UIScreen mainScreen]（带主线程断言），
    // 在 iconpreload 后台队列上直接调必然抛异常、abort 把 SpringBoard 打成安全模式
    //（崩溃栈：iconpreload → _applicationIconImageForBundleIdentifier:format:scale:
    //  → _iconVariantForUIApplicationIconFormat:idiom:scale: → +[UIScreen mainScreen]）。
    // 所以一律回主线程执行；主线程 3 秒内没回话就放弃这张图，不能把 SpringBoard 拖死。
    if ([NSThread isMainThread]) {
        fetch();
    } else {
        dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
        dispatch_async(dispatch_get_main_queue(), ^{
          fetch();
          dispatch_semaphore_signal(semaphore);
        });
        dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC));
    }
    return result;
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
