#import "LavaControlTrackingGuard.h"
#import <UIKit/UIGestureRecognizerSubclass.h>

@interface LavaPanContactLease : NSObject
@property(nonatomic) NSUInteger count;
@property(nonatomic) BOOL originalEnabled;
@end
@implementation LavaPanContactLease
@end

@implementation LavaControlTrackingGuard {
  __weak UIPanGestureRecognizer *_pan;
  LavaPanContactLease *_lease;
}
- (instancetype)init {
  if ((self = [super initWithTarget:nil action:nil])) {
    self.cancelsTouchesInView = NO;
    self.delaysTouchesBegan = NO;
    self.delaysTouchesEnded = NO;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(cancelTracking) name:UIApplicationWillResignActiveNotification object:nil];
  }
  return self;
}
// All native controls lease the same ancestor state. Ending one contact must
// neither enable another contact's pan nor restore an already-disabled value.
// Suspend only the gesture: changing UIScrollView.scrollEnabled during a mascot
// tap can let UIKit re-evaluate large-title/inset tracking and move the page.
+ (NSMapTable<UIPanGestureRecognizer *, LavaPanContactLease *> *)leases {
  static NSMapTable *leases;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ leases = [NSMapTable weakToStrongObjectsMapTable]; });
  return leases;
}
- (void)releasePan {
  if (!_lease) return;
  if (--_lease.count == 0 && _pan) {
    _pan.enabled = _lease.originalEnabled;
    [[LavaControlTrackingGuard leases] removeObjectForKey:_pan];
  }
  _lease = nil;
  _pan = nil;
}
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
  if (_lease) return;
  UIView *ancestor = self.view.superview;
  while (ancestor && ![ancestor isKindOfClass:UIScrollView.class]) ancestor = ancestor.superview;
  _pan = ((UIScrollView *)ancestor).panGestureRecognizer;
  if (!_pan) return;
  _lease = [[LavaControlTrackingGuard leases] objectForKey:_pan];
  if (!_lease) {
    _lease = [LavaPanContactLease new];
    _lease.originalEnabled = _pan.enabled;
    [[LavaControlTrackingGuard leases] setObject:_lease forKey:_pan];
  }
  _lease.count++;
  _pan.enabled = NO;
}
- (void)cancelTracking {
  BOOL enabled = self.enabled;
  self.enabled = NO;
  self.enabled = enabled;
}
- (void)dealloc { [self releasePan]; [[NSNotificationCenter defaultCenter] removeObserver:self]; }
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { self.state = UIGestureRecognizerStateFailed; }
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { self.state = UIGestureRecognizerStateFailed; }
- (BOOL)canPreventGestureRecognizer:(UIGestureRecognizer *)other { return NO; }
- (BOOL)canBePreventedByGestureRecognizer:(UIGestureRecognizer *)other { return NO; }
- (void)reset {
  [self releasePan];
  [super reset];
}
@end
