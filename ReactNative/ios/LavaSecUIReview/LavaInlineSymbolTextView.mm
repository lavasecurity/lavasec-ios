#import "LavaInlineSymbolTextView.h"
#import <React/RCTConversions.h>
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
@implementation LavaInlineSymbolTextView { LavaInlineSymbolTextContent *_label; }
+ (ComponentDescriptorProvider)componentDescriptorProvider { return concreteComponentDescriptorProvider<LavaInlineSymbolTextComponentDescriptor>(); }
- (instancetype)initWithFrame:(CGRect)frame {
  if (self = [super initWithFrame:frame]) {
    _props = std::make_shared<const LavaInlineSymbolTextProps>();
    _label = [LavaInlineSymbolTextContent new];
    __weak LavaInlineSymbolTextView *weakSelf = self;
    _label.onSizeChange = ^(NSString *measurementID, double width, double height) {
      LavaInlineSymbolTextView *strongSelf = weakSelf; if (!strongSelf) return;
      auto emitter = std::static_pointer_cast<const LavaInlineSymbolTextEventEmitter>(strongSelf->_eventEmitter);
      if (emitter) emitter->onSizeChange({std::string(measurementID.UTF8String ?: ""),width,height});
    };
    self.contentView = _label; self.isAccessibilityElement = NO;
  }
  return self;
}
- (void)updateProps:(Props::Shared const &)props oldProps:(Props::Shared const &)oldProps {
  const auto &next = *std::static_pointer_cast<const LavaInlineSymbolTextProps>(props);
  [_label configureWithTitle:[NSString stringWithUTF8String:next.title.c_str()]
    symbol:[NSString stringWithUTF8String:next.symbol.c_str()]
    tintColor:RCTUIColorFromSharedColor(next.tintColor) textColor:RCTUIColorFromSharedColor(next.textColor)
    fontSize:next.fontSize fontWeight:[NSString stringWithUTF8String:next.fontWeight.c_str()]
    colorScheme:[NSString stringWithUTF8String:next.colorScheme.c_str()]
    measurementID:[NSString stringWithUTF8String:next.measurementID.c_str()]
    textStyle:[NSString stringWithUTF8String:next.textStyle.c_str()]
    contentAlignment:[NSString stringWithUTF8String:next.contentAlignment.c_str()]
    multilineAlignment:[NSString stringWithUTF8String:next.multilineAlignment.c_str()]];
  [super updateProps:props oldProps:oldProps]; self.isAccessibilityElement = NO;
}
- (void)layoutSubviews { [super layoutSubviews]; _label.frame = self.bounds; }
- (void)prepareForRecycle { [_label resetForRecycle]; [super prepareForRecycle]; }
@end
