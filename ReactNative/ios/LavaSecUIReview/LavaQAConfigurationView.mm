#import "LavaQAConfigurationView.h"
#import <react/renderer/components/LavaUIReviewSpec/ComponentDescriptors.h>
#import <react/renderer/components/LavaUIReviewSpec/Props.h>
#if LAVA_REACT_NATIVE
#import <AuthenticationServices/AuthenticationServices.h>
#import <UserNotifications/UserNotifications.h>
#import <AVFoundation/AVFoundation.h>
#import "LavaSecUIReview-Swift.h"
#endif
using namespace facebook::react;
@implementation LavaQAConfigurationView
+ (ComponentDescriptorProvider)componentDescriptorProvider { return concreteComponentDescriptorProvider<LavaQAConfigurationComponentDescriptor>(); }
- (instancetype)initWithFrame:(CGRect)frame {
  if (self = [super initWithFrame:frame]) {
    _props = std::make_shared<const LavaQAConfigurationProps>();
#if LAVA_REACT_NATIVE
    self.contentView = [LavaQAConfigurationContent new];
#endif
  }
  return self;
}
- (void)prepareForRecycle {
#if LAVA_REACT_NATIVE
  [(LavaQAConfigurationContent *)self.contentView resetForRecycle];
#endif
  [super prepareForRecycle];
}
- (void)updateProps:(Props::Shared const &)props oldProps:(Props::Shared const &)oldProps {
#if LAVA_REACT_NATIVE
  const auto &next = *std::static_pointer_cast<const LavaQAConfigurationProps>(props);
  [(LavaQAConfigurationContent *)self.contentView configureWithOwnerID:[NSString stringWithUTF8String:next.ownerID.c_str()] fontSize:next.fontSize];
#endif
  [super updateProps:props oldProps:oldProps];
}
@end
