#import "LavaBackupCredentialsView.h"
#import <react/renderer/components/LavaUIReviewSpec/ComponentDescriptors.h>
#import <react/renderer/components/LavaUIReviewSpec/EventEmitters.h>
#import <react/renderer/components/LavaUIReviewSpec/Props.h>
#if LAVA_REACT_NATIVE
#import <AuthenticationServices/AuthenticationServices.h>
#import <UserNotifications/UserNotifications.h>
#endif
#import <AVFoundation/AVFoundation.h>
#import "LavaSecUIReview-Swift.h"
using namespace facebook::react;
@implementation LavaBackupCredentialsView {
#if LAVA_REACT_NATIVE
  LavaBackupCredentialsContent *_credentials;
#endif
}
+ (ComponentDescriptorProvider)componentDescriptorProvider { return concreteComponentDescriptorProvider<LavaBackupCredentialsComponentDescriptor>(); }
- (instancetype)initWithFrame:(CGRect)frame {
  if (self = [super initWithFrame:frame]) {
    _props = std::make_shared<const LavaBackupCredentialsProps>();
#if LAVA_REACT_NATIVE
    _credentials = [LavaBackupCredentialsContent new];
    __weak LavaBackupCredentialsView *weakSelf = self;
    _credentials.sizeChanged = ^(CGFloat height) {
      LavaBackupCredentialsView *strongSelf = weakSelf;
      if (strongSelf && strongSelf->_eventEmitter) std::static_pointer_cast<const LavaBackupCredentialsEventEmitter>(strongSelf->_eventEmitter)->onSizeChange({.height = (float)height});
    };
    self.contentView = _credentials;
#endif
  }
  return self;
}
- (void)updateProps:(Props::Shared const &)props oldProps:(Props::Shared const &)oldProps {
  const auto &next = *std::static_pointer_cast<const LavaBackupCredentialsProps>(props);
#if LAVA_REACT_NATIVE
  [_credentials configureWithOwnerID:[NSString stringWithUTF8String:next.ownerID.c_str()] mode:[NSString stringWithUTF8String:next.mode.c_str()]];
#endif
  [super updateProps:props oldProps:oldProps];
}
- (void)prepareForRecycle {
#if LAVA_REACT_NATIVE
  [_credentials resetForRecycle];
#endif
  [super prepareForRecycle];
}
@end
