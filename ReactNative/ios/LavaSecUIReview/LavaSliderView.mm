#import "LavaSliderView.h"
#import "LavaChoiceView.h"
#import <React/RCTConversions.h>
#import <react/renderer/components/LavaUIReviewSpec/ComponentDescriptors.h>
#import <react/renderer/components/LavaUIReviewSpec/EventEmitters.h>
#import <react/renderer/components/LavaUIReviewSpec/Props.h>
#include <cmath>
using namespace facebook::react;
@implementation LavaSliderView { UISlider *_slider; }
+ (ComponentDescriptorProvider)componentDescriptorProvider { return concreteComponentDescriptorProvider<LavaSliderComponentDescriptor>(); }
- (instancetype)initWithFrame:(CGRect)frame {
  if (self = [super initWithFrame:frame]) {
    _props = std::make_shared<const LavaSliderProps>();
    _slider = [UISlider new];
    [_slider addGestureRecognizer:[LavaControlTrackingGuard new]];
    [_slider addTarget:self action:@selector(changed) forControlEvents:UIControlEventValueChanged];
    [_slider addTarget:self action:@selector(trackingBegan) forControlEvents:UIControlEventTouchDown];
    [_slider addTarget:self action:@selector(trackingEnded) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    self.contentView = _slider;
    self.isAccessibilityElement = NO;
  }
  return self;
}
- (void)updateProps:(Props::Shared const &)props oldProps:(Props::Shared const &)oldProps {
  const auto &next = *std::static_pointer_cast<const LavaSliderProps>(props);
  const auto &previous = *std::static_pointer_cast<const LavaSliderProps>(_props);
  _slider.minimumValue = 0;
  _slider.maximumValue = std::isfinite(next.maximum) ? MAX(1, next.maximum) : 1;
  if (!_slider.tracking) [_slider setValue:std::isfinite(next.value) ? round(next.value) : 0 animated:YES];
  if (@available(iOS 26.0, *)) {
    if (!_slider.trackConfiguration || next.maximum != previous.maximum) {
      // UIKit's track positions are normalized; let its public factory space
      // the stops across the track, independent of our integer step values.
      _slider.trackConfiguration = [UISliderTrackConfiguration configurationWithNumberOfTicks:(NSInteger)_slider.maximumValue + 1];
    }
  }
  _slider.enabled = !next.disabled;
  _slider.tintColor = RCTUIColorFromSharedColor(next.tintColor);
  _slider.accessibilityLabel = [NSString stringWithUTF8String:next.label.c_str()];
  [super updateProps:props oldProps:oldProps];
  self.isAccessibilityElement = NO;
  _slider.isAccessibilityElement = YES;
  _slider.accessibilityIdentifier = _slider.accessibilityLabel;
  self.accessibilityElements = @[_slider];
}
- (void)layoutSubviews { [super layoutSubviews]; _slider.frame = self.bounds; }
- (void)changed {
  const auto &props = *std::static_pointer_cast<const LavaSliderProps>(_props);
  if (props.disabled) return;
  double value = round(_slider.value);
  _slider.value = value;
  auto emitter = std::static_pointer_cast<const LavaSliderEventEmitter>(_eventEmitter);
  if (emitter) emitter->onValueChange({value});
}
- (void)trackingBegan {
  auto emitter = std::static_pointer_cast<const LavaSliderEventEmitter>(_eventEmitter);
  if (emitter) emitter->onTrackingChange({true});
}
- (void)trackingEnded {
  // Finish at the native accepted tick. A lagging React render must not rewind it.
  [self changed];
  auto emitter = std::static_pointer_cast<const LavaSliderEventEmitter>(_eventEmitter);
  if (emitter) emitter->onTrackingChange({false});
}
- (void)prepareForRecycle {
  // A recycled control may leave while tracking. Release its ancestor scroll
  // lock before Fabric detaches it; cancellation must be as complete as release.
  for (UIGestureRecognizer *recognizer in _slider.gestureRecognizers) {
    if ([recognizer isKindOfClass:LavaControlTrackingGuard.class]) {
      recognizer.enabled = NO;
      recognizer.enabled = YES;
    }
  }
  _slider.enabled = NO; _slider.value = 0; _slider.accessibilityLabel = nil;
  [super prepareForRecycle];
}
@end
