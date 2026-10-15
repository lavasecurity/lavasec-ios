#import "LavaScrollView.h"
#import <React/RCTComponentViewFactory.h>
#import <React/RCTScrollViewComponentView.h>
#import <react/renderer/components/scrollview/ScrollViewProps.h>

// The pinned RN 0.87.1 owner is verified during workspace preparation. These
// inherited hooks retain Fabric's event dispatch, RTL handling and keyboard
// focus reveal while correcting its raw-inset clamp and cross-fade reset.
@interface RCTScrollViewComponentView (LavaScrollHooks)
- (void)_keyboardWillChangeFrame:(NSNotification *)notification;
- (void)scrollToOffset:(CGPoint)offset animated:(BOOL)animated;
- (void)scrollTo:(double)x y:(double)y animated:(BOOL)animated;
@end

@interface LavaScrollView : RCTScrollViewComponentView
@end

@implementation LavaScrollView {
  BOOL _preservingKeyboardOffset;
  CGFloat _keyboardOffsetY;
}
- (void)_keyboardWillChangeFrame:(NSNotification *)notification {
  CGRect endFrame = [notification.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
  _preservingKeyboardOffset = UIAccessibilityPrefersCrossFadeTransitions() && endFrame.size.height == 0;
  _keyboardOffsetY = self.scrollView.contentOffset.y;
  [super _keyboardWillChangeFrame:notification];
  _preservingKeyboardOffset = NO;
}
- (void)scrollTo:(double)x y:(double)y animated:(BOOL)animated {
  UIScrollView *scroll = self.scrollView;
  // A cross-fade hide must retain the user's offset, not force the page to zero.
  // The final clamp still accounts for the keyboard's newly removed bottom inset.
  CGPoint offset = CGPointMake(x, _preservingKeyboardOffset ? _keyboardOffsetY : y);
  const auto &props = static_cast<const facebook::react::ScrollViewProps &>(*_props);
  if (!props.scrollToOverflowEnabled) {
    UIEdgeInsets insets = scroll.adjustedContentInset;
    CGFloat minX = -insets.left, minY = -insets.top;
    CGFloat maxX = MAX(minX, scroll.contentSize.width - scroll.bounds.size.width + insets.right);
    CGFloat maxY = MAX(minY, scroll.contentSize.height - scroll.bounds.size.height + insets.bottom);
    offset.x = MIN(MAX(offset.x, minX), maxX);
    offset.y = MIN(MAX(offset.y, minY), maxY);
  }
  [self scrollToOffset:offset animated:animated];
}
@end

void LavaInstallScrollScaffold(void) {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    [[RCTComponentViewFactory currentComponentViewFactory] registerComponentViewClass:LavaScrollView.class];
  });
}
