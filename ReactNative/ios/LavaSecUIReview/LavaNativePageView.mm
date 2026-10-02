#import "LavaNativePageView.h"
#import <react/renderer/components/LavaUIReviewSpec/ComponentDescriptors.h>
#import <react/renderer/components/LavaUIReviewSpec/Props.h>
#import <react/renderer/components/LavaUIReviewSpec/EventEmitters.h>
#if LAVA_REACT_NATIVE
#import <AuthenticationServices/AuthenticationServices.h>
#import <UserNotifications/UserNotifications.h>
#import <AVFoundation/AVFoundation.h>
#import "LavaSecUIReview-Swift.h"
#endif

using namespace facebook::react;

@implementation LavaNativePageView
+ (ComponentDescriptorProvider)componentDescriptorProvider {
  return concreteComponentDescriptorProvider<LavaNativePageComponentDescriptor>();
}
- (instancetype)initWithFrame:(CGRect)frame {
  if (self = [super initWithFrame:frame]) {
    _props = std::make_shared<const LavaNativePageProps>();
#if LAVA_REACT_NATIVE
    LavaNativePageContent *page = [LavaNativePageContent new];
    __weak LavaNativePageView *weakSelf = self;
    page.onBack = ^{ [weakSelf emitBack]; };
    page.onNavigate = ^(NSString *destination){ [weakSelf emitNavigate:destination]; };
    self.contentView = page;
#endif
  }
  return self;
}
- (void)emitBack {
  if (_eventEmitter) std::static_pointer_cast<const LavaNativePageEventEmitter>(_eventEmitter)->onBack({});
}
- (void)emitNavigate:(NSString *)destination {
  if (_eventEmitter) std::static_pointer_cast<const LavaNativePageEventEmitter>(_eventEmitter)->onNavigate({.destination = destination.UTF8String});
}
- (void)prepareForRecycle {
#if LAVA_REACT_NATIVE
  [(LavaNativePageContent *)self.contentView resetForRecycle];
#endif
  [super prepareForRecycle];
}
- (void)updateProps:(Props::Shared const &)props oldProps:(Props::Shared const &)oldProps {
#if LAVA_REACT_NATIVE
  const auto &next = *std::static_pointer_cast<const LavaNativePageProps>(props);
  [(LavaNativePageContent *)self.contentView configureWithPage:[NSString stringWithUTF8String:next.page.c_str()]];
  [(LavaNativePageContent *)self.contentView setRouteFocused:next.focused];
#endif
  [super updateProps:props oldProps:oldProps];
}
@end
