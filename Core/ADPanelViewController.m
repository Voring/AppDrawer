#import "ADPanelViewController.h"

#import <QuartzCore/QuartzCore.h>

#import "ADAppCell.h"
#import "ADAppInfo.h"
#import "ADPrefs.h"

static NSString *const ADAppCellReuseIdentifier = @"ADAppCell";

@interface ADPanelViewController () <UISearchBarDelegate, UICollectionViewDataSource,
                                     UICollectionViewDelegateFlowLayout>

@property (nonatomic, strong) UIView *dimView;
@property (nonatomic, strong) UIView *cardView;
@property (nonatomic, strong) UIVisualEffectView *blurView;
@property (nonatomic, strong) UISearchBar *searchBar;
@property (nonatomic, strong) UICollectionView *collectionView;
@property (nonatomic, strong) UILabel *emptyLabel;

@property (nonatomic, copy) NSArray<ADAppInfo *> *allApplications;
@property (nonatomic, copy) NSArray<ADAppInfo *> *filteredApplications;

@end

@implementation ADPanelViewController

#pragma mark - 生命周期

- (void)viewDidLoad {
    [super viewDidLoad];

    self.view.backgroundColor = [UIColor clearColor];

    _dimView = [[UIView alloc] init];
    _dimView.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.35];
    [_dimView addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self
                                                                          action:@selector(handleBackgroundTap)]];
    [self.view addSubview:_dimView];

    _cardView = [[UIView alloc] init];
    _cardView.clipsToBounds = YES;
    _cardView.layer.cornerCurve = kCACornerCurveContinuous;
    _cardView.layer.maskedCorners = kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner;
    [self.view addSubview:_cardView];

    _blurView = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:ADPrefBlurStyle()]];
    [_cardView addSubview:_blurView];

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

    [self applyFilter];
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

#pragma mark - 布局

- (void)layoutPanel {
    CGFloat width = CGRectGetWidth(self.view.bounds);
    CGFloat height = CGRectGetHeight(self.view.bounds);
    if (width <= 0.0 || height <= 0.0) {
        return;
    }

    CGFloat cardHeight = floor(height * ADPrefPanelHeightPercent());
    cardHeight = MAX(cardHeight, 320.0);
    cardHeight = MIN(cardHeight, height - 56.0);

    self.dimView.frame = self.view.bounds;

    self.cardView.frame = CGRectMake(0.0, 0.0, width, cardHeight);
    self.cardView.layer.cornerRadius = ADPrefPanelCornerRadius();

    self.blurView.frame = self.cardView.bounds;

    CGFloat topInset = MAX(self.view.safeAreaInsets.top, 20.0);
    CGFloat horizontalInset = 12.0;
    self.searchBar.frame = CGRectMake(horizontalInset,
                                      topInset + 2.0,
                                      width - horizontalInset * 2.0,
                                      48.0);

    CGFloat listTop = CGRectGetMaxY(self.searchBar.frame) + 2.0;
    self.collectionView.frame = CGRectMake(0.0,
                                           listTop,
                                           width,
                                           cardHeight - listTop - 6.0);
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
    self.allApplications = applications ?: @[];
    [self applyFilter];
}

- (void)setQuery:(NSString *)query {
    self.searchBar.text = query ?: @"";
    [self applyFilter];
}

- (NSString *)_normalizedQuery {
    NSString *raw = self.searchBar.text ?: @"";
    NSString *trimmed = [raw stringByTrimmingCharactersInSet:
                                   [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return [trimmed lowercaseString];
}

- (void)applyFilter {
    NSString *query = [self _normalizedQuery];

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

    if (self.filteredApplications.count > 0) {
        [self.collectionView setContentOffset:CGPointMake(0.0, -self.collectionView.contentInset.top)
                                      animated:NO];
    }
}

#pragma mark - 动画

- (void)animateIn {
    [self.view layoutIfNeeded];

    self.dimView.alpha = 0.0;
    self.cardView.alpha = 0.0;
    self.cardView.transform = CGAffineTransformMakeTranslation(0.0, -CGRectGetHeight(self.cardView.bounds) * 0.22);

    [UIView animateWithDuration:0.42
                          delay:0.0
         usingSpringWithDamping:0.86
          initialSpringVelocity:0.35
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
                       self.dimView.alpha = 1.0;
                       self.cardView.alpha = 1.0;
                       self.cardView.transform = CGAffineTransformIdentity;
                     }
                     completion:nil];
}

- (void)animateOutWithCompletion:(void (^)(void))completion {
    [self.view endEditing:YES];

    [UIView animateWithDuration:0.20
        delay:0.0
        options:UIViewAnimationOptionCurveEaseIn
        animations:^{
          self.dimView.alpha = 0.0;
          self.cardView.alpha = 0.0;
          self.cardView.transform = CGAffineTransformMakeTranslation(0.0, -30.0);
        }
        completion:^(__unused BOOL finished) {
          self.cardView.transform = CGAffineTransformIdentity;
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

#pragma mark - UISearchBarDelegate

- (void)searchBarTextDidBeginEditing:(UISearchBar *)searchBar {
    // SpringBoard 会不时把自己的主窗口抢回 key window，这里再抢一次保证键盘有落点。
    [self.view.window makeKeyWindow];
    [searchBar setShowsCancelButton:YES animated:YES];
}

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    [self applyFilter];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];
}

- (void)searchBarCancelButtonClicked:(UISearchBar *)searchBar {
    searchBar.text = @"";
    [searchBar setShowsCancelButton:NO animated:YES];
    [searchBar resignFirstResponder];
    [self applyFilter];
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
