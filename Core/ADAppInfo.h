#import <UIKit/UIKit.h>

@interface ADAppInfo : NSObject

@property (nonatomic, copy, readonly) NSString *bundleIdentifier;
@property (nonatomic, copy, readonly) NSString *displayName;
// 预拼好的检索串：原名 / 全拼 / 首字母 / 去空格全拼，四段以换行分隔（不含 bundle id）
@property (nonatomic, copy, readonly) NSString *searchKey;
@property (nonatomic, strong, readonly) id applicationProxy;

- (instancetype)initWithProxy:(id)proxy
             bundleIdentifier:(NSString *)bundleIdentifier
                  displayName:(NSString *)displayName;

// 同步取图标，调用方自己放到后台队列；内部有 NSCache。
- (UIImage *)iconImage;
// 只读缓存，不触发加载。cell 首次配置时用它，避免「占位图 → 真图标」的闪烁。
- (UIImage *)cachedIconImage;
// 后台批量预热图标缓存，面板唤出时图标已经在内存里。
+ (void)preloadIconsForApplications:(NSArray<ADAppInfo *> *)applications;

@end
