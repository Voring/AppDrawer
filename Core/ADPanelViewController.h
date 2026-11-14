#import <UIKit/UIKit.h>

@class ADAppInfo;

@interface ADPanelViewController : UIViewController

@property (nonatomic, copy) void (^onRequestClose)(void);
@property (nonatomic, copy) void (^onRequestOpenApplication)(NSString *bundleIdentifier);

- (void)setApplications:(NSArray<ADAppInfo *> *)applications;
- (void)setQuery:(NSString *)query;

- (void)animateIn;
- (void)animateOutWithCompletion:(void (^)(void))completion;

@end
