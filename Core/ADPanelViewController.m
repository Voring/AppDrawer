#import "ADPanelViewController.h"

#import <QuartzCore/QuartzCore.h>

#import "ADAppCell.h"
#import "ADAppInfo.h"
#import "ADPrefs.h"
#import "ADURLScheme.h"

// 重写版（1.3.x）：只有一套竖屏布局，横屏时它就是同一套参数按窗口宽度/高度自然拉伸。
// 没有任何 isLandscape 判定、没有任何 view.frame / transform 的强制改写。
// 位置只由两个量决定：一个固定偏好偏移，和键盘顶边。

static NSString *const ADAppCellReuseIdentifier = @"ADAppCell";

// 检索前统一剔除空格、声调残留、不可见字符等：只保留字母、数字、汉字。
static NSString *ADNormalizeText(NSString *raw) {
    if (raw.length == 0) {
        return @"";
    }
    NSMutableString *out = [NSMutableString string];
    for (NSUInteger i = 0; i < raw.length; i++) {
        unichar c = [raw characterAtIndex:i];
        BOOL alnum = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') ||
                     (c >= 'A' && c <= 'Z');
        BOOL cjk = c >= 0x4E00 && c <= 0x9FFF;
        if (alnum || cjk) {
            [out appendFormat:@"%c", c];
        }
    }
    return out.lowercaseString;
}

static CGFloat const kADPanelSideInset = 8.0;
static CGFloat const kADPanelEdgeGap = 8.0;
static CGFloat const kADPanelTopOffset = 40.0;
static CGFloat const kADPanelMaxWidth = 430.0;
// 面板高度缩放系数（宽保持满宽/430 封顶）。可在 Core/Makefile 用
// -DAD_PANEL_HEIGHT_REDUCTION=... 调整，不必改源码。1.0 = 初版高度（约 290）。
#ifndef AD_PANEL_HEIGHT_REDUCTION
#define AD_PANEL_HEIGHT_REDUCTION (1.0)
#endif
static CGFloat const kADPanelHeightReduction = AD_PANEL_HEIGHT_REDUCTION;
static CGFloat const kADPanelKeyboardMinHeight = 120.0;
static CGFloat const kADPanelHeightScale = 2.0 / 3.0;
static CGFloat const kADPanelMinHeight = 200.0;
static CGFloat const kADPanelShadowOpacity = 0.28;
static CGFloat const kADPanelShadowRadius = 8.0;
static CGFloat const kADPanelCornerRadiusMin = 28.0;
static CGFloat const kADPanelCornerRadiusMax = 54.0;
static CGFloat const kADGrabberWidth = 42.0;
static CGFloat const kADGrabberHeight = 14.0;
static CGFloat const kADGrabberLineWidth = 5.0;
static CGFloat const kADGrabberInset = 6.0;
static CGFloat const kADSearchHeight = 48.0;
static CGFloat const kADListTopInset = 8.0;
static NSTimeInterval const kADPanelAnimationDuration = 0.33;
static CGFloat const kADFadeOutDistance = 60.0;
static CGFloat const kADFastDismissVelocity = 900.0;

@interface ADGrabberView : UIView
@end

@implementation ADGrabberView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.contentMode = UIViewContentModeRedraw;
    }
    return self;
}

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    return CGRectContainsPoint(CGRectInset(self.bounds, -44.0, -16.0), point);
}

- (void)drawRect:(CGRect)rect {
    [[[UIColor labelColor] colorWithAlphaComponent:0.22] setStroke];
    UIBezierPath *path = [UIBezierPath bezierPath];
    path.lineWidth = kADGrabberLineWidth;
    // 圆头，不要方头小长方形。
    path.lineCapStyle = kCGLineCapRound;
    [path moveToPoint:CGPointMake(2.0, CGRectGetMidY(self.bounds))];
    [path addLineToPoint:CGPointMake(CGRectGetWidth(self.bounds) - 2.0, CGRectGetMidY(self.bounds))];
    [path stroke];
}

@end

@interface ADPanelViewController () <UISearchBarDelegate, UICollectionViewDataSource,
                                     UICollectionViewDelegateFlowLayout, UIGestureRecognizerDelegate>

@property (nonatomic, strong) UIView *dimView;
@property (nonatomic, strong) UIView *cardView;
@property (nonatomic, strong) UIVisualEffectView *blurView;
@property (nonatomic, strong) UIView *tintView;
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
// 委托回调带回的当前文本（marked 阶段比直接读 field.text 更全）。
@property (nonatomic, copy) NSString *lastDelegateText;

// 键盘顶边（self.view 坐标系）；0 表示当前没有键盘。位置由它推出来，不靠横竖屏判定。
@property (nonatomic, assign) CGFloat keyboardTop;
@property (nonatomic, strong) NSTimer *queryPollTimer;

@end

@implementation ADPanelViewController


// 检索诊断：后台串行写，定长，不阻塞主线程。
static void ADQueryDiag(NSString *line) {
    if (line.length == 0) {
        return;
    }
    static dispatch_queue_t queue;
    static NSMutableArray<NSString *> *lines;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("com.voring.appdrawer.query.diag", DISPATCH_QUEUE_SERIAL);
        lines = [NSMutableArray array];
    });
    dispatch_async(queue, ^{
        [lines addObject:line];
        while (lines.count > 24) {
            [lines removeObjectAtIndex:0];
        }
        NSString *directory = ADRequestDirectoryPath();
        [[NSFileManager defaultManager] createDirectoryAtPath:directory
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:NULL];
        NSString *path = [directory stringByAppendingPathComponent:@"querydiag.txt"];
        [[lines componentsJoinedByString:@"\n"] writeToFile:path
                                               atomically:YES
                                                 encoding:NSUTF8StringEncoding
                                                    error:NULL];
    });
}

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
    _cardView.clipsToBounds = YES;
    _cardView.layer.cornerCurve = kCACornerCurveContinuous;
    _cardView.layer.shadowColor = [UIColor blackColor].CGColor;
    _cardView.layer.shadowOffset = CGSizeMake(0.0, 1.0);
    _cardView.layer.shadowRadius = kADPanelShadowRadius;
    _cardView.layer.shadowOpacity = kADPanelShadowOpacity;
    [self.view addSubview:_cardView];

    _blurView = [[UIVisualEffectView alloc] initWithEffect:[self preferredBlurEffect]];
    _blurView.backgroundColor = [UIColor clearColor];
    [_cardView addSubview:_blurView];

    _tintView = [[UIView alloc] init];
    _tintView.userInteractionEnabled = NO;
    _tintView.backgroundColor = [self preferredTintColor];
    [_blurView.contentView addSubview:_tintView];

    _grabberView = [[ADGrabberView alloc] initWithFrame:CGRectZero];
    [_cardView addSubview:_grabberView];
    [_grabberView addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self
                                                                              action:@selector(handleGrabberTap)]];

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
    [_cardView addSubview:_searchBar];

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
    // 交互条在最下方，所以列表按「从下往上」铺，第一项贴着搜索框。
    _collectionView.transform = CGAffineTransformMakeScale(1.0, -1.0);
    [_collectionView registerClass:[ADAppCell class]
        forCellWithReuseIdentifier:ADAppCellReuseIdentifier];
    [_cardView addSubview:_collectionView];

    _emptyLabel = [[UILabel alloc] init];
    _emptyLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightRegular];
    _emptyLabel.textColor = [UIColor secondaryLabelColor];
    _emptyLabel.textAlignment = NSTextAlignmentCenter;
    _emptyLabel.numberOfLines = 0;
    _emptyLabel.text = @"正在读取已安装 App…";
    [_cardView addSubview:_emptyLabel];

    _panGestureRecognizer = [[UIPanGestureRecognizer alloc] initWithTarget:self
                                                                    action:@selector(handlePanGesture:)];
    _panGestureRecognizer.delegate = self;
    [_cardView addGestureRecognizer:_panGestureRecognizer];

    [self applyFilterResettingOffset:YES];
    [self startObservingKeyboard];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self stopQueryPolling];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self.view.window makeKeyWindow];
    [self focusSearchField];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self layoutPanel];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if (@available(iOS 13.0, *)) {
        if (previousTraitCollection &&
            previousTraitCollection.userInterfaceStyle != self.traitCollection.userInterfaceStyle) {
            _blurView.effect = [self preferredBlurEffect];
            _tintView.backgroundColor = [self preferredTintColor];
        }
    }
    [self layoutPanel];
}

#pragma mark - 材质

- (BOOL)prefersDarkMaterial {
    if (@available(iOS 13.0, *)) {
        return self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
    }
    return NO;
}

- (UIBlurEffect *)preferredBlurEffect {
    if (@available(iOS 13.0, *)) {
        return [UIBlurEffect effectWithStyle:[self prefersDarkMaterial]
                                                ? UIBlurEffectStyleSystemThinMaterialDark
                                                : UIBlurEffectStyleSystemThinMaterialLight];
    }
    return [UIBlurEffect effectWithStyle:UIBlurEffectStyleRegular];
}

- (UIColor *)preferredTintColor {
    return [UIColor colorWithWhite:1.0 alpha:[self prefersDarkMaterial] ? 0.06 : 0.34];
}

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
    }
    return MAX(kADPanelCornerRadiusMin, MIN(kADPanelCornerRadiusMax, radius));
}

#pragma mark - 布局（一套参数，横屏自然拉伸）

- (void)layoutPanel {
    CGFloat width = CGRectGetWidth(self.view.bounds);
    CGFloat height = CGRectGetHeight(self.view.bounds);
    if (width <= 0.0 || height <= 0.0) {
        return;
    }
    // 拖拽过程中卡片带 transform，此时不改 frame。
    if (!CGAffineTransformIsIdentity(self.cardView.transform)) {
        return;
    }

    UIEdgeInsets safeArea = self.view.safeAreaInsets;
    CGFloat topLimit = safeArea.top + kADPanelEdgeGap;

    // 宽度不变：竖屏满宽，横屏封顶 430 居中。
    CGFloat cardWidth = MIN(width - kADPanelSideInset * 2.0, kADPanelMaxWidth);
    CGFloat originX = floor((width - cardWidth) / 2.0);

    CGFloat preferredHeight = floor((height - safeArea.top) * ADPrefPanelHeightPercent() *
                                    kADPanelHeightScale * kADPanelHeightReduction);
    preferredHeight = MAX(preferredHeight, kADPanelMinHeight);

    // 只有一条几何约束：卡片底边不许越过键盘顶边。竖屏键盘矮 → 卡片停在偏好位置；
    // 横屏键盘高 → 这一条会同时把卡片往上推、把高度压小。没有任何横竖屏分支。
    CGFloat maxBottom = height - kADPanelEdgeGap;
    if (self.keyboardTop > 0.0) {
        maxBottom = MIN(maxBottom, self.keyboardTop - kADPanelEdgeGap);
    }
    CGFloat cardHeight = MIN(preferredHeight, MAX(maxBottom - topLimit, kADPanelKeyboardMinHeight));
    cardHeight = MIN(cardHeight, height - topLimit - kADPanelEdgeGap);

    CGFloat originY = MIN(topLimit + kADPanelTopOffset, maxBottom - cardHeight);
    originY = MAX(topLimit, originY);

    self.dimView.frame = self.view.bounds;

    self.cardView.frame = CGRectMake(originX, originY, cardWidth, cardHeight);
    CGFloat radius = [self resolvedCornerRadius];
    self.cardView.layer.cornerRadius = radius;
    self.cardView.layer.shadowPath =
        [UIBezierPath bezierPathWithRoundedRect:self.cardView.bounds cornerRadius:radius].CGPath;

    self.blurView.frame = self.cardView.bounds;
    self.blurView.layer.cornerRadius = radius;
    self.blurView.layer.masksToBounds = YES;
    self.tintView.frame = self.blurView.contentView.bounds;

    CGFloat cardWidthActual = CGRectGetWidth(self.cardView.bounds);
    CGFloat cardHeightActual = CGRectGetHeight(self.cardView.bounds);
    CGFloat horizontalInset = 8.0;

    CGFloat grabberY = cardHeightActual - kADGrabberInset - kADGrabberHeight;
    self.grabberView.frame = CGRectMake(floor((cardWidthActual - kADGrabberWidth) / 2.0),
                                        grabberY,
                                        kADGrabberWidth,
                                        kADGrabberHeight);

    CGFloat searchY = grabberY - 2.0 - kADSearchHeight;
    self.searchBar.frame = CGRectMake(horizontalInset,
                                      searchY,
                                      cardWidthActual - horizontalInset * 2.0,
                                      kADSearchHeight);

    self.collectionView.frame = CGRectMake(0.0,
                                           kADListTopInset,
                                           cardWidthActual,
                                           MAX(searchY - kADListTopInset, 0.0));
    self.emptyLabel.frame = CGRectInset(self.collectionView.frame, 24.0, 0.0);
}

#pragma mark - 键盘避让（只认键盘顶边，不问方向）

- (void)startObservingKeyboard {
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self
               selector:@selector(handleKeyboardWillChangeFrame:)
                   name:UIKeyboardWillChangeFrameNotification
                 object:nil];
    [center addObserver:self
               selector:@selector(handleKeyboardWillHide:)
                   name:UIKeyboardWillHideNotification
                 object:nil];
}

- (void)handleKeyboardWillChangeFrame:(NSNotification *)notification {
    NSValue *value = notification.userInfo[UIKeyboardFrameEndUserInfoKey];
    if (!value) {
        return;
    }
    CGRect keyboardFrame = [self.view convertRect:[value CGRectValue] fromView:nil];
    CGFloat top = CGRectGetMinY(keyboardFrame);
    if (top >= CGRectGetHeight(self.view.bounds) - 0.5) {
        top = 0.0;
    }
    [self applyKeyboardTop:top userInfo:notification.userInfo];
}

- (void)handleKeyboardWillHide:(NSNotification *)notification {
    [self applyKeyboardTop:0.0 userInfo:notification.userInfo];
}

- (void)applyKeyboardTop:(CGFloat)top userInfo:(NSDictionary *)userInfo {
    if (fabs(self.keyboardTop - top) < 0.5) {
        return;
    }
    self.keyboardTop = top;

    NSNumber *duration = userInfo[UIKeyboardAnimationDurationUserInfoKey];
    NSTimeInterval animationDuration = duration ? duration.doubleValue : 0.25;
    NSNumber *curve = userInfo[UIKeyboardAnimationCurveUserInfoKey];
    UIViewAnimationOptions options = UIViewAnimationOptionBeginFromCurrentState;
    if (curve) {
        options |= (UIViewAnimationOptions)(curve.unsignedIntegerValue << 16);
    }
    if (animationDuration <= 0.01) {
        [self layoutPanel];
        return;
    }
    [UIView animateWithDuration:animationDuration
                          delay:0.0
                        options:options
                     animations:^{
                       [self layoutPanel];
                     }
                     completion:nil];
}

#pragma mark - 输入框

- (void)focusSearchField {
    if (!self.searchBar.window) {
        return;
    }
    [self.view layoutIfNeeded];
    [self.view.window makeKeyWindow];
    [self.searchBar.searchTextField becomeFirstResponder];
    [self.searchBar setShowsCancelButton:YES animated:NO];
}

- (BOOL)isSearchFieldFirstResponder {
    return self.searchBar.searchTextField.isFirstResponder;
}

#pragma mark - 数据

- (void)setApplications:(NSArray<ADAppInfo *> *)applications {
    NSArray<ADAppInfo *> *incoming = applications ?: @[];
    if ([self applications:incoming equalTo:self.allApplications]) {
        return;
    }
    self.allApplications = incoming;
    [self applyFilterResettingOffset:NO];
}

- (BOOL)applications:(NSArray<ADAppInfo *> *)lhs equalTo:(NSArray<ADAppInfo *> *)rhs {
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

- (void)applyFilter {
    [self applyFilterResettingOffset:NO];
}

// 中文输入法在拼音未上屏时，text 属性里通常还看不到这些字母；用 textInRange 取
// 整个文档内容（包含 marked text），才能做到「一边打一边出结果」。
- (NSString *)currentSearchText {
    UITextField *field = self.searchBar.searchTextField;
    NSString *committed = field.text ?: (self.lastDelegateText ?: self.searchBar.text ?: @"");
    NSString *markedText = nil;
    UITextRange *markedRange = field.markedTextRange;
    if (markedRange && !markedRange.isEmpty) {
        markedText = [field textInRange:markedRange];
    }
    if (markedText.length == 0) {
        UITextRange *all = [field textRangeFromPosition:field.beginningOfDocument
                                             toPosition:field.endOfDocument];
        markedText = all ? [field textInRange:all] : nil;
    }
    if (markedText.length == 0) {
        // 最后一道兜底：UIKit 把未上屏内容存在这个私有槽里。
        NSArray<NSString *> *keys = @[@"_markedText", @"markedText", @"_markedTextString"];
        for (NSString *key in keys) {
            @try {
                id value = [field valueForKey:key];
                if ([value isKindOfClass:[NSString class]] && [value length] > 0) {
                    markedText = value;
                    break;
                }
            } @catch (__unused NSException *exception) {
            }
        }
    }
    if (markedText.length == 0) {
        return committed;
    }
    // 两段内容任意包含对方都属于同一份输入，只取较长的一段，避免重复拼接。
    if ([committed containsString:markedText]) {
        return committed;
    }
    if ([markedText containsString:committed]) {
        return markedText;
    }
    return [committed stringByAppendingString:markedText];
}

// 中文输入法在拼音阶段常常不发 textDidChange；编辑期间用 0.15s 轮询兜底，
// 只要输入内容变了就重新筛。
- (void)startQueryPolling {
    [self stopQueryPolling];
    __weak typeof(self) weakSelf = self;
    self.queryPollTimer = [NSTimer scheduledTimerWithTimeInterval:0.15
                                                           repeats:YES
                                                             block:^(NSTimer *_timer) {
        [weakSelf pollQuery];
    }];
}

- (void)stopQueryPolling {
    [self.queryPollTimer invalidate];
    self.queryPollTimer = nil;
}

- (void)pollQuery {
    if (!self.searchBar.isFirstResponder) {
        [self stopQueryPolling];
        return;
    }
    NSString *query = ADNormalizeText([self currentSearchText]);
    if ([query isEqualToString:self.lastAppliedQuery]) {
        return;
    }
    [self applyFilterResettingOffset:YES];
}

- (void)applyFilterResettingOffset:(BOOL)resetsOffset {
    NSString *raw = [self currentSearchText];
    NSString *query = ADNormalizeText(raw);
    BOOL queryChanged = !(self.lastAppliedQuery == nil ? (query.length == 0)
                                                       : [self.lastAppliedQuery isEqualToString:query]);
    self.lastAppliedQuery = query;
    ADQueryDiag([NSString stringWithFormat:@"raw=[%@] norm=[%@]", raw, query]);

    if (query.length == 0) {
        self.filteredApplications = self.allApplications ?: @[];
    } else {
        // 查询按空格/分隔符拆成片段，逐段「包含」即可，不要求整段连贯。
        NSCharacterSet *separator = [NSCharacterSet
            characterSetWithCharactersInString:@" \t\n\r'’-·_"];
        NSArray<NSString *> *parts = [raw componentsSeparatedByCharactersInSet:separator];
        NSMutableArray<NSString *> *tokens = [NSMutableArray array];
        for (NSString *part in parts) {
            NSString *token = ADNormalizeText(part);
            if (token.length > 0) {
                [tokens addObject:token];
            }
        }

        NSMutableArray<ADAppInfo *> *matches = [NSMutableArray array];
        for (ADAppInfo *application in self.allApplications) {
            NSString *keyNorm = ADNormalizeText(application.searchKey);
            BOOL matched = YES;
            for (NSString *token in tokens) {
                if ([keyNorm rangeOfString:token].location == NSNotFound) {
                    matched = NO;
                    break;
                }
            }
            if (matched) {
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

    // 面板挂在上沿，所以从上方落下来。
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
    [self stopQueryPolling];
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
        // 收起方向固定为「向上推」。
        if (translation.y > 0.0 && !_panDidFadeOut) {
            return;
        }
        CGFloat fadeProgress = MIN(MAX(-translation.y / kADFadeOutDistance, 0.0), 1.0);
        if (_panDidFadeOut || fadeProgress >= 1.0) {
            _panDidFadeOut = YES;
            fadeProgress = 1.0;
            translation.y = -kADFadeOutDistance;
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

    BOOL fastDismiss = (recognizer.state == UIGestureRecognizerStateEnded) && !_panDidFadeOut &&
                       translation.y < 0.0 && velocity.y <= -kADFastDismissVelocity;
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
    if (velocity.y >= 0.0 || fabs(velocity.x) >= fabs(velocity.y)) {
        return NO;
    }

    CGPoint location = [gestureRecognizer locationInView:self.cardView];
    if (CGRectContainsPoint(self.collectionView.frame, location)) {
        UIEdgeInsets insets = self.collectionView.adjustedContentInset;
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
    [self.view.window makeKeyWindow];
    [searchBar setShowsCancelButton:YES animated:YES];
    [self startQueryPolling];
}

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    self.lastDelegateText = searchText;
    [self applyFilterResettingOffset:YES];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];
    [self stopQueryPolling];
}

- (void)searchBarCancelButtonClicked:(UISearchBar *)searchBar {
    searchBar.text = @"";
    [searchBar setShowsCancelButton:NO animated:YES];
    [searchBar resignFirstResponder];
    [self stopQueryPolling];
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
    cell.contentView.transform = CGAffineTransformMakeScale(1.0, -1.0);
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
