#import "NativeControlTrackingTests.h"
#import "../../ios/LavaSecUIReview/LavaControlTrackingGuard.h"
#import <UIKit/UIGestureRecognizerSubclass.h>

// Observe property writes as well as geometry: setting scrollEnabled to its
// existing value can still involve UIKit's navigation/inset bookkeeping.
@interface ObservedScrollView : UIScrollView
@property(nonatomic) NSUInteger enabledWrites;
@property(nonatomic) NSUInteger offsetWrites;
@property(nonatomic) NSUInteger insetWrites;
@end
@implementation ObservedScrollView
- (void)setScrollEnabled:(BOOL)value { self.enabledWrites++; [super setScrollEnabled:value]; }
- (void)setContentOffset:(CGPoint)value { self.offsetWrites++; [super setContentOffset:value]; }
- (void)setContentInset:(UIEdgeInsets)value { self.insetWrites++; [super setContentInset:value]; }
@end

NSDictionary<NSString *, NSNumber *> *LavaControlTrackingChecks(void) {
  UIEvent *event = [UIEvent new];
  NSMutableDictionary *checks = [NSMutableDictionary new];
  ObservedScrollView *scroll = [[ObservedScrollView alloc] initWithFrame:CGRectMake(0, 0, 390, 680)];
  scroll.contentSize = CGSizeMake(390, 1600);
  scroll.contentInset = UIEdgeInsetsMake(96, 0, 34, 0);
  UIView *mascot = [[UIView alloc] initWithFrame:CGRectMake(180, 80, 160, 160)];
  [scroll addSubview:mascot];
  LavaControlTrackingGuard *first = [LavaControlTrackingGuard new];
  LavaControlTrackingGuard *second = [LavaControlTrackingGuard new];
  [mascot addGestureRecognizer:first];
  [mascot addGestureRecognizer:second];
  for (NSNumber *position in @[@(-96), @0, @240, @954]) {
    scroll.contentOffset = CGPointMake(0, position.doubleValue);
    CGPoint offset = scroll.contentOffset;
    UIEdgeInsets inset = scroll.contentInset;
    scroll.enabledWrites = scroll.offsetWrites = scroll.insetWrites = 0;
    [first touchesBegan:[NSSet set] withEvent:event];
    checks[[NSString stringWithFormat:@"contact at %@ suspends only the pan gesture", position]] = @(!scroll.panGestureRecognizer.enabled && scroll.scrollEnabled);
    checks[[NSString stringWithFormat:@"contact at %@ retains page geometry", position]] = @(CGPointEqualToPoint(scroll.contentOffset, offset) && UIEdgeInsetsEqualToEdgeInsets(scroll.contentInset, inset));
    [first reset];
    checks[[NSString stringWithFormat:@"release at %@ restores the pan without scrolling", position]] = @(scroll.panGestureRecognizer.enabled && scroll.scrollEnabled && CGPointEqualToPoint(scroll.contentOffset, offset));
    checks[[NSString stringWithFormat:@"tap at %@ never writes page scroll state", position]] = @(scroll.enabledWrites == 0 && scroll.offsetWrites == 0 && scroll.insetWrites == 0);
  }
  [first touchesBegan:[NSSet set] withEvent:event];
  [second touchesBegan:[NSSet set] withEvent:event];
  [first reset];
  checks[@"overlapping contacts retain the other owner's pan lock"] = @(!scroll.panGestureRecognizer.enabled);
  [second reset];
  checks[@"last contact restores the original pan state"] = @(scroll.panGestureRecognizer.enabled);
  scroll.panGestureRecognizer.enabled = NO;
  [first touchesBegan:[NSSet set] withEvent:event];
  [first reset];
  checks[@"an already-disabled pan remains disabled"] = @(!scroll.panGestureRecognizer.enabled);
  scroll.scrollEnabled = NO;
  scroll.enabledWrites = 0;
  [first touchesBegan:[NSSet set] withEvent:event];
  [first reset];
  checks[@"an already-disabled page is never enabled by a contact"] = @(!scroll.scrollEnabled && scroll.enabledWrites == 0);
  scroll.scrollEnabled = YES;
  scroll.panGestureRecognizer.enabled = YES;
  CGPoint offset = scroll.contentOffset;
  [first touchesBegan:[NSSet set] withEvent:event];
  [[NSNotificationCenter defaultCenter] postNotificationName:UIApplicationWillResignActiveNotification object:nil];
  // UIKit invokes reset when disabling a recognizer; also exercise explicit
  // reset here, as cancellation/recycling may repeat it after the notification.
  [first reset];
  checks[@"background cancellation restores pan without changing offset"] = @(scroll.panGestureRecognizer.enabled && CGPointEqualToPoint(scroll.contentOffset, offset));
  [first touchesBegan:[NSSet set] withEvent:event];
  first.enabled = NO;
  [first reset];
  checks[@"recycling a gesture owner restores pan without changing offset"] = @(scroll.panGestureRecognizer.enabled && CGPointEqualToPoint(scroll.contentOffset, offset));
  return checks;
}
