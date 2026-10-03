#import "LavaTextFieldView.h"
#import <React/RCTScrollViewComponentView.h>
#import <react/renderer/components/LavaUIReviewSpec/ComponentDescriptors.h>
#import <react/renderer/components/LavaUIReviewSpec/EventEmitters.h>
#import <react/renderer/components/LavaUIReviewSpec/Props.h>

using namespace facebook::react;

@interface LavaTextFieldView () <UITextFieldDelegate, UITextViewDelegate>
@end

@implementation LavaTextFieldView {
  UITextField *_field;
  UITextView *_multiline;
  UILabel *_placeholder;
  CGFloat _lastReportedHeight;
}
+ (ComponentDescriptorProvider)componentDescriptorProvider {
  return concreteComponentDescriptorProvider<LavaTextFieldComponentDescriptor>();
}
- (instancetype)initWithFrame:(CGRect)frame {
  if (self = [super initWithFrame:frame]) {
    _props = std::make_shared<const LavaTextFieldProps>();
    _field = [UITextField new];
    _field.delegate = self;
    _field.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    _field.adjustsFontForContentSizeCategory = YES;
    _field.textColor = UIColor.labelColor;
    _field.keyboardType = UIKeyboardTypeURL;
    _field.returnKeyType = UIReturnKeyDone;
    _field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _field.autocorrectionType = UITextAutocorrectionTypeNo;
    _field.spellCheckingType = UITextSpellCheckingTypeNo;
    _field.smartInsertDeleteType = UITextSmartInsertDeleteTypeNo;
    [_field addTarget:self action:@selector(textChanged) forControlEvents:UIControlEventEditingChanged];
    _multiline = [UITextView new];
    _multiline.delegate = self;
    _multiline.font = _field.font;
    _multiline.adjustsFontForContentSizeCategory = YES;
    _multiline.textColor = UIColor.labelColor;
    _multiline.backgroundColor = UIColor.clearColor;
    _multiline.textContainerInset = UIEdgeInsetsZero;
    _multiline.textContainer.lineFragmentPadding = 0;
    _multiline.hidden = YES;
    _placeholder = [UILabel new];
    _placeholder.font = _field.font;
    _placeholder.adjustsFontForContentSizeCategory = YES;
    _placeholder.textColor = UIColor.placeholderTextColor;
    _placeholder.numberOfLines = 0;
    _placeholder.isAccessibilityElement = NO;
    [_multiline addSubview:_placeholder];
    UIView *container = [UIView new];
    [container addSubview:_field];
    [container addSubview:_multiline];
    self.contentView = container;
    self.isAccessibilityElement = NO;
  }
  return self;
}
- (void)updateProps:(Props::Shared const &)props oldProps:(Props::Shared const &)oldProps {
  const auto &next = *std::static_pointer_cast<const LavaTextFieldProps>(props);
  const auto &previous = *std::static_pointer_cast<const LavaTextFieldProps>(_props);
  _field.accessibilityLabel = [NSString stringWithUTF8String:next.inputLabel.c_str()];
  _multiline.accessibilityLabel = _field.accessibilityLabel;
  _field.placeholder = [NSString stringWithUTF8String:next.placeholder.c_str()];
  _placeholder.text = _field.placeholder;
  UIFont *font = next.fontPointSize > 0 ? [UIFont systemFontOfSize:next.fontPointSize] : [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
  _field.font = font;
  _multiline.font = font;
  _placeholder.font = font;
  _field.adjustsFontForContentSizeCategory = next.fontPointSize <= 0;
  _multiline.adjustsFontForContentSizeCategory = next.fontPointSize <= 0;
  _placeholder.adjustsFontForContentSizeCategory = next.fontPointSize <= 0;
  _field.hidden = next.kind == "multiline";
  _multiline.hidden = !_field.hidden;
  if (next.resetRevision != previous.resetRevision) {
    _field.text = @"";
    _multiline.text = @"";
    _placeholder.hidden = NO;
  }
  [super updateProps:props oldProps:oldProps];
  [self setNeedsLayout];
}
- (void)didMoveToWindow {
  [super didMoveToWindow];
  const auto &props = *std::static_pointer_cast<const LavaTextFieldProps>(_props);
  if (self.window && props.autoFocus) {
    // Match the domain sheet's delayed native focus after presentation. A weak
    // reference and window check keep a canceled sheet from reopening a keyboard.
    __weak LavaTextFieldView *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 180 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
      LavaTextFieldView *strongSelf = weakSelf;
      if (strongSelf.window) [strongSelf->_field becomeFirstResponder];
    });
  }
}
- (void)layoutSubviews {
  [super layoutSubviews];
  _field.frame = self.contentView.bounds;
  _multiline.frame = self.contentView.bounds;
  CGSize placeholderSize = [_placeholder sizeThatFits:CGSizeMake(_multiline.bounds.size.width, CGFLOAT_MAX)];
  _placeholder.frame = (CGRect){CGPointZero, placeholderSize};
  CGFloat height = ceil(_field.font.lineHeight + 2);
  if (height != _lastReportedHeight) {
    auto emitter = std::static_pointer_cast<const LavaTextFieldEventEmitter>(_eventEmitter);
    if (emitter) { _lastReportedHeight = height; emitter->onSizeChange({(float)height}); }
  }
}
- (void)reactUpdateResponderOffsetForScrollView:(RCTScrollViewComponentView *)scrollView {
  if ([self isDescendantOfView:scrollView.scrollView] && (_field.isFirstResponder || _multiline.isFirstResponder)) {
    scrollView.firstResponderFocus = [self convertRect:self.bounds toView:nil];
  }
}
- (void)textChanged {
  auto emitter = std::static_pointer_cast<const LavaTextFieldEventEmitter>(_eventEmitter);
  if (emitter) emitter->onChange({std::string((_field.text ?: @"").UTF8String)});
}
- (void)textViewDidChange:(UITextView *)textView {
  _placeholder.hidden = textView.text.length > 0;
  auto emitter = std::static_pointer_cast<const LavaTextFieldEventEmitter>(_eventEmitter);
  if (emitter) emitter->onChange({std::string((textView.text ?: @"").UTF8String)});
}
- (BOOL)textFieldShouldReturn:(UITextField *)textField {
  auto emitter = std::static_pointer_cast<const LavaTextFieldEventEmitter>(_eventEmitter);
  if (emitter) emitter->onSubmit({std::string((textField.text ?: @"").UTF8String)});
  [textField resignFirstResponder];
  return YES;
}
- (void)prepareForRecycle {
  [_field resignFirstResponder];
  [_multiline resignFirstResponder];
  _field.text = @"";
  _multiline.text = @"";
  _placeholder.hidden = NO;
  _lastReportedHeight = 0;
  [super prepareForRecycle];
}
@end
