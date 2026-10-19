  // Lava: visible icon + title is a native configured UIButton inside the
  // navigation item's pipeline. UIKit owns intrinsic sizing, the bar's shared
  // background and its transition; no Fabric measurement or extra glass layer.
  // Mode controls keep one native button/canvas in both states. Rasterizing only
  // the selected SF Symbol drops its typographic alignment metadata, so UIKit
  // used to resize/recenter it when the green fill appeared.
  BOOL isMode = dict[@"selected"] != nil && dict[@"sfSymbolName"] != nil;
  if (isMode) {
    BOOL active = [dict[@"selected"] boolValue];
    self.selected = NO;
    self.style = UIBarButtonItemStylePlain;
    UIButtonConfiguration *configuration;
    if (@available(iOS 26.0, *)) {
      self.hidesSharedBackground = YES;
      configuration = active ? [UIButtonConfiguration prominentGlassButtonConfiguration]
                             : [UIButtonConfiguration glassButtonConfiguration];
    } else {
      configuration = active ? [UIButtonConfiguration filledButtonConfiguration]
                             : [UIButtonConfiguration plainButtonConfiguration];
    }
    configuration.baseBackgroundColor = active ? self.tintColor : nil;
    configuration.baseForegroundColor = active ? UIColor.whiteColor : self.tintColor;
    // The 44pt target alone does not size UIKit's glass material. Its default
    // configuration size paints a compressed pill around the fixed glyph.
    configuration.buttonSize = UIButtonConfigurationSizeLarge;
    configuration.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    CGFloat modeInset = (__LAVA_MODE_TARGET__ - __LAVA_MODE_CANVAS__) / 2.0;
    configuration.contentInsets = NSDirectionalEdgeInsetsMake(modeInset, modeInset, modeInset, modeInset);
    UIImage *symbol = [UIImage systemImageNamed:dict[@"sfSymbolName"]
        withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:__LAVA_MODE_GLYPH__
                                                                          weight:UIImageSymbolWeightSemibold]];
    // Use a fixed canvas in both states, including eye/eye.slash's different
    // natural widths. Filled native buttons cannot recolor these resolved pixels.
    CGSize canvas = CGSizeMake(__LAVA_MODE_CANVAS__, __LAVA_MODE_CANVAS__);
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:canvas];
    configuration.image = [[renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
      UIImage *colored = [symbol imageWithTintColor:configuration.baseForegroundColor
                                     renderingMode:UIImageRenderingModeAlwaysOriginal];
      [colored drawAtPoint:CGPointMake((canvas.width - symbol.size.width) / 2,
                                      (canvas.height - symbol.size.height) / 2)];
    }] imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.configuration = configuration;
    button.frame = CGRectMake(0, 0, __LAVA_MODE_TARGET__, __LAVA_MODE_TARGET__);
    [button.widthAnchor constraintEqualToConstant:__LAVA_MODE_TARGET__].active = YES;
    [button.heightAnchor constraintEqualToConstant:__LAVA_MODE_TARGET__].active = YES;
    button.enabled = self.enabled;
    button.accessibilityLabel = self.accessibilityLabel;
    button.accessibilityIdentifier = dict[@"identifier"];
    if (active) button.accessibilityTraits |= UIAccessibilityTraitSelected;
    [button addTarget:self action:@selector(handleBarButtonItemPress:) forControlEvents:UIControlEventTouchUpInside];
    self.customView = button;
  }
  // PhoneQAView's NativeToolbarIconButton keeps its explicit foreground even
  // when result availability disables it. Match that bounded native control;
  // ordinary UIBarButtonItem disabled tinting must not wash out its glyph.
  if ([dict[@"identifier"] isEqualToString:@"lava.toolbar.qa.result"]) {
    UIColor *foreground = self.tintColor ?: [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
      return traits.userInterfaceStyle == UIUserInterfaceStyleDark ? UIColor.whiteColor : UIColor.blackColor;
    }];
    UIImage *symbol = [UIImage systemImageNamed:@"info.circle"
        withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:22
                                                                          weight:UIImageSymbolWeightRegular
                                                                           scale:UIImageSymbolScaleMedium]];
    UIButtonConfiguration *configuration;
    if (@available(iOS 26.0, *)) {
      self.hidesSharedBackground = YES;
      configuration = [UIButtonConfiguration glassButtonConfiguration];
    } else {
      configuration = [UIButtonConfiguration plainButtonConfiguration];
    }
    configuration.buttonSize = UIButtonConfigurationSizeLarge;
    configuration.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    configuration.image = symbol;
    configuration.baseForegroundColor = foreground;
    configuration.imageColorTransformer = ^UIColor *(UIColor *color) { return foreground; };
    configuration.contentInsets = NSDirectionalEdgeInsetsMake(
        (__LAVA_MODE_TARGET__ - symbol.size.height) / 2, (__LAVA_MODE_TARGET__ - symbol.size.width) / 2,
        (__LAVA_MODE_TARGET__ - symbol.size.height) / 2, (__LAVA_MODE_TARGET__ - symbol.size.width) / 2);
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.configuration = configuration;
    // Like LavaToolbarSymbol's confirmation image, resolve the actual pixels:
    // UIKit can recolor/reconfigure a symbolic UIImage inside disabled glass.
    // Re-resolve dynamic navigation ink under this button's current traits;
    // retaining a first-mount raster would freeze the wrong appearance.
    __block UIColor *renderedForeground = nil;
    __block CGFloat renderedScale = 0;
    __block UIImage *renderedImage = nil;
    button.configurationUpdateHandler = ^(UIButton *current) {
      [current.traitCollection performAsCurrentTraitCollection:^{
        UIColor *resolved = [foreground resolvedColorWithTraitCollection:current.traitCollection];
        UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
        if (current.traitCollection.displayScale > 0) { format.scale = current.traitCollection.displayScale; }
        BOOL sameForeground = renderedForeground == resolved || [renderedForeground isEqual:resolved];
        if (!renderedImage || !sameForeground || renderedScale != format.scale) {
          UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:symbol.size format:format];
          renderedImage = [[renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
            [[symbol imageWithTintColor:resolved renderingMode:UIImageRenderingModeAlwaysOriginal] drawAtPoint:CGPointZero];
          }] imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
          renderedForeground = resolved;
          renderedScale = format.scale;
          // UIKit may copy/configure its image. Only a changed render key may
          // assign configuration; image identity cannot prove an update is due.
          UIButtonConfiguration *updated = current.configuration;
          updated.image = renderedImage;
          current.configuration = updated;
        }
      }];
    };
    if (@available(iOS 17.0, *)) {
      [button registerForTraitChanges:@[UITraitUserInterfaceStyle.class, UITraitAccessibilityContrast.class, UITraitDisplayScale.class]
          withHandler:^(id<UITraitEnvironment> environment, UITraitCollection *previousTraits) {
            [(UIButton *)environment setNeedsUpdateConfiguration];
          }];
    }
    [button setNeedsUpdateConfiguration];
    button.enabled = self.enabled;
    button.accessibilityLabel = self.accessibilityLabel;
    button.accessibilityIdentifier = dict[@"identifier"];
    [button.widthAnchor constraintEqualToConstant:__LAVA_MODE_TARGET__].active = YES;
    [button.heightAnchor constraintEqualToConstant:__LAVA_MODE_TARGET__].active = YES;
    [button addTarget:self action:@selector(handleBarButtonItemPress:) forControlEvents:UIControlEventTouchUpInside];
    self.customView = button;
  }
  // Confirmation actions retain their existing platform-owned sizing.
  if (!isMode && [dict[@"variant"] isEqualToString:@"prominent"] &&
      [dict[@"sfSymbolName"] isEqualToString:@"checkmark"]) {
    UIImage *symbol = [self.image imageWithTintColor:UIColor.whiteColor renderingMode:UIImageRenderingModeAlwaysOriginal];
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:symbol.size];
    self.image = [[renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
      [symbol drawAtPoint:CGPointZero];
    }] imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
  }
  BOOL needsProminentFallback = NO;
  if (@available(iOS 26.0, *)) {} else {
    needsProminentFallback = [dict[@"variant"] isEqualToString:@"prominent"];
  }
  if (!isMode && ([dict[@"identifier"] hasPrefix:@"lava.toolbar.labeled."] || needsProminentFallback)) {
    UIButtonConfiguration *configuration = needsProminentFallback
        ? [UIButtonConfiguration filledButtonConfiguration] : [UIButtonConfiguration plainButtonConfiguration];
    if (needsProminentFallback) {
      configuration.baseBackgroundColor = self.tintColor;
      configuration.baseForegroundColor = UIColor.whiteColor;
      configuration.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
      configuration.contentInsets = NSDirectionalEdgeInsetsMake(10, 12, 10, 12);
    }
    configuration.title = self.title;
    configuration.image = self.image;
    configuration.imagePadding = 6;
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.configuration = configuration;
    button.tintColor = self.tintColor;
    button.enabled = self.enabled;
    button.accessibilityLabel = self.accessibilityLabel;
    button.accessibilityIdentifier = dict[@"identifier"];
    if ([dict[@"selected"] boolValue]) button.accessibilityTraits |= UIAccessibilityTraitSelected;
    button.titleLabel.adjustsFontForContentSizeCategory = YES;
    [button addTarget:self action:@selector(handleBarButtonItemPress:) forControlEvents:UIControlEventTouchUpInside];
    self.customView = button;
  }
  // Lava: end native labeled toolbar item.
