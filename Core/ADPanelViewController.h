#import <UIKit/UIKit.h>

@class ADAppInfo;

@interface ADPanelViewController : UIViewController

@property (nonatomic, copy) void (^onRequestClose)(void);
@property (nonatomic, copy) void (^onRequestOpenApplication)(NSString *bundleIdentifier);

- (void)setApplications:(NSArray<ADAppInfo *> *)applications;
- (void)setQuery:(NSString *)query;

// 把键盘叫到搜索框上（同时也能看出 window 是否真的拿到了 key）。
- (void)focusSearchField;

- (void)animateIn;
- (void)animateOutWithCompletion:(void (^)(void))completion;

@end
