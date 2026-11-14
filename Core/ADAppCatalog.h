#import <Foundation/Foundation.h>

@class ADAppInfo;

@interface ADAppCatalog : NSObject

// 上一次成功枚举的结果，面板可以先用它铺满再刷新。
+ (NSArray<ADAppInfo *> *)cachedApplications;

// 同步枚举（内部会遍历 LSApplicationProxy，建议在后台队列调用）。
+ (NSArray<ADAppInfo *> *)loadApplications;

// 后台刷新，完成后主线程回调。
+ (void)reloadInBackgroundWithCompletion:(void (^)(NSArray<ADAppInfo *> *applications))completion;

@end
