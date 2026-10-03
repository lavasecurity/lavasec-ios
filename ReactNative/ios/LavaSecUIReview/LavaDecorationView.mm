#import "LavaDecorationView.h"
#import "LavaChoiceView.h"
#import <react/renderer/components/LavaUIReviewSpec/ComponentDescriptors.h>
#import <react/renderer/components/LavaUIReviewSpec/Props.h>
#import <react/renderer/components/LavaUIReviewSpec/EventEmitters.h>
#if LAVA_REACT_NATIVE
#import <AuthenticationServices/AuthenticationServices.h>
#import <UserNotifications/UserNotifications.h>
#import <AVFoundation/AVFoundation.h>
#endif
#import "LavaSecUIReview-Swift.h"

using namespace facebook::react;

@implementation LavaDecorationView {
  LavaDecorationContent *_decoration;
  LavaControlTrackingGuard *_trackingGuard;
}
+ (ComponentDescriptorProvider)componentDescriptorProvider {
  return concreteComponentDescriptorProvider<LavaDecorationComponentDescriptor>();
}
- (instancetype)initWithFrame:(CGRect)frame {
  if (self = [super initWithFrame:frame]) {
    _props = std::make_shared<const LavaDecorationProps>();
    _decoration = [LavaDecorationContent new];
    _trackingGuard = [LavaControlTrackingGuard new];
    _trackingGuard.enabled = NO;
    [_decoration addGestureRecognizer:_trackingGuard];
    __weak LavaDecorationView *weakSelf = self;
    _decoration.onGuardianGesture = ^(NSString *gesture) {
      [weakSelf emitGuardianGesture:gesture];
    };
    self.contentView = _decoration;
  }
  return self;
}
- (void)emitGuardianGesture:(NSString *)gesture {
  auto emitter = std::static_pointer_cast<const LavaDecorationEventEmitter>(_eventEmitter);
  if (emitter && gesture.UTF8String) emitter->onGuardianGesture({gesture.UTF8String});
}
- (void)updateProps:(Props::Shared const &)props oldProps:(Props::Shared const &)oldProps {
  const auto &next = *std::static_pointer_cast<const LavaDecorationProps>(props);
  [_decoration configureWithSymbol:[NSString stringWithUTF8String:next.symbol.c_str()]
                             mood:[NSString stringWithUTF8String:next.mood.c_str()]
                             look:[NSString stringWithUTF8String:next.look.c_str()]
                             tone:[NSString stringWithUTF8String:next.tone.c_str()]
                      colorScheme:[NSString stringWithUTF8String:next.colorScheme.c_str()]
                    fontPointSize:next.fontPointSize
                       fontWeight:[NSString stringWithUTF8String:next.fontWeight.c_str()]];
  [_decoration configureRevealWithEnabled:next.revealEnabled visible:next.revealVisible
                                       x:next.revealX y:next.revealY radius:next.revealRadius];
  _trackingGuard.enabled = next.guardianGestures;
  [_decoration setGuardianGestures:next.guardianGestures];
  [super updateProps:props oldProps:oldProps];
}
- (void)prepareForRecycle {
  _trackingGuard.enabled = NO;
  [_decoration resetForRecycle];
  [super prepareForRecycle];
}
@end
