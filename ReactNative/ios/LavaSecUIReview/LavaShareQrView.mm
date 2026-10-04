#import "LavaShareQrView.h"
#import <react/renderer/components/LavaUIReviewSpec/ComponentDescriptors.h>
#import <react/renderer/components/LavaUIReviewSpec/Props.h>
#if LAVA_REACT_NATIVE
#import <AuthenticationServices/AuthenticationServices.h>
#import <UserNotifications/UserNotifications.h>
#import <AVFoundation/AVFoundation.h>
#endif
#import "LavaSecUIReview-Swift.h"

using namespace facebook::react;

@implementation LavaShareQrView
+ (ComponentDescriptorProvider)componentDescriptorProvider {
  return concreteComponentDescriptorProvider<LavaShareQrComponentDescriptor>();
}
- (instancetype)initWithFrame:(CGRect)frame {
  if (self = [super initWithFrame:frame]) {
    _props = std::make_shared<const LavaShareQrProps>();
    self.contentView = [LavaShareQrContent new];
  }
  return self;
}
- (void)updateProps:(Props::Shared const &)props oldProps:(Props::Shared const &)oldProps {
  const auto &next = *std::static_pointer_cast<const LavaShareQrProps>(props);
  [(LavaShareQrContent *)self.contentView configureWithPayload:
      [NSString stringWithUTF8String:next.payload.c_str()] moduleCount:next.moduleCount];
  [super updateProps:props oldProps:oldProps];
}
- (void)prepareForRecycle {
  [(LavaShareQrContent *)self.contentView configureWithPayload:@"" moduleCount:0];
  [super prepareForRecycle];
}
@end
