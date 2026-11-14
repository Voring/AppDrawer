#import <UIKit/UIKit.h>

@interface ADAppInfo : NSObject

@property (nonatomic, copy, readonly) NSString *bundleIdentifier;
@property (nonatomic, copy, readonly) NSString *displayName;
// 预拼好的检索串：原名 + bundle id + 全拼 + 首字母 + 去空格全拼
@property (nonatomic, copy, readonly) NSString *searchKey;
@property (nonatomic, strong, readonly) id applicationProxy;

- (instancetype)initWithProxy:(id)proxy
             bundleIdentifier:(NSString *)bundleIdentifier
                  displayName:(NSString *)displayName;

// 同步取图标，调用方自己放到后台队列；内部有 NSCache。
- (UIImage *)iconImage;

@end
