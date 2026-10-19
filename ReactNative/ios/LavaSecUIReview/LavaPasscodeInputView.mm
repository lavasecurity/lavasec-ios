#import "LavaPasscodeInputView.h"
#import <react/renderer/components/LavaUIReviewSpec/ComponentDescriptors.h>
#import <react/renderer/components/LavaUIReviewSpec/Props.h>
#if LAVA_REACT_NATIVE
#import <AuthenticationServices/AuthenticationServices.h>
#import <UserNotifications/UserNotifications.h>
#import <AVFoundation/AVFoundation.h>
#import "LavaSecUIReview-Swift.h"
#endif
using namespace facebook::react;
@implementation LavaPasscodeInputView
+ (ComponentDescriptorProvider)componentDescriptorProvider { return concreteComponentDescriptorProvider<LavaPasscodeInputComponentDescriptor>(); }
- (instancetype)initWithFrame:(CGRect)frame {
  if (self = [super initWithFrame:frame]) {
    _props = std::make_shared<const LavaPasscodeInputProps>();
#if LAVA_REACT_NATIVE
    self.contentView = [LavaPasscodeInputContent new];
#endif
  }
  return self;
}
- (void)prepareForRecycle {
#if LAVA_REACT_NATIVE
  [(LavaPasscodeInputContent *)self.contentView resetForRecycle];
#endif
  [super prepareForRecycle];
}
- (void)updateProps:(Props::Shared const &)props oldProps:(Props::Shared const &)oldProps {
#if LAVA_REACT_NATIVE
  const auto &next = *std::static_pointer_cast<const LavaPasscodeInputProps>(props);
  [(LavaPasscodeInputContent *)self.contentView configureWithOwnerID:[NSString stringWithUTF8String:next.ownerID.c_str()] kind:[NSString stringWithUTF8String:next.kind.c_str()]];
#endif
  [super updateProps:props oldProps:oldProps];
}
@end
