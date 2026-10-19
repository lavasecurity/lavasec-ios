#import "LavaSystemButtonView.h"
#if LAVA_REACT_NATIVE
#import <AuthenticationServices/AuthenticationServices.h>
#import <UserNotifications/UserNotifications.h>
#import <AVFoundation/AVFoundation.h>
#endif
#import "LavaSecUIReview-Swift.h"
#import <react/renderer/components/LavaUIReviewSpec/ComponentDescriptors.h>
#import <react/renderer/components/LavaUIReviewSpec/EventEmitters.h>
#import <react/renderer/components/LavaUIReviewSpec/Props.h>
using namespace facebook::react;
@implementation LavaSystemButtonView { LavaSystemButtonContent *_button; }
+ (ComponentDescriptorProvider)componentDescriptorProvider { return concreteComponentDescriptorProvider<LavaSystemButtonComponentDescriptor>(); }
- (instancetype)initWithFrame:(CGRect)frame {
  if (self = [super initWithFrame:frame]) {
    _props = std::make_shared<const LavaSystemButtonProps>();
    _button = [LavaSystemButtonContent new];
    __weak LavaSystemButtonView *weakSelf = self;
    _button.onPress = ^(NSString *eventID) {
      LavaSystemButtonView *strongSelf = weakSelf; if (!strongSelf) return;
      auto emitter = std::static_pointer_cast<const LavaSystemButtonEventEmitter>(strongSelf->_eventEmitter);
      if (emitter) emitter->onPress({std::string(eventID.UTF8String ?: "")});
    };
    _button.onSizeChange = ^(double width, double height) {
      LavaSystemButtonView *strongSelf = weakSelf; if (!strongSelf) return;
      auto emitter = std::static_pointer_cast<const LavaSystemButtonEventEmitter>(strongSelf->_eventEmitter);
      if (emitter) emitter->onSizeChange({width,height});
    };
    self.contentView = _button; self.isAccessibilityElement = NO;
  }
  return self;
}
- (void)updateProps:(Props::Shared const &)props oldProps:(Props::Shared const &)oldProps {
  const auto &next = *std::static_pointer_cast<const LavaSystemButtonProps>(props);
  [_button configureWithTitle:[NSString stringWithUTF8String:next.title.c_str()] fontSize:next.fontSize prominent:next.prominent disabled:next.disabled
    destructive:next.destructive eventID:[NSString stringWithUTF8String:next.eventID.c_str()]];
  [super updateProps:props oldProps:oldProps]; self.isAccessibilityElement = NO;
}
- (void)layoutSubviews { [super layoutSubviews]; _button.frame = self.bounds; }
- (void)prepareForRecycle { [_button resetForRecycle]; [super prepareForRecycle]; }
@end
