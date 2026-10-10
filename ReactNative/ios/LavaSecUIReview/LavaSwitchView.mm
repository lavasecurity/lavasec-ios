#import "LavaSwitchView.h"
#import <React/RCTConversions.h>
#import <react/renderer/components/LavaUIReviewSpec/ComponentDescriptors.h>
#import <react/renderer/components/LavaUIReviewSpec/EventEmitters.h>
#import <react/renderer/components/LavaUIReviewSpec/Props.h>
using namespace facebook::react;
@implementation LavaSwitchView { UISwitch *_control; BOOL _initialized; BOOL _awaitingAcknowledgement; BOOL _requestedValue; CGSize _reportedSize; }
+ (ComponentDescriptorProvider)componentDescriptorProvider { return concreteComponentDescriptorProvider<LavaSwitchComponentDescriptor>(); }
- (instancetype)initWithFrame:(CGRect)frame {
  if (self = [super initWithFrame:frame]) {
    _props = std::make_shared<const LavaSwitchProps>();
    _control = [UISwitch new];
    [_control addTarget:self action:@selector(changed) forControlEvents:UIControlEventValueChanged];
    [self addSubview:_control];
    self.isAccessibilityElement = NO;
  }
  return self;
}
- (void)updateProps:(Props::Shared const &)props oldProps:(Props::Shared const &)oldProps {
  const auto &next = *std::static_pointer_cast<const LavaSwitchProps>(props);
  const auto &previous = *std::static_pointer_cast<const LavaSwitchProps>(_props);
  const BOOL reconcile = !_initialized || next.value != previous.value || next.resetRevision != previous.resetRevision;
  // Layout, label and disabled updates are not an acknowledgement of a gesture.
  // Reapplying an unchanged value here reverses the thumb before JS can publish
  // pending intent, then animates it forward again.
  if (reconcile && _control.on != next.value) [_control setOn:next.value animated:_initialized];
  if (reconcile || next.pending) _awaitingAcknowledgement = NO;
  _initialized = YES;
  _control.enabled = !next.disabled;
  _control.userInteractionEnabled = !next.pending && !_awaitingAcknowledgement;
  if (next.disabled || next.pending) _control.accessibilityTraits |= UIAccessibilityTraitNotEnabled;
  else _control.accessibilityTraits &= ~UIAccessibilityTraitNotEnabled;
  _control.onTintColor = RCTUIColorFromSharedColor(next.tintColor);
  _control.accessibilityLabel = [NSString stringWithUTF8String:next.label.c_str()];
  [super updateProps:props oldProps:oldProps];
  _control.accessibilityHint = self.accessibilityHint;
  self.isAccessibilityElement = NO;
  _control.isAccessibilityElement = YES;
  _control.accessibilityIdentifier = _control.accessibilityLabel;
  self.accessibilityElements = @[_control];
}
- (BOOL)isAccessibilityElement { return NO; }
- (void)layoutSubviews {
  [super layoutSubviews];
  // SwiftUI places UISwitch by its alignment rectangle, which can differ from
  // its painted bounds. Reserve that same layout slot without clipping its paint.
  [_control sizeToFit];
  const CGRect alignment = [_control alignmentRectForFrame:_control.bounds];
  const CGSize size = alignment.size;
  const CGRect targetAlignment = CGRectMake(CGRectGetMidX(self.bounds) - size.width / 2,
                                           CGRectGetMidY(self.bounds) - size.height / 2,
                                           size.width, size.height);
  _control.frame = [_control frameForAlignmentRect:targetAlignment];
  auto emitter = std::static_pointer_cast<const LavaSwitchEventEmitter>(_eventEmitter);
  if (emitter && !CGSizeEqualToSize(size, _reportedSize)) {
    _reportedSize = size;
    emitter->onSizeChange({size.width, size.height});
  }
}
- (void)changed {
  const auto &props = *std::static_pointer_cast<const LavaSwitchProps>(_props);
  if (_awaitingAcknowledgement) { [_control setOn:_requestedValue animated:NO]; return; }
  if (props.disabled || props.pending) { [_control setOn:props.value animated:NO]; return; }
  const BOOL requestedValue = _control.on;
  // Consequential controls publish intent without briefly claiming completion.
  // Capture the gesture first, then restore the last authoritative native value.
  if (!props.optimistic) [_control setOn:props.value animated:NO];
  auto emitter = std::static_pointer_cast<const LavaSwitchEventEmitter>(_eventEmitter);
  if (emitter && requestedValue != props.value) {
    _awaitingAcknowledgement = YES;
    _requestedValue = props.optimistic ? requestedValue : props.value;
    _control.userInteractionEnabled = NO;
    emitter->onValueChange({static_cast<bool>(requestedValue)});
  }
}
- (void)prepareForRecycle {
  _initialized = NO;
  _awaitingAcknowledgement = NO;
  _reportedSize = CGSizeZero;
  _control.enabled = NO;
  _control.accessibilityLabel = nil;
  _control.accessibilityHint = nil;
  [super prepareForRecycle];
}
@end
