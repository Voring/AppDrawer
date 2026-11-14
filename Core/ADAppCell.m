#import "ADAppCell.h"

#import <QuartzCore/QuartzCore.h>

#import "ADAppInfo.h"

@interface ADAppCell ()
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, copy) NSString *currentBundleIdentifier;
@end

@implementation ADAppCell

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _iconView = [[UIImageView alloc] init];
        _iconView.contentMode = UIViewContentModeScaleAspectFit;
        _iconView.layer.cornerCurve = kCACornerCurveContinuous;
        _iconView.image = [UIImage systemImageNamed:@"app.fill"];
        _iconView.tintColor = [UIColor secondaryLabelColor];

        _nameLabel = [[UILabel alloc] init];
        _nameLabel.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightRegular];
        _nameLabel.textColor = [UIColor labelColor];
        _nameLabel.textAlignment = NSTextAlignmentCenter;
        _nameLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        _nameLabel.numberOfLines = 1;

        [self.contentView addSubview:_iconView];
        [self.contentView addSubview:_nameLabel];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];

    CGFloat width = CGRectGetWidth(self.contentView.bounds);
    CGFloat iconSide = floor(MIN(width * 0.82, 62.0));
    CGFloat iconTop = 4.0;

    self.iconView.frame = CGRectMake(floor((width - iconSide) / 2.0), iconTop, iconSide, iconSide);
    self.iconView.layer.cornerRadius = iconSide * 0.2237;  // 与 iOS 图标遮罩比例接近

    self.nameLabel.frame = CGRectMake(2.0,
                                      CGRectGetMaxY(self.iconView.frame) + 7.0,
                                      width - 4.0,
                                      14.0);
}

- (void)prepareForReuse {
    [super prepareForReuse];
    self.currentBundleIdentifier = nil;
    self.iconView.image = [UIImage systemImageNamed:@"app.fill"];
    self.nameLabel.text = nil;
}

- (void)configureWithApplication:(ADAppInfo *)application {
    self.nameLabel.text = application.displayName;
    self.currentBundleIdentifier = application.bundleIdentifier;

    UIImage *placeholder = [UIImage systemImageNamed:@"app.fill"];
    self.iconView.image = placeholder;

    NSString *bundleIdentifier = application.bundleIdentifier;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      UIImage *icon = [application iconImage];
      if (!icon) {
          return;
      }
      dispatch_async(dispatch_get_main_queue(), ^{
        ADAppCell *cell = weakSelf;
        if (!cell || ![cell.currentBundleIdentifier isEqualToString:bundleIdentifier]) {
            return;
        }
        cell.iconView.image = icon;
      });
    });
}

@end
