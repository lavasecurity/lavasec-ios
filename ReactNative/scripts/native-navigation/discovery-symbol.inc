// Lava: discovery symbol adapter. Use public UIImage composition rather than UIKit's
// minimum-size badge or private tab-bar subviews. The wire name carries scaffold colors.
static UIImage *LavaDiscoverySymbol(NSString *name)
{
  if (![name hasPrefix:@"lava.discovery|"]) return [UIImage systemImageNamed:name];
  NSArray<NSString *> *parts = [name componentsSeparatedByString:@"|"];
  if (parts.count != 4) return nil;
  UIColor *(^color)(NSString *) = ^UIColor *(NSString *hex) {
    unsigned int rgb = 0;
    [[NSScanner scannerWithString:hex] scanHexInt:&rgb];
    return [UIColor colorWithRed:((rgb >> 16) & 255) / 255.0
                           green:((rgb >> 8) & 255) / 255.0
                            blue:(rgb & 255) / 255.0 alpha:1];
  };
  UIImage *symbol = [[UIImage systemImageNamed:parts[1]
                            withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:24
                                                                                              weight:UIImageSymbolWeightRegular]]
      imageWithTintColor:color(parts[2]) renderingMode:UIImageRenderingModeAlwaysOriginal];
  if (symbol == nil) return nil;
  // Six points, solid orange, no text. Keep the symbol's aspect ratio intact.
  CGSize canvas = CGSizeMake(30, 28);
  CGFloat scale = MIN(24 / symbol.size.width, 24 / symbol.size.height);
  CGSize size = CGSizeMake(symbol.size.width * scale, symbol.size.height * scale);
  UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:canvas];
  UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
    [symbol drawInRect:CGRectMake((26 - size.width) / 2, (28 - size.height) / 2, size.width, size.height)];
    [color(parts[3]) setFill];
    [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(24, 0, 6, 6)] fill];
  }];
  return [image imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
}
// Lava: end discovery symbol adapter.

