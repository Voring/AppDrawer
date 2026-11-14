#import "ADPanelViewController.h"

#import <QuartzCore/QuartzCore.h>

#import "ADAppCell.h"
#import "ADAppInfo.h"
#import "ADPrefs.h"

static NSString *const ADAppCellReuseIdentifier = @"ADAppCell";

// —— 以下视觉/动效参数与 Voring/Kayoko-1 的 Core/Presentation + Core/Views 对齐 ——
// 面板：悬浮卡片，四角连续圆角（半径取自屏幕 displayCornerRadius - 3），阴影 0.28。
static CGFloat const kADPanelHorizontalInset = 8.0;
static CGFloat const kADPanelVerticalGap = 8.0;
static CGFloat const kADPanelShadowOpacity = 0.28;
static CGFloat const kADPanelShadowRadius = 8.0;
static CGFloat const kADPanelCornerRadiusMin = 28.0;
static CGFloat const kADPanelCornerRadiusMax = 54.0;
// 抓杆：42 x 14，线宽 5，labelColor 22% 透明度。
static CGFloat const kADGrabberWidth = 42.0;
static CGFloat const kADGrabberHeight = 14.0;
static CGFloat const kADGrabberLineWidth = 5.0;
static CGFloat const kADGrabberTop = 6.0;
// 竖屏面板高度在偏好值（默认 55%）基础上再缩到 1/3（约屏幕的 18%）。
static CGFloat const kADPanelHeightScale = 1.0 / 3.0;
static CGFloat const kADPanelPortraitMinHeight = 170.0;
// 横屏：宽度取屏幕 1/2，居中；高度沿用偏好值。
static CGFloat const kADPanelLandscapeWidthFraction = 0.5;
static CGFloat const kADPanelLandscapeMinHeight = 220.0;
// 展开/收起：0.33s，弹簧阻尼 1，easeOut；展开位移为自身高度的 1/3。
static NSTimeInterval const kADPanelAnimationDuration = 0.33;
// 上推收起：100pt 内渐进淡出，速度超过 900 直接收。
static CGFloat const kADFadeOutDistance = 100.0;
static CGFloat const kADFastDismissVelocity = 900.0;

@interface ADGrabberView : UIView
@property (nonatomic, strong) CAShapeLayer *lineLayer;
@end

@implementation ADGrabberView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _lineLayer = [CAShapeLayer layer];
        _lineLayer.lineWidth = kADGrabberLineWidth;
        _lineLayer.lineCap = kCALineCapRound;
        _lineLayer.lineJoin = kCALineJoinRound;
        _lineLayer.strokeColor = [[UIColor labelColor] colorWithAlphaComponent:0.22].CGColor;
        [self.layer addSublayer:_lineLayer];
        self.contentMode = UIViewContentModeRedraw;
        self.backgroundColor = [UIColor clearColor];
    }
    return self;
}

- (CGSize)intrinsicContentSize {
    return CGSizeMake(kADGrabberWidth, kADGrabberHeight);
}

// 抓杆本身只有 42x14，但可点区域按 Kayoko 的 CGRectInset(-44, -16) 放大。
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    return CGRectContainsPoint(CGRectInset(self.bounds, -44.0, -16.0), point);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _lineLayer.frame = self.bounds;
    UIBezierPath *path = [UIBezierPath bezierPath];
    CGPoint start = CGPointMake(2.0, CGRectGetMidY(self.bounds));
    CGPoint end = CGPointMake(CGRectGetWidth(self.bounds) - 2.0, CGRectGetMidY(self.bounds));
    [path moveToPoint:start];
    [path addLineToPoint:end];
    _lineLayer.path = path.CGPath;
    _lineLayer.strokeColor = [[UIColor labelColor] colorWithAlphaComponent:0.22].CGColor;
}

@end

@interface ADPanelViewController () <UISearchBarDelegate, UICollectionViewDataSource,
                                     UICollectionViewDelegateFlowLayout, UIGestureRecognizerDelegate>

@property (nonatomic, strong) UIView *dimView;
// 承载阴影的透明外壳；真正的裁剪在 chromeClipView 上（阴影与裁剪必须分层）。
@property (nonatomic, strong) UIView *cardView;
@property (nonatomic, strong) UIView *chromeClipView;
@property (nonatomic, strong) UIVisualEffectView *blurView;
@property (nonatomic, strong) UIView *materialTintView;
@property (nonatomic, strong) ADGrabberView *grabberView;
@property (nonatomic, strong) UISearchBar *searchBar;
@property (nonatomic, strong) UICollectionView *collectionView;
@property (nonatomic, strong) UILabel *emptyLabel;

@property (nonatomic, strong) UIPanGestureRecognizer *panGestureRecognizer;
@property (nonatomic, assign) BOOL panDidFadeOut;
@property (nonatomic, assign, getter=isAnimating) BOOL animating;

@property (nonatomic, copy) NSArray<ADAppInfo *> *allApplications;
@property (nonatomic, copy) NSArray<ADAppInfo *> *filteredApplications;
@property (nonatomic, copy) NSString *lastAppliedQuery;

@end

@implementation ADPanelViewController

#pragma mark - 生命周期

- (void)viewDidLoad {
    [super viewDidLoad];

    self.view.backgroundColor = [UIColor clearColor];

    _dimView = [[UIView alloc] init];
    _dimView.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.30];
    [_dimView addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self
                                                                          action:@selector(handleBackgroundTap)]];
    [self.view addSubview:_dimView];

    _cardView = [[UIView alloc] init];
    _cardView.backgroundColor = [UIColor clearColor];
    _cardView.opaque = NO;
    _cardView.clipsToBounds = NO;
    _cardView.layer.cornerCurve = kCACornerCurveContinuous;
    _cardView.layer.shadowColor = [UIColor blackColor].CGColor;
    _cardView.layer.shadowOffset = CGSizeMake(0.0, 1.0);
    _cardView.layer.shadowRadius = kADPanelShadowRadius;
    _cardView.layer.shadowOpacity = kADPanelShadowOpacity;
    [self.view addSubview:_cardView];

    _chromeClipView = [[UIView alloc] init];
    _chromeClipView.backgroundColor = [UIColor clearColor];
    _chromeClipView.opaque = NO;
    _chromeClipView.clipsToBounds = YES;
    _chromeClipView.layer.cornerCurve = kCACornerCurveContinuous;
    [_cardView addSubview:_chromeClipView];

    _blurView = [[UIVisualEffectView alloc] initWithEffect:[self preferredBlurEffect]];
    _blurView.backgroundColor = [UIColor clearColor];
    _blurView.opaque = NO;
    _blurView.contentView.backgroundColor = [UIColor clearColor];
    _blurView.contentView.opaque = NO;
    _blurView.layer.masksToBounds = YES;
    _blurView.layer.cornerCurve = kCACornerCurveContinuous;
    [_chromeClipView addSubview:_blurView];

    _materialTintView = [[UIView alloc] init];
    _materialTintView.userInteractionEnabled = NO;
    _materialTintView.backgroundColor = [self preferredMaterialTintColor];
    [_blurView.contentView addSubview:_materialTintView];

    _grabberView = [[ADGrabberView alloc] initWithFrame:CGRectZero];
    [_chromeClipView addSubview:_grabberView];
    // 点抓杆 = 收起（Kayoko 的 grabber tap 行为）；手势挂在抓杆自己身上，
    // 不能挂到卡片上，否则点列表格子会被这个 tap 吃掉。
    UITapGestureRecognizer *grabberTap =
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleGrabberTap)];
    [_grabberView addGestureRecognizer:grabberTap];

    _searchBar = [[UISearchBar alloc] init];
    _searchBar.delegate = self;
    _searchBar.searchBarStyle = UISearchBarStyleMinimal;
    _searchBar.placeholder = @"搜索 App";
    _searchBar.autocorrectionType = UITextAutocorrectionTypeNo;
    _searchBar.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _searchBar.returnKeyType = UIReturnKeyDone;
    _searchBar.backgroundImage = [[UIImage alloc] init];
    _searchBar.backgroundColor = [UIColor clearColor];
    _searchBar.searchTextField.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.14];
    _searchBar.searchTextField.textColor = [UIColor labelColor];
    _searchBar.searchTextField.clearButtonMode = UITextFieldViewModeWhileEditing;
    _searchBar.searchTextField.enablesReturnKeyAutomatically = NO;
    [_chromeClipView addSubview:_searchBar];

    UICollectionViewFlowLayout *layout = [[UICollectionViewFlowLayout alloc] init];
    layout.minimumLineSpacing = 14.0;
    layout.minimumInteritemSpacing = 4.0;
    layout.sectionInset = UIEdgeInsetsMake(4.0, 16.0, 12.0, 16.0);

    _collectionView = [[UICollectionView alloc] initWithFrame:CGRectZero collectionViewLayout:layout];
    _collectionView.backgroundColor = [UIColor clearColor];
    _collectionView.alwaysBounceVertical = YES;
    _collectionView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    _collectionView.dataSource = self;
    _collectionView.delegate = self;
    _collectionView.contentInset = UIEdgeInsetsMake(2.0, 0.0, 16.0, 0.0);
    [_collectionView registerClass:[ADAppCell class]
        forCellWithReuseIdentifier:ADAppCellReuseIdentifier];
    [_chromeClipView addSubview:_collectionView];

    _emptyLabel = [[UILabel alloc] init];
    _emptyLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightRegular];
    _emptyLabel.textColor = [UIColor secondaryLabelColor];
    _emptyLabel.textAlignment = NSTextAlignmentCenter;
    _emptyLabel.numberOfLines = 0;
    _emptyLabel.text = @"正在读取已安装 App…";
    [_chromeClipView addSubview:_emptyLabel];

    _panGestureRecognizer = [[UIPanGestureRecognizer alloc] initWithTarget:self
                                                                    action:@selector(handlePanGesture:)];
    _panGestureRecognizer.delegate = self;
    [_cardView addGestureRecognizer:_panGestureRecognizer];

    [self applyFilterResettingOffset:YES];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];

    // 面板是搜索型 UI：一出来就给键盘，同时也验证 window 是否真的拿到了 key。
    [self.view.window makeKeyWindow];
    [self focusSearchField];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self layoutPanel];
}

- (void)viewSafeAreaInsetsDidChange {
    [super viewSafeAreaInsetsDidChange];
    [self layoutPanel];
}

#pragma mark - 材质

- (BOOL)prefersDarkMaterial {
    if (@available(iOS 13.0, *)) {
        if (self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark) {
            return YES;
        }
    }
    return NO;
}

// 与 Kayoko 一致：SystemThinMaterial（而不是厚的 SystemMaterial），
// 背后能透出一点壁纸，观感更轻。
- (UIBlurEffect *)preferredBlurEffect {
    NSInteger style = ADPrefBlurStyle();
    if (style != UIBlurEffectStyleSystemMaterial) {
        // 用户在偏好里显式指定了样式，尊重设置。
        return [UIBlurEffect effectWithStyle:(UIBlurEffectStyle)style];
    }
    if (@available(iOS 13.0, *)) {
        return [UIBlurEffect effectWithStyle:[self prefersDarkMaterial]
                                                   ? UIBlurEffectStyleSystemThinMaterialDark
                                                   : UIBlurEffectStyleSystemThinMaterialLight];
    }
    return [UIBlurEffect effectWithStyle:UIBlurEffectStyleRegular];
}

- (UIColor *)preferredMaterialTintColor {
    if ([self prefersDarkMaterial]) {
        return [UIColor colorWithWhite:1.0 alpha:0.06];
    }
    return [UIColor colorWithWhite:1.0 alpha:0.34];
}

- (void)applyMaterialAppearance {
    _blurView.effect = [self preferredBlurEffect];
    _materialTintView.backgroundColor = [self preferredMaterialTintColor];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if (@available(iOS 13.0, *)) {
        if (previousTraitCollection &&
            previousTraitCollection.userInterfaceStyle != self.traitCollection.userInterfaceStyle) {
            [self applyMaterialAppearance];
        }
    }
    [self layoutPanel];
}

// 圆角按屏幕物理圆角推导：displayCornerRadius - 3，夹在 28...54 之间。
- (CGFloat)resolvedCornerRadius {
    CGFloat radius = ADPrefPanelCornerRadius();
    UIScreen *screen = self.view.window.windowScene.screen ?: [UIScreen mainScreen];
    @try {
        NSNumber *value = [screen valueForKey:@"_displayCornerRadius"];
        if (!value) {
            value = [screen valueForKey:@"displayCornerRadius"];
        }
        if ([value respondsToSelector:@selector(doubleValue)]) {
            radius = MAX(radius, [value doubleValue] - 3.0);
        }
    } @catch (__unused NSException *exception) {
        // 取不到就退回偏好值。
    }
    return MAX(kADPanelCornerRadiusMin, MIN(kADPanelCornerRadiusMax, radius));
}

#pragma mark - 布局

- (BOOL)isLandscapeInterface {
    UIInterfaceOrientation orientation = UIInterfaceOrientationPortrait;
    if (@available(iOS 13.0, *)) {
        UIWindowScene *scene = self.view.window.windowScene;
        if (scene) {
            orientation = scene.interfaceOrientation;
        }
    }
    if (orientation == UIInterfaceOrientationUnknown) {
        // 16.5 SDK 上 statusBarOrientation 已 deprecated，这里改用窗口尺寸判断。
        CGSize screenSize = self.view.window.bounds.size;
        if (screenSize.width <= 0.0 || screenSize.height <= 0.0) {
            screenSize = [UIScreen mainScreen].bounds.size;
        }
        return screenSize.width > screenSize.height;
    }
    return UIInterfaceOrientationIsLandscape(orientation);
}

// 收起手势的方向系数：竖屏向上推（负），横屏向下拉（正）。
- (CGFloat)panDismissSign {
    return [self isLandscapeInterface] ? 1.0 : -1.0;
}

- (void)viewWillTransitionToSize:(CGSize)size
       withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    __weak typeof(self) weakSelf = self;
    [coordinator animateAlongsideTransition:^(__unused id<UIViewControllerTransitionCoordinatorContext> context) {
      [weakSelf layoutPanel];
    } completion:nil];
}

- (void)layoutPanel {
    CGFloat width = CGRectGetWidth(self.view.bounds);
    CGFloat height = CGRectGetHeight(self.view.bounds);
    if (width <= 0.0 || height <= 0.0) {
        return;
    }

    BOOL landscape = [self isLandscapeInterface];
    CGFloat topInset = MAX(self.view.safeAreaInsets.top, 20.0);

    CGFloat cardWidth = 0.0;
    CGFloat cardHeight = 0.0;
    CGFloat originX = 0.0;
    CGFloat originY = 0.0;

    if (landscape) {
        // 横屏：半宽、水平居中，交互条在上方。
        cardWidth = floor(width * kADPanelLandscapeWidthFraction);
        cardHeight = floor(height * ADPrefPanelHeightPercent());
        cardHeight = MAX(cardHeight, kADPanelLandscapeMinHeight);
        cardHeight = MIN(cardHeight, height - kADPanelVerticalGap * 2.0);
        originX = floor((width - cardWidth) / 2.0);
        originY = floor((height - cardHeight) / 2.0);
    } else {
        // 竖屏：贴顶，高度缩到偏好值的 1/3。
        cardWidth = width - kADPanelHorizontalInset * 2.0;
        cardHeight = floor((height - topInset) * ADPrefPanelHeightPercent() * kADPanelHeightScale);
        cardHeight = MAX(cardHeight, kADPanelPortraitMinHeight);
        cardHeight = MIN(cardHeight, height - topInset - kADPanelVerticalGap);
        originX = kADPanelHorizontalInset;
        originY = topInset;
    }

    self.dimView.frame = self.view.bounds;

    self.cardView.frame = CGRectMake(originX, originY, cardWidth, cardHeight);
    CGFloat radius = [self resolvedCornerRadius];
    self.cardView.layer.cornerRadius = radius;
    self.cardView.layer.shadowPath =
        [UIBezierPath bezierPathWithRoundedRect:self.cardView.bounds cornerRadius:radius].CGPath;

    self.chromeClipView.frame = self.cardView.bounds;
    self.chromeClipView.layer.cornerRadius = radius;
    self.chromeClipView.layer.maskedCorners =
        kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner | kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner;

    self.blurView.frame = self.chromeClipView.bounds;
    self.blurView.layer.cornerRadius = radius;
    self.materialTintView.frame = self.blurView.contentView.bounds;

    CGFloat cardWidthActual = CGRectGetWidth(self.cardView.bounds);
    CGFloat cardHeightActual = CGRectGetHeight(self.cardView.bounds);
    CGFloat horizontalInset = 8.0;
    CGFloat searchHeight = 48.0;

    if (landscape) {
        // 横屏：抓杆在上，搜索框紧随其后，列表在下方。
        self.grabberView.frame = CGRectMake(floor((cardWidthActual - kADGrabberWidth) / 2.0),
                                            kADGrabberTop,
                                            kADGrabberWidth,
                                            kADGrabberHeight);
        CGFloat searchY = CGRectGetMaxY(self.grabberView.frame) + 2.0;
        self.searchBar.frame = CGRectMake(horizontalInset,
                                          searchY,
                                          cardWidthActual - horizontalInset * 2.0,
                                          searchHeight);
        CGFloat listTop = CGRectGetMaxY(self.searchBar.frame);
        self.collectionView.frame = CGRectMake(0.0,
                                               listTop,
                                               cardWidthActual,
                                               MAX(cardHeightActual - listTop - 4.0, 0.0));
    } else {
        // 竖屏：交互元素全部贴底，列表在上方。
        CGFloat grabberY = cardHeightActual - kADGrabberTop - kADGrabberHeight;
        self.grabberView.frame = CGRectMake(floor((cardWidthActual - kADGrabberWidth) / 2.0),
                                            grabberY,
                                            kADGrabberWidth,
                                            kADGrabberHeight);
        CGFloat searchY = grabberY - 2.0 - searchHeight;
        self.searchBar.frame = CGRectMake(horizontalInset,
                                          searchY,
                                          cardWidthActual - horizontalInset * 2.0,
                                          searchHeight);
        CGFloat listTop = 8.0;
        self.collectionView.frame = CGRectMake(0.0,
                                               listTop,
                                               cardWidthActual,
                                               MAX(searchY - listTop, 0.0));
    }
    self.emptyLabel.frame = CGRectInset(self.collectionView.frame, 24.0, 0.0);
}

#pragma mark - 输入框

- (void)focusSearchField {
    if (!self.searchBar.window) {
        return;
    }
    [self.searchBar.searchTextField becomeFirstResponder];
    [self.searchBar setShowsCancelButton:YES animated:NO];
}

- (BOOL)isSearchFieldFirstResponder {
    return self.searchBar.searchTextField.isFirstResponder;
}

#pragma mark - 数据

- (void)setApplications:(NSArray<ADAppInfo *> *)applications {
    NSArray<ADAppInfo *> *incoming = applications ?: @[];

    // 内容没变就什么都不做：这是打开面板时列表「闪一下」的主要原因
    // （后台重载回来的同一份列表触发了 reloadData 并重置了滚动位置）。
    if ([self _applications:incoming equalTo:self.allApplications]) {
        return;
    }

    self.allApplications = incoming;
    [self applyFilterResettingOffset:NO];
}

- (BOOL)_applications:(NSArray<ADAppInfo *> *)lhs equalTo:(NSArray<ADAppInfo *> *)rhs {
    if (lhs.count != rhs.count) {
        return NO;
    }
    for (NSUInteger index = 0; index < lhs.count; index++) {
        if (![lhs[index].bundleIdentifier isEqualToString:rhs[index].bundleIdentifier]) {
            return NO;
        }
    }
    return YES;
}

- (void)setQuery:(NSString *)query {
    NSString *text = query ?: @"";
    if ([self.searchBar.text isEqualToString:text]) {
        return;
    }
    self.searchBar.text = text;
    [self applyFilterResettingOffset:YES];
}

- (NSString *)_normalizedQuery {
    NSString *raw = self.searchBar.text ?: @"";
    NSString *trimmed = [raw stringByTrimmingCharactersInSet:
                                   [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return [trimmed lowercaseString];
}

- (void)applyFilter {
    [self applyFilterResettingOffset:NO];
}

- (void)applyFilterResettingOffset:(BOOL)resetsOffset {
    NSString *query = [self _normalizedQuery];
    BOOL queryChanged = !(self.lastAppliedQuery == nil ? (query.length == 0)
                                                       : [self.lastAppliedQuery isEqualToString:query]);
    self.lastAppliedQuery = query;

    if (query.length == 0) {
        self.filteredApplications = self.allApplications ?: @[];
    } else {
        NSString *compactQuery = [query stringByReplacingOccurrencesOfString:@" " withString:@""];
        NSMutableArray<ADAppInfo *> *matches = [NSMutableArray array];
        for (ADAppInfo *application in self.allApplications) {
            NSString *key = application.searchKey;
            if ([key rangeOfString:query].location != NSNotFound ||
                (compactQuery.length && [key rangeOfString:compactQuery].location != NSNotFound)) {
                [matches addObject:application];
            }
        }
        self.filteredApplications = matches;
    }

    [self.collectionView reloadData];

    if (self.filteredApplications.count == 0) {
        self.emptyLabel.hidden = NO;
        if (self.allApplications.count == 0) {
            self.emptyLabel.text = @"正在读取已安装 App…";
        } else {
            self.emptyLabel.text = query.length ? @"没有找到 App" : @"还没有可显示的 App";
        }
    } else {
        self.emptyLabel.hidden = YES;
    }

    // 只有搜索词真的变了才回到顶部，后台刷新不能把用户正在看的位置弹走。
    if (resetsOffset || queryChanged) {
        if (self.filteredApplications.count > 0) {
            [self.collectionView setContentOffset:CGPointMake(0.0, -self.collectionView.contentInset.top)
                                          animated:NO];
        }
    }
}

#pragma mark - 动画

- (void)animateIn {
    [self.view layoutIfNeeded];

    // 面板贴顶，所以展开位移取负值：从上方落下来（与下半屏的 Kayoko 镜像）。
    _cardView.transform = CGAffineTransformMakeTranslation(0.0,
                                                           -CGRectGetHeight(self.cardView.bounds) / 3.0);
    _cardView.alpha = 0.0;
    _dimView.alpha = 0.0;

    _animating = YES;
    __weak typeof(self) weakSelf = self;
    [UIView animateWithDuration:kADPanelAnimationDuration
                          delay:0.0
         usingSpringWithDamping:1.0
          initialSpringVelocity:0.0
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
                       ADPanelViewController *strongSelf = weakSelf;
                       strongSelf.cardView.transform = CGAffineTransformIdentity;
                       strongSelf.cardView.alpha = 1.0;
                       strongSelf.dimView.alpha = 1.0;
                     }
                     completion:^(__unused BOOL finished) {
                       weakSelf.animating = NO;
                     }];
}

- (void)animateOutWithCompletion:(void (^)(void))completion {
    [self.view endEditing:YES];

    _animating = YES;
    __weak typeof(self) weakSelf = self;
    [UIView animateWithDuration:kADPanelAnimationDuration
                          delay:0.0
         usingSpringWithDamping:1.0
          initialSpringVelocity:0.0
                        options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionBeginFromCurrentState
                     animations:^{
                       ADPanelViewController *strongSelf = weakSelf;
                       strongSelf.cardView.alpha = 0.0;
                       strongSelf.dimView.alpha = 0.0;
                     }
                     completion:^(__unused BOOL finished) {
                       ADPanelViewController *strongSelf = weakSelf;
                       strongSelf.cardView.transform = CGAffineTransformIdentity;
                       strongSelf.animating = NO;
                       if (completion) {
                           completion();
                       }
                     }];
}

#pragma mark - 交互

- (void)handleBackgroundTap {
    [self.view endEditing:YES];
    if (self.onRequestClose) {
        self.onRequestClose();
    }
}

- (void)handleGrabberTap {
    if (self.isAnimating) {
        return;
    }
    if (self.onRequestClose) {
        self.onRequestClose();
    }
}

- (void)handlePanGesture:(UIPanGestureRecognizer *)recognizer {
    CGPoint translation = [recognizer translationInView:self.cardView];
    CGPoint velocity = [recognizer velocityInView:self.cardView];

    if (recognizer.state == UIGestureRecognizerStateBegan) {
        _panDidFadeOut = NO;
        _dimView.userInteractionEnabled = NO;
        return;
    }

    if (recognizer.state == UIGestureRecognizerStateChanged) {
        // 竖屏只接受上推（负），横屏只接受下拉（正）。
        CGFloat sign = [self panDismissSign];
        if (translation.y * sign < 0.0 && !_panDidFadeOut) {
            return;
        }
        CGFloat fadeProgress = MIN(MAX(translation.y * sign / kADFadeOutDistance, 0.0), 1.0);
        if (_panDidFadeOut || fadeProgress >= 1.0) {
            _panDidFadeOut = YES;
            fadeProgress = 1.0;
            translation.y = sign * kADFadeOutDistance;
        }
        [UIView animateWithDuration:0.1
                              delay:0.0
             usingSpringWithDamping:0.7
              initialSpringVelocity:0.0
                            options:UIViewAnimationOptionCurveEaseOut |
                                    UIViewAnimationOptionBeginFromCurrentState
                         animations:^{
                           self.cardView.transform =
                               CGAffineTransformMakeTranslation(0.0, translation.y);
                           self.cardView.alpha = 1.0 - fadeProgress;
                           self.dimView.alpha = 1.0 - fadeProgress;
                         }
                         completion:nil];
        return;
    }

    if (recognizer.state != UIGestureRecognizerStateEnded &&
        recognizer.state != UIGestureRecognizerStateCancelled &&
        recognizer.state != UIGestureRecognizerStateFailed) {
        return;
    }

    CGFloat sign = [self panDismissSign];
    BOOL fastDismiss = (recognizer.state == UIGestureRecognizerStateEnded) && !_panDidFadeOut &&
                       translation.y * sign > 0.0 && velocity.y * sign >= kADFastDismissVelocity;
    if (_panDidFadeOut || fastDismiss) {
        if (self.onRequestClose) {
            self.onRequestClose();
        }
        return;
    }

    [UIView animateWithDuration:0.4
                          delay:0.0
         usingSpringWithDamping:1.0
          initialSpringVelocity:0.0
                        options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionBeginFromCurrentState
                     animations:^{
                       self.cardView.transform = CGAffineTransformIdentity;
                       self.cardView.alpha = 1.0;
                       self.dimView.alpha = 1.0;
                     }
                     completion:^(__unused BOOL finished) {
                       self.dimView.userInteractionEnabled = YES;
                     }];
}

#pragma mark - UIGestureRecognizerDelegate

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if (gestureRecognizer != self.panGestureRecognizer) {
        return YES;
    }
    if (self.isAnimating) {
        return NO;
    }

    CGPoint velocity = [(UIPanGestureRecognizer *)gestureRecognizer velocityInView:self.cardView];
    CGFloat sign = [self panDismissSign];
    if (velocity.y * sign <= 0.0 || fabs(velocity.x) >= fabs(velocity.y)) {
        return NO;
    }

    // 列表还有滚动余量时，拖动优先给列表；到达边界才接管为收起手势。
    CGPoint location = [gestureRecognizer locationInView:self.cardView];
    if (CGRectContainsPoint(self.collectionView.frame, location)) {
        UIEdgeInsets insets = self.collectionView.adjustedContentInset;
        if ([self isLandscapeInterface]) {
            // 横屏下拉：列表回到顶部才收。
            return self.collectionView.contentOffset.y <= -insets.top + 0.5;
        }
        CGFloat bottomBoundary =
            self.collectionView.contentSize.height - CGRectGetHeight(self.collectionView.bounds) +
            insets.bottom;
        if (bottomBoundary <= 0.0) {
            return YES;
        }
        return self.collectionView.contentOffset.y >= bottomBoundary - 0.5;
    }
    return YES;
}

#pragma mark - UISearchBarDelegate

- (void)searchBarTextDidBeginEditing:(UISearchBar *)searchBar {
    // SpringBoard 会不时把自己的主窗口抢回 key window，这里再抢一次保证键盘有落点。
    [self.view.window makeKeyWindow];
    [searchBar setShowsCancelButton:YES animated:YES];
}

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    [self applyFilterResettingOffset:YES];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];
}

- (void)searchBarCancelButtonClicked:(UISearchBar *)searchBar {
    searchBar.text = @"";
    [searchBar setShowsCancelButton:NO animated:YES];
    [searchBar resignFirstResponder];
    [self applyFilterResettingOffset:YES];
}

#pragma mark - UICollectionViewDataSource

- (NSInteger)collectionView:(UICollectionView *)collectionView
     numberOfItemsInSection:(NSInteger)section {
    return (NSInteger)self.filteredApplications.count;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView
                  cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    ADAppCell *cell = (ADAppCell *)[collectionView dequeueReusableCellWithReuseIdentifier:ADAppCellReuseIdentifier
                                                                             forIndexPath:indexPath];
    if (indexPath.item < (NSInteger)self.filteredApplications.count) {
        [cell configureWithApplication:self.filteredApplications[indexPath.item]];
    }
    return cell;
}

#pragma mark - UICollectionViewDelegateFlowLayout

- (CGSize)collectionView:(UICollectionView *)collectionView
                    layout:(UICollectionViewLayout *)collectionViewLayout
    sizeForItemAtIndexPath:(NSIndexPath *)indexPath {
    CGFloat width = CGRectGetWidth(collectionView.bounds);
    NSInteger columns = ADPrefColumns();
    CGFloat horizontalInsets = 32.0;
    CGFloat spacing = (CGFloat)(columns - 1) * 4.0;
    CGFloat itemWidth = floor((width - horizontalInsets - spacing) / (CGFloat)columns);
    CGFloat iconSide = MIN(floor(itemWidth * 0.82), 62.0);
    return CGSizeMake(itemWidth, iconSide + 34.0);
}

#pragma mark - UICollectionViewDelegate

- (void)collectionView:(UICollectionView *)collectionView
    didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    [collectionView deselectItemAtIndexPath:indexPath animated:NO];
    [self.view endEditing:YES];

    if (indexPath.item >= (NSInteger)self.filteredApplications.count) {
        return;
    }

    ADAppInfo *application = self.filteredApplications[indexPath.item];
    if (self.onRequestOpenApplication) {
        self.onRequestOpenApplication(application.bundleIdentifier);
    }
}

@end
