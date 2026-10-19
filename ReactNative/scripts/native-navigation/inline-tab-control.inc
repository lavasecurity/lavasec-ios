// Lava: inline iPad tab control. UIKit still owns navigation.
#import <objc/runtime.h>

@interface LavaInlineTabButton : UIButton
@property (nonatomic, copy) NSDictionary *lavaConfigurationSignature;
@end
@implementation LavaInlineTabButton
@end

@interface LavaInlineTabControl : UIView
@property (nonatomic, weak) RNSTabBarController *owner;
@property (nonatomic, strong) UIVisualEffectView *materialView;
@property (nonatomic, strong) UIStackView *buttonStack;
@property (nonatomic, copy) NSArray<UIViewController *> *controllers;
@property (nonatomic, strong) NSMutableArray<LavaInlineTabButton *> *buttons;
@property (nonatomic, strong) UIFont *labelFont;
@property (nonatomic, copy) UIContentSizeCategory fontCategory;
@property (nonatomic) CGFloat appliedTopInset;
@property (nonatomic) BOOL updating;
@property (nonatomic) BOOL materialConfigured;
@property (nonatomic) BOOL reducedTransparency;
@property (nonatomic) UIUserInterfaceStyle materialStyle;
- (void)updateForController:(RNSTabBarController *)controller;
@end

@implementation LavaInlineTabControl

- (instancetype)initWithFrame:(CGRect)frame
{
  if (self = [super initWithFrame:frame]) {
    self.hidden = YES;
    self.isAccessibilityElement = NO;
    self.accessibilityTraits = UIAccessibilityTraitTabBar;
    self.accessibilityContainerType = UIAccessibilityContainerTypeSemanticGroup;
    self.shouldGroupAccessibilityChildren = YES;
    self.accessibilityIdentifier = @"lava.inline-tab-control";
    _controllers = @[];
    _buttons = [NSMutableArray new];
    _materialView = [[UIVisualEffectView alloc] initWithEffect:nil];
    _materialView.userInteractionEnabled = NO;
    _materialView.clipsToBounds = YES;
    [self addSubview:_materialView];
    _buttonStack = [[UIStackView alloc] initWithFrame:CGRectZero];
    _buttonStack.axis = UILayoutConstraintAxisHorizontal;
    _buttonStack.alignment = UIStackViewAlignmentFill;
    _buttonStack.distribution = UIStackViewDistributionFillProportionally;
    _buttonStack.spacing = 0;
    [self addSubview:_buttonStack];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(reduceTransparencyChanged:)
                                                 name:UIAccessibilityReduceTransparencyStatusDidChangeNotification
                                               object:nil];
  }
  return self;
}

- (void)dealloc
{
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)reduceTransparencyChanged:(NSNotification *)notification
{
  RNSTabBarController *owner = self.owner;
  if (owner != nil) [self updateForController:owner];
}

- (void)layoutSubviews
{
  [super layoutSubviews];
  self.materialView.frame = self.bounds;
  self.buttonStack.frame = UIEdgeInsetsInsetRect(self.bounds, UIEdgeInsetsMake(2, 4, 2, 4));
  if (@available(iOS 26.0, *)) {
    self.materialView.cornerConfiguration = [UICornerConfiguration capsuleConfiguration];
  } else {
    self.materialView.layer.cornerRadius = CGRectGetHeight(self.bounds) / 2;
  }
}

- (void)updateMaterial
{
  BOOL reduced = UIAccessibilityIsReduceTransparencyEnabled();
  UIUserInterfaceStyle style = self.owner.traitCollection.userInterfaceStyle;
  if (self.materialConfigured && self.reducedTransparency == reduced && self.materialStyle == style) return;
  self.materialConfigured = YES;
  self.reducedTransparency = reduced;
  self.materialStyle = style;
  if (reduced) {
    self.materialView.effect = nil;
    self.materialView.backgroundColor = UIColor.secondarySystemBackgroundColor;
  } else {
    self.materialView.backgroundColor = UIColor.clearColor;
    if (@available(iOS 26.0, *)) {
      UIGlassEffect *effect = [UIGlassEffect effectWithStyle:UIGlassEffectStyleRegular];
      effect.interactive = NO;
      self.materialView.effect = effect;
    } else {
      self.materialView.effect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial];
    }
  }
}

- (void)rebuildButtonsIfNeeded:(NSArray<UIViewController *> *)controllers
{
  if ([self.controllers isEqualToArray:controllers]) return;
  self.controllers = controllers;
  for (UIButton *button in self.buttons) {
    [self.buttonStack removeArrangedSubview:button];
    [button removeFromSuperview];
  }
  [self.buttons removeAllObjects];
  for (NSUInteger index = 0; index < controllers.count; index++) {
    LavaInlineTabButton *button = [LavaInlineTabButton buttonWithType:UIButtonTypeSystem];
    button.tag = index;
    button.titleLabel.adjustsFontForContentSizeCategory = YES;
    [button addTarget:self action:@selector(selectTab:) forControlEvents:UIControlEventTouchUpInside];
    [self.buttons addObject:button];
    [self.buttonStack addArrangedSubview:button];
  }
}

- (void)updateButtons
{
  RNSTabBarController *owner = self.owner;
  UIContentSizeCategory category = owner.traitCollection.preferredContentSizeCategory;
  if (self.labelFont == nil || ![self.fontCategory isEqualToString:category]) {
    self.fontCategory = category;
    self.labelFont = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleBody]
        scaledFontForFont:[UIFont systemFontOfSize:17 weight:UIFontWeightMedium]
        compatibleWithTraitCollection:owner.traitCollection];
  }
  UIColor *tint = [owner.tabBar.tintColor resolvedColorWithTraitCollection:owner.traitCollection];
  for (NSUInteger index = 0; index < self.controllers.count; index++) {
    UIViewController *controller = self.controllers[index];
    UITabBarItem *item = controller.tabBarItem;
    LavaInlineTabButton *button = self.buttons[index];
    BOOL selected = owner.selectedViewController == controller;
    NSString *title = controller.title ?: item.title ?: @"";
    UIImage *image = selected ? (item.selectedImage ?: item.image) : item.image;
    NSString *label = item.accessibilityLabel ?: title;
    NSString *identifier = item.accessibilityIdentifier.length > 0
        ? item.accessibilityIdentifier : [NSString stringWithFormat:@"lava.inline-tab.%lu", (unsigned long)index];
    NSDictionary *signature = @{
      @"title": title, @"image": image ?: NSNull.null, @"tint": tint ?: NSNull.null,
      @"font": self.labelFont, @"selected": @(selected), @"enabled": @(item.enabled),
      @"label": label, @"identifier": identifier,
      @"style": @(owner.traitCollection.userInterfaceStyle)
    };
    if ([button.lavaConfigurationSignature isEqualToDictionary:signature]) continue;
    button.lavaConfigurationSignature = signature;
    UIButtonConfiguration *configuration = [UIButtonConfiguration plainButtonConfiguration];
    configuration.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    configuration.contentInsets = NSDirectionalEdgeInsetsMake(6, 16, 6, 16);
    configuration.imagePadding = 6;
    configuration.imagePlacement = NSDirectionalRectEdgeLeading;
    configuration.image = image;
    configuration.preferredSymbolConfigurationForImage =
        [UIImageSymbolConfiguration configurationWithFont:self.labelFont scale:UIImageSymbolScaleMedium];
    UIColor *foreground = selected ? tint : UIColor.labelColor;
    configuration.baseForegroundColor = foreground;
    configuration.attributedTitle = [[NSAttributedString alloc] initWithString:title attributes:@{
      NSFontAttributeName: self.labelFont, NSForegroundColorAttributeName: foreground ?: UIColor.labelColor
    }];
    configuration.background.backgroundColor = selected ? UIColor.systemBackgroundColor : UIColor.clearColor;
    button.configuration = configuration;
    button.selected = selected;
    button.enabled = item.enabled;
    button.accessibilityIdentifier = identifier;
    button.accessibilityLabel = label;
    button.accessibilityTraits = UIAccessibilityTraitButton | (selected ? UIAccessibilityTraitSelected : 0);
  }
}

- (void)selectTab:(UIButton *)sender
{
  RNSTabBarController *owner = self.owner;
  if (owner == nil || sender.tag < 0 || (NSUInteger)sender.tag >= self.controllers.count) return;
  UIViewController *target = self.controllers[(NSUInteger)sender.tag];
  if (![owner.viewControllers containsObject:target]) return;
  id<UITabBarControllerDelegate> delegate = (id<UITabBarControllerDelegate>)owner;
  // Repeats and denied selections are completely handled by shouldSelect. In
  // particular, denial must reach JS's existing protected-Settings auth gate.
  if ([delegate tabBarController:owner shouldSelectViewController:target]) {
    [owner setSelectedViewController:target];
    [delegate tabBarController:owner didSelectViewController:target];
  }
  [self updateForController:owner];
}

- (void)updateForController:(RNSTabBarController *)controller
{
  if (self.updating || !controller.isViewLoaded) return;
  self.updating = YES;
  self.owner = controller;
  BOOL regularPad = NO;
  if (@available(iOS 18.0, *)) {
    regularPad = controller.traitCollection.userInterfaceIdiom == UIUserInterfaceIdiomPad &&
        controller.traitCollection.horizontalSizeClass == UIUserInterfaceSizeClassRegular;
  }
  BOOL hostHidden = controller.tabsHostComponentView.tabBarHidden;
  BOOL visible = regularPad && !hostHidden && controller.viewControllers.count > 1;
  if (@available(iOS 18.0, *)) {
    BOOL nativeHidden = regularPad ? YES : hostHidden;
    if (controller.isTabBarHidden != nativeHidden) [controller setTabBarHidden:nativeHidden animated:NO];
  }
  if (self.hidden == visible) self.hidden = !visible;
  CGFloat nextTopInset = 0;
  if (visible) {
    [self rebuildButtonsIfNeeded:controller.viewControllers];
    UISemanticContentAttribute direction = controller.tabsHostComponentView.layoutDirection == UIUserInterfaceLayoutDirectionRightToLeft
        ? UISemanticContentAttributeForceRightToLeft : UISemanticContentAttributeForceLeftToRight;
    if (self.semanticContentAttribute != direction) {
      self.semanticContentAttribute = direction;
      self.buttonStack.semanticContentAttribute = direction;
    }
    [self updateMaterial];
    [self updateButtons];
    CGFloat height = MAX(48, ceil(self.labelFont.lineHeight + 16));
    nextTopInset = height + 8;
    UIEdgeInsets safe = controller.view.safeAreaInsets;
    CGFloat top = MAX(0, safe.top - self.appliedTopInset) + 4;
    CGFloat availableWidth = MAX(0, CGRectGetWidth(controller.view.bounds) - safe.left - safe.right - 24);
    CGSize natural = [self.buttonStack systemLayoutSizeFittingSize:UILayoutFittingCompressedSize];
    CGFloat width = MIN(availableWidth, natural.width + 8);
    CGRect frame = CGRectMake(safe.left + 12 + (availableWidth - width) / 2, top, width, height);
    if (self.superview != controller.view) [controller.view addSubview:self];
    if (controller.view.subviews.lastObject != self) [controller.view bringSubviewToFront:self];
    if (!CGRectEqualToRect(self.frame, frame)) self.frame = frame;
  }
  if (fabs(nextTopInset - self.appliedTopInset) > 0.01) {
    // Remove precisely our previous delta, retaining insets owned elsewhere.
    UIEdgeInsets insets = controller.additionalSafeAreaInsets;
    insets.top += nextTopInset - self.appliedTopInset;
    self.appliedTopInset = nextTopInset;
    controller.additionalSafeAreaInsets = insets;
  }
  self.updating = NO;
}

@end

static void LavaUpdateInlineTabControl(RNSTabBarController *controller)
{
  if (!controller.isViewLoaded) return;
  static char controlKey;
  LavaInlineTabControl *control = objc_getAssociatedObject(controller, &controlKey);
  if (control == nil) {
    if (@available(iOS 18.0, *)) {
      if (controller.traitCollection.userInterfaceIdiom != UIUserInterfaceIdiomPad ||
          controller.traitCollection.horizontalSizeClass != UIUserInterfaceSizeClassRegular) return;
    } else {
      return;
    }
    control = [[LavaInlineTabControl alloc] initWithFrame:CGRectZero];
    objc_setAssociatedObject(controller, &controlKey, control, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  }
  [control updateForController:controller];
}
// Lava: end inline iPad tab control.
