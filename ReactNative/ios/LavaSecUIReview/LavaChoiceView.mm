#import "LavaChoiceView.h"
#import <React/RCTConversions.h>
#import <react/renderer/components/LavaUIReviewSpec/ComponentDescriptors.h>
#import <react/renderer/components/LavaUIReviewSpec/EventEmitters.h>
#import <react/renderer/components/LavaUIReviewSpec/Props.h>
#include <algorithm>
#if LAVA_REACT_NATIVE
#import <AuthenticationServices/AuthenticationServices.h>
#import <UserNotifications/UserNotifications.h>
#import <AVFoundation/AVFoundation.h>
#endif
#import "LavaSecUIReview-Swift.h"

using namespace facebook::react;

// UIKit does not send a value-change action for the selected segment. A
// reselectable choice (Custom dates) is also an editor entry point. Observe its
// tap without cancelling UIKit's native tracking, appearance or selection.
@interface LavaChoiceView () <UIGestureRecognizerDelegate>
@end

@implementation LavaChoiceView {
  UISegmentedControl *_control;
  UIStepper *_stepper;
  UIPageControl *_pages;
  CGFloat _reportedHeight;
  NSInteger _reselectIndex;
}
+ (ComponentDescriptorProvider)componentDescriptorProvider {
  return concreteComponentDescriptorProvider<LavaChoiceComponentDescriptor>();
}
- (instancetype)initWithFrame:(CGRect)frame {
  if (self = [super initWithFrame:frame]) {
    _props = std::make_shared<const LavaChoiceProps>();
    _control = [[UISegmentedControl alloc] initWithItems:@[]];
    [_control addTarget:self action:@selector(selectionChanged) forControlEvents:UIControlEventValueChanged];
    UITapGestureRecognizer *reselect = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(reselected:)];
    reselect.cancelsTouchesInView = NO;
    reselect.delegate = self;
    [_control addGestureRecognizer:reselect];
    _stepper = [[UIStepper alloc] init];
    [_stepper addTarget:self action:@selector(selectionChanged) forControlEvents:UIControlEventValueChanged];
    _pages = [[UIPageControl alloc] init];
    [_pages addTarget:self action:@selector(selectionChanged) forControlEvents:UIControlEventValueChanged];
    self.contentView = _control;
    self.isAccessibilityElement = NO;
  }
  return self;
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer shouldReceiveTouch:(UITouch *)touch {
  const auto &props = *std::static_pointer_cast<const LavaChoiceProps>(_props);
  _reselectIndex = UISegmentedControlNoSegment;
  if (props.disabled || props.stepper || props.pageControl || props.reselectValue.empty() || props.value != props.reselectValue) return NO;
  // Segments have equal widths (apportionsSegmentWidthsByContent is false).
  CGPoint point = [touch locationInView:_control];
  if (!CGRectContainsPoint(_control.bounds, point) || _control.bounds.size.width <= 0) return NO;
  NSInteger index = MIN((NSInteger)props.options.size() - 1,
    (NSInteger)(point.x / _control.bounds.size.width * props.options.size()));
  if (_control.effectiveUserInterfaceLayoutDirection == UIUserInterfaceLayoutDirectionRightToLeft) {
    index = (NSInteger)props.options.size() - 1 - index;
  }
  if (index < 0 || props.options[index].value != props.reselectValue) return NO;
  _reselectIndex = index;
  return YES;
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
  return YES;
}
- (void)reselected:(UITapGestureRecognizer *)recognizer {
  const auto &props = *std::static_pointer_cast<const LavaChoiceProps>(_props);
  if (recognizer.state == UIGestureRecognizerStateEnded && !props.stepper &&
      _reselectIndex >= 0 && _reselectIndex < (NSInteger)props.options.size() &&
      props.options[_reselectIndex].value == props.reselectValue && props.value == props.reselectValue) {
    [self selectionChangedAtIndex:_reselectIndex];
  }
}
- (void)updateProps:(Props::Shared const &)props oldProps:(Props::Shared const &)oldProps {
  const auto &next = *std::static_pointer_cast<const LavaChoiceProps>(props);
  const auto &previous = *std::static_pointer_cast<const LavaChoiceProps>(_props);
  const bool sameOptions = next.options.size() == previous.options.size() &&
    std::equal(next.options.begin(), next.options.end(), previous.options.begin(),
      [](const auto &left, const auto &right) { return left.value == right.value && left.label == right.label; });
  BOOL rebuilt = !next.stepper && !next.pageControl && (!sameOptions || _control.numberOfSegments != (NSInteger)next.options.size());
  if (rebuilt) {
    [_control removeAllSegments];
    for (NSUInteger index = 0; index < next.options.size(); index++) {
      [_control insertSegmentWithTitle:[NSString stringWithUTF8String:next.options[index].label.c_str()]
        atIndex:index animated:NO];
    }
  }
  NSInteger selected = UISegmentedControlNoSegment;
  for (NSUInteger index = 0; index < next.options.size(); index++) {
    if (next.options[index].value == next.value) selected = index;
  }
  // UIKit owns tracking. Reconcile only a new accepted value/acknowledgement,
  // never an unrelated Fabric update while the native selector is being dragged.
  if (rebuilt || !sameOptions || next.value != previous.value || next.selectionRevision != previous.selectionRevision) {
    _control.selectedSegmentIndex = next.stepper ? UISegmentedControlNoSegment : selected;
  }
  _control.enabled = !next.disabled;
  _control.accessibilityLabel = [NSString stringWithUTF8String:next.label.c_str()];
  _control.accessibilityIdentifier = [NSString stringWithUTF8String:next.controlID.c_str()];
  _control.tintColor = RCTUIColorFromSharedColor(next.tintColor);
  // Match SwiftUI segmented pickers: the native selection surface owns its color.
  _control.selectedSegmentTintColor = nil;
  _stepper.minimumValue = 0;
  _stepper.maximumValue = MAX(0, (NSInteger)next.options.size() - 1);
  _stepper.stepValue = 1;
  _stepper.value = MAX(0, selected);
  _stepper.enabled = !next.disabled && selected != UISegmentedControlNoSegment;
  _stepper.accessibilityLabel = _control.accessibilityLabel;
  _stepper.accessibilityIdentifier = _control.accessibilityIdentifier;
  _stepper.accessibilityValue = [NSString stringWithUTF8String:next.value.c_str()];
  _stepper.tintColor = _control.tintColor;
  _pages.numberOfPages = next.options.size();
  _pages.currentPage = MAX(0, selected);
  _pages.enabled = !next.disabled;
  _pages.accessibilityLabel = _control.accessibilityLabel;
  _pages.accessibilityIdentifier = _control.accessibilityIdentifier;
  _pages.currentPageIndicatorTintColor = _control.tintColor;
  _pages.pageIndicatorTintColor = [UIColor secondaryLabelColor];
  UIView *control = next.pageControl ? _pages : next.stepper ? _stepper : _control;
  if (self.contentView != control) self.contentView = control;
  [super updateProps:props oldProps:oldProps];
  [self setNeedsLayout];
}
- (void)layoutSubviews {
  [super layoutSubviews];
  // UIKit owns the control's intrinsic height and native accessibility elements.
  UIView *control = self.contentView;
  CGFloat height = [control sizeThatFits:CGSizeMake(self.bounds.size.width, 0)].height;
  control.frame = CGRectMake(0, 0, self.bounds.size.width, height);
  auto emitter = std::static_pointer_cast<const LavaChoiceEventEmitter>(_eventEmitter);
  if (height > 0 && height != _reportedHeight && emitter) {
    _reportedHeight = height;
    emitter->onSizeChange({height});
  }
}
- (void)selectionChanged {
  const auto &props = *std::static_pointer_cast<const LavaChoiceProps>(_props);
  [self selectionChangedAtIndex:props.pageControl ? _pages.currentPage : props.stepper ? (NSInteger)_stepper.value : _control.selectedSegmentIndex];
}
- (void)selectionChangedAtIndex:(NSInteger)index {
  const auto &props = *std::static_pointer_cast<const LavaChoiceProps>(_props);
  if (props.disabled || index < 0 || index >= (NSInteger)props.options.size()) return;
  const auto value = props.options[index].value;
  // Let UIKit finish its native tracking/selection animation. React returns an
  // acknowledgement even if an operation rejects the value; updateProps then
  // reconciles it. Resetting here interrupts the control's own drag behavior.
  auto emitter = std::static_pointer_cast<const LavaChoiceEventEmitter>(_eventEmitter);
  if (emitter && (value != props.value || value == props.reselectValue)) emitter->onValueChange({value});
}
- (void)prepareForRecycle {
  _reselectIndex = UISegmentedControlNoSegment;
  _control.enabled = NO;
  _stepper.enabled = NO;
  _pages.enabled = NO;
  _pages.accessibilityLabel = nil;
  _pages.accessibilityIdentifier = nil;
  _pages.numberOfPages = 0;
  _stepper.accessibilityLabel = nil;
  _stepper.accessibilityIdentifier = nil;
  _stepper.accessibilityValue = nil;
  [_control removeAllSegments];
  _control.accessibilityLabel = nil;
  _control.accessibilityIdentifier = nil;
  _reportedHeight = 0;
  [super prepareForRecycle];
}
@end
