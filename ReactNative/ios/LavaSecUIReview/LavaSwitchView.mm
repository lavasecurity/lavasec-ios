#import "LavaSwitchView.h"
#import <React/RCTConversions.h>
#import <react/renderer/components/LavaUIReviewSpec/ComponentDescriptors.h>
#import <react/renderer/components/LavaUIReviewSpec/EventEmitters.h>
#import <react/renderer/components/LavaUIReviewSpec/Props.h>
using namespace facebook::react;
@implementation LavaSwitchView { UISwitch *_control; BOOL _initialized; CGSize _reportedSize; }
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
  if (!_initialized || _control.on != next.value) [_control setOn:next.value animated:_initialized];
  _initialized = YES;
  _control.enabled = !next.disabled;
  _control.userInteractionEnabled = !next.pending;
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
  // UISwitch's intrinsic size changes with iOS. Center its actual bounds in
  // the row's control slot instead of assigning RN's legacy switch rectangle.
  [_control sizeToFit];
  _control.center = CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));
  const CGSize size = _control.bounds.size;
  auto emitter = std::static_pointer_cast<const LavaSwitchEventEmitter>(_eventEmitter);
  if (emitter && !CGSizeEqualToSize(size, _reportedSize)) {
    _reportedSize = size;
    emitter->onSizeChange({size.width, size.height});
  }
}
- (void)changed {
  const auto &props = *std::static_pointer_cast<const LavaSwitchProps>(_props);
  if (props.disabled || props.pending) { [_control setOn:props.value animated:NO]; return; }
  const BOOL requestedValue = _control.on;
  // Consequential controls publish intent without briefly claiming completion.
  // Capture the gesture first, then restore the last authoritative native value.
  if (!props.optimistic) [_control setOn:props.value animated:NO];
  auto emitter = std::static_pointer_cast<const LavaSwitchEventEmitter>(_eventEmitter);
  if (emitter && requestedValue != props.value) emitter->onValueChange({static_cast<bool>(requestedValue)});
}
- (void)prepareForRecycle {
  _initialized = NO;
  _reportedSize = CGSizeZero;
  _control.enabled = NO;
  _control.accessibilityLabel = nil;
  _control.accessibilityHint = nil;
  [super prepareForRecycle];
}
@end
