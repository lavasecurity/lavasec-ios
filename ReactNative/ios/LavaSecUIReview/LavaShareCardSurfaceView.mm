#import "LavaShareCardSurfaceView.h"
#import <react/renderer/components/LavaUIReviewSpec/ComponentDescriptors.h>
#import <react/renderer/components/LavaUIReviewSpec/Props.h>
#if LAVA_REACT_NATIVE
#import <AuthenticationServices/AuthenticationServices.h>
#import <UserNotifications/UserNotifications.h>
#import <AVFoundation/AVFoundation.h>
#endif
#import "LavaSecUIReview-Swift.h"

using namespace facebook::react;

@implementation LavaShareCardSurfaceView
+ (ComponentDescriptorProvider)componentDescriptorProvider {
  return concreteComponentDescriptorProvider<LavaShareCardSurfaceComponentDescriptor>();
}
- (instancetype)initWithFrame:(CGRect)frame {
  if (self = [super initWithFrame:frame]) {
    _props = std::make_shared<const LavaShareCardSurfaceProps>();
    // No contentView replacement: Fabric mounts the shared composer's children.
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;
  }
  return self;
}
- (void)updateProps:(Props::Shared const &)props oldProps:(Props::Shared const &)oldProps {
  [super updateProps:props oldProps:oldProps];
  [self updateExportRegistration];
}
- (void)didMoveToWindow {
  [super didMoveToWindow];
  [self updateExportRegistration];
}
- (void)updateExportRegistration {
  const auto &props = *std::static_pointer_cast<const LavaShareCardSurfaceProps>(_props);
  [[LavaShareCardSurfaceRegistry shared] updateWithView:self
      token:[NSString stringWithUTF8String:props.token.c_str()]
      payload:[NSString stringWithUTF8String:props.payload.c_str()] ready:props.ready];
}
- (void)prepareForRecycle {
  [[LavaShareCardSurfaceRegistry shared] removeWithView:self];
  [super prepareForRecycle];
}
@end
