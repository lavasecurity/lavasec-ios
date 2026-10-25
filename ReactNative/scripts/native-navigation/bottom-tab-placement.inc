// Lava: native bottom tabs on iPad.
static void LavaUpdateBottomTabPlacement(RNSTabBarController *controller)
{
  if (@available(iOS 18.0, *)) {
    if (controller.traitCollection.userInterfaceIdiom != UIUserInterfaceIdiomPad) return;

    // Read outside the tab controller's override. Content keeps the actual
    // window/container size class, including narrow multitasking windows.
    UITraitCollection *containerTraits = controller.parentViewController.traitCollection;
    if (containerTraits == nil) containerTraits = controller.viewIfLoaded.window.traitCollection;
    UIUserInterfaceSizeClass contentSizeClass = containerTraits.horizontalSizeClass;
    if (contentSizeClass == UIUserInterfaceSizeClassUnspecified) return;

    // UIKit owns the bar, its material, item layout and bottom safe-area inset.
    // Limit the compact trait to this navigation container, not its pages.
    if (![controller.traitOverrides containsTrait:UITraitHorizontalSizeClass.class] ||
        controller.traitOverrides.horizontalSizeClass != UIUserInterfaceSizeClassCompact) {
      controller.traitOverrides.horizontalSizeClass = UIUserInterfaceSizeClassCompact;
    }
    for (UIViewController *child in controller.viewControllers) {
      if (![child.traitOverrides containsTrait:UITraitHorizontalSizeClass.class] ||
          child.traitOverrides.horizontalSizeClass != contentSizeClass) {
        child.traitOverrides.horizontalSizeClass = contentSizeClass;
      }
    }
  }
}
// Lava: end native bottom tabs on iPad.
