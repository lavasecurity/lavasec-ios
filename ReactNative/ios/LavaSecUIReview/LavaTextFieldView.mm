#import "LavaTextFieldView.h"
#import <React/RCTScrollViewComponentView.h>
#import <React/RCTConversions.h>
#import <react/renderer/components/LavaUIReviewSpec/ComponentDescriptors.h>
#import <react/renderer/components/LavaUIReviewSpec/EventEmitters.h>
#import <react/renderer/components/LavaUIReviewSpec/Props.h>
#if LAVA_REACT_NATIVE
#import <AuthenticationServices/AuthenticationServices.h>
#import <UserNotifications/UserNotifications.h>
#import <AVFoundation/AVFoundation.h>
#endif
#import "LavaSecUIReview-Swift.h"

using namespace facebook::react;

static BOOL mayEditWireGuardName(const LavaTextFieldProps &props) {
  if (props.kind != "wireGuardName") return YES;
#if LAVA_REACT_NATIVE
  return props.editable && [[LavaAppBridge shared] canEditWireGuardNameForOwnerID:[NSString stringWithUTF8String:props.ownerID.c_str()]];
#else
  return NO;
#endif
}

@interface LavaTextFieldView () <UITextFieldDelegate, UITextViewDelegate>
- (BOOL)admitsWireGuardNameEdit;
- (void)suspendWireGuardName;
- (void)refreshWireGuardNameAdmission;
- (void)requestInitialFocus;
@end

@implementation LavaTextFieldView {
  UITextField *_field;
  UITextView *_multiline;
  UILabel *_placeholder;
  CGFloat _lastReportedHeight;
  BOOL _emojiSeeded;
  BOOL _ordinarySeeded;
  BOOL _initialFocusQueued;
  BOOL _initialFocusCompleted;
  NSUInteger _focusGeneration;
  BOOL _wireGuardNameSuspended;
  BOOL _wireGuardNameNeedsReconciliation;
  BOOL _wireGuardNameReconciliationQueued;
#if LAVA_REACT_NATIVE
  LavaWireGuardInputContent *_confidentialInput;
#endif
}
+ (ComponentDescriptorProvider)componentDescriptorProvider {
  return concreteComponentDescriptorProvider<LavaTextFieldComponentDescriptor>();
}
- (instancetype)initWithFrame:(CGRect)frame {
  if (self = [super initWithFrame:frame]) {
    _props = std::make_shared<const LavaTextFieldProps>();
    _field = [LavaEmojiTextField new];
    _wireGuardNameSuspended = UIApplication.sharedApplication.applicationState != UIApplicationStateActive || !UIApplication.sharedApplication.protectedDataAvailable;
    __weak LavaTextFieldView *weakSelf = self;
    ((LavaEmojiTextField *)_field).mayPerformEditAction = ^BOOL {
      LavaTextFieldView *strongSelf = weakSelf;
      return strongSelf && [strongSelf admitsWireGuardNameEdit];
    };
    NSNotificationCenter *notifications = NSNotificationCenter.defaultCenter;
    [notifications addObserver:self selector:@selector(suspendWireGuardName) name:UIApplicationWillResignActiveNotification object:nil];
    [notifications addObserver:self selector:@selector(suspendWireGuardName) name:UIApplicationProtectedDataWillBecomeUnavailable object:nil];
    [notifications addObserver:self selector:@selector(refreshWireGuardNameAdmission) name:UIApplicationDidBecomeActiveNotification object:nil];
    [notifications addObserver:self selector:@selector(refreshWireGuardNameAdmission) name:UIApplicationProtectedDataDidBecomeAvailable object:nil];
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
    _multiline.autocorrectionType = UITextAutocorrectionTypeNo;
    _multiline.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _multiline.spellCheckingType = UITextSpellCheckingTypeNo;
    _multiline.smartInsertDeleteType = UITextSmartInsertDeleteTypeNo;
    _multiline.tintColor = _field.tintColor;
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
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (BOOL)admitsWireGuardNameEdit {
  const auto &props = *std::static_pointer_cast<const LavaTextFieldProps>(_props);
  return props.kind != "wireGuardName" || (!_wireGuardNameSuspended && mayEditWireGuardName(props));
}
- (void)suspendWireGuardName {
  _wireGuardNameSuspended = YES;
  const auto &props = *std::static_pointer_cast<const LavaTextFieldProps>(_props);
  if (props.kind != "wireGuardName") return;
  // Do not blur the separate confidential configuration responder or replace
  // the Name buffer. UIKit must stop Name input before an RN update arrives.
  _wireGuardNameNeedsReconciliation = YES;
  _field.enabled = NO; _field.accessibilityElementsHidden = YES;
  [_field resignFirstResponder];
}
- (void)refreshWireGuardNameAdmission {
  _wireGuardNameSuspended = UIApplication.sharedApplication.applicationState != UIApplicationStateActive || !UIApplication.sharedApplication.protectedDataAvailable;
  const auto &props = *std::static_pointer_cast<const LavaTextFieldProps>(_props);
  if (props.kind != "wireGuardName") return;
  BOOL editable = [self admitsWireGuardNameEdit];
  _field.enabled = editable; _field.accessibilityElementsHidden = !editable;
  if (!editable) [_field resignFirstResponder];
}
- (void)updateProps:(Props::Shared const &)props oldProps:(Props::Shared const &)oldProps {
  const auto &next = *std::static_pointer_cast<const LavaTextFieldProps>(props);
  const auto &previous = *std::static_pointer_cast<const LavaTextFieldProps>(_props);
  _field.accessibilityLabel = [NSString stringWithUTF8String:next.inputLabel.c_str()];
  _multiline.accessibilityLabel = _field.accessibilityLabel;
  _field.placeholder = [NSString stringWithUTF8String:next.placeholder.c_str()];
  const BOOL ordinary = next.kind == "plain" || next.kind == "prose" || next.kind == "search" || next.kind == "wireGuardName";
  const BOOL ordinaryReseed = ordinary && (!_ordinarySeeded || next.ownerID != previous.ownerID || next.resetRevision != previous.resetRevision);
  if (ordinaryReseed) {
    NSString *value = [NSString stringWithUTF8String:next.value.c_str()];
    _field.text = value; _multiline.text = value;
    _ordinarySeeded = YES;
  } else if (!ordinary) { _ordinarySeeded = NO; }
  const BOOL nameEditable = next.kind != "wireGuardName" || (!_wireGuardNameSuspended && mayEditWireGuardName(next));
  if (next.kind != "wireGuardName" || previous.kind != "wireGuardName" || next.ownerID != previous.ownerID || next.resetRevision != previous.resetRevision) {
    _wireGuardNameNeedsReconciliation = NO;
  } else if (!next.editable || !nameEditable) { _wireGuardNameNeedsReconciliation = YES; }
  _field.enabled = next.editable && nameEditable;
  if (next.kind == "wireGuardName" || previous.kind == "wireGuardName") _field.accessibilityElementsHidden = next.kind == "wireGuardName" && !nameEditable;
  _multiline.editable = next.editable;
  if (!next.editable || !nameEditable) { [_field resignFirstResponder]; [_multiline resignFirstResponder]; }
  _field.keyboardType = next.keyboardType == "email-address" ? UIKeyboardTypeEmailAddress
    : next.keyboardType == "url" || (!ordinary && next.keyboardType.empty()) ? UIKeyboardTypeURL : UIKeyboardTypeDefault;
  _field.autocapitalizationType = next.autoCapitalize == "words" ? UITextAutocapitalizationTypeWords
    : next.autoCapitalize == "sentences" ? UITextAutocapitalizationTypeSentences : UITextAutocapitalizationTypeNone;
  _multiline.autocapitalizationType = _field.autocapitalizationType;
  _field.autocorrectionType = next.autoCorrect ? UITextAutocorrectionTypeDefault : UITextAutocorrectionTypeNo;
  _multiline.autocorrectionType = _field.autocorrectionType;
  _field.spellCheckingType = next.spellCheck ? UITextSpellCheckingTypeDefault : UITextSpellCheckingTypeNo;
  _multiline.spellCheckingType = _field.spellCheckingType;
  _field.smartInsertDeleteType = next.smartInsertDelete ? UITextSmartInsertDeleteTypeDefault : UITextSmartInsertDeleteTypeNo;
  _multiline.smartInsertDeleteType = _field.smartInsertDeleteType;
  _field.clearButtonMode = next.clearButtonMode == "while-editing" ? UITextFieldViewModeWhileEditing : UITextFieldViewModeNever;
  if (next.selectionColor) {
    _field.tintColor = RCTUIColorFromSharedColor(next.selectionColor);
    _multiline.tintColor = _field.tintColor;
  }
  UIColor *textColor = next.textColor ? RCTUIColorFromSharedColor(next.textColor) : UIColor.labelColor;
  _field.textColor = textColor; _multiline.textColor = textColor;
  UIColor *placeholderColor = next.placeholderTextColor ? RCTUIColorFromSharedColor(next.placeholderTextColor) : UIColor.placeholderTextColor;
  _field.attributedPlaceholder = [[NSAttributedString alloc] initWithString:_field.placeholder ?: @""
    attributes:@{NSForegroundColorAttributeName: placeholderColor}];
  _placeholder.textColor = placeholderColor;
  ((LavaEmojiTextField *)_field).emojiEnabled = next.kind == "emoji";
  if (next.kind == "emoji") {
    _field.accessibilityIdentifier = @"filter.identity.emoji.input";
    // UIKit owns the live edit buffer. Unrelated draft/validation acknowledgements
    // may carry the previous value while a newer emoji is already being typed.
    // Seed only a new owner or an explicit reset, never echo those stale props.
    if (!_emojiSeeded || next.ownerID != previous.ownerID || next.resetRevision != previous.resetRevision) {
      _field.text = [NSString stringWithUTF8String:next.value.c_str()];
      _emojiSeeded = YES;
    }
  } else { _field.accessibilityIdentifier = nil; _emojiSeeded = NO; }
  _placeholder.text = _field.placeholder;
  UIFont *font = next.fontPointSize > 0 ? [UIFont systemFontOfSize:next.fontPointSize] : [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
  if (![_field.font isEqual:font]) _field.font = font;
  if (![_multiline.font isEqual:font]) _multiline.font = font;
  _placeholder.font = font;
  if (next.kind == "prose" && next.lineHeight > 0) {
    NSMutableParagraphStyle *paragraph = [NSMutableParagraphStyle new];
    // SwiftUI keeps the first baseline at the font's natural height and adds
    // leading between paragraphs. A minimum line height moves every glyph down.
    paragraph.lineSpacing = MAX(0, next.lineHeight - font.lineHeight);
    _multiline.typingAttributes = @{NSFontAttributeName:font, NSForegroundColorAttributeName:textColor,
      NSParagraphStyleAttributeName:paragraph};
    if (ordinaryReseed || next.lineHeight != previous.lineHeight) {
      [_multiline.textStorage addAttribute:NSParagraphStyleAttributeName value:paragraph range:NSMakeRange(0,_multiline.textStorage.length)];
    }
    _placeholder.attributedText = [[NSAttributedString alloc] initWithString:_field.placeholder ?: @""
      attributes:@{NSFontAttributeName:font, NSForegroundColorAttributeName:placeholderColor, NSParagraphStyleAttributeName:paragraph}];
  }
  _field.adjustsFontForContentSizeCategory = next.fontPointSize <= 0;
  _multiline.adjustsFontForContentSizeCategory = next.fontPointSize <= 0;
  _placeholder.adjustsFontForContentSizeCategory = next.fontPointSize <= 0;
  _field.hidden = next.kind == "multiline" || next.kind == "prose";
  _multiline.hidden = !_field.hidden;
  _multiline.textContainerInset = next.kind == "prose" ? UIEdgeInsetsMake(8, 0, 8, 0) : UIEdgeInsetsZero;
  _multiline.textContainer.lineFragmentPadding = next.kind == "prose" ? 5 : 0;
  _placeholder.hidden = _multiline.text.length > 0;
#if LAVA_REACT_NATIVE
  if (next.kind == "wireGuard") {
    if (!_confidentialInput) {
      _confidentialInput = [LavaWireGuardInputContent new];
      __weak LavaTextFieldView *weakSelf = self;
      _confidentialInput.focusChanged = ^(BOOL focused) {
        LavaTextFieldView *strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf reportFocus:focused];
      };
      [self.contentView addSubview:_confidentialInput];
    }
    [_confidentialInput configureWithOwnerID:[NSString stringWithUTF8String:next.ownerID.c_str()]
      placeholder:[NSString stringWithUTF8String:next.placeholder.c_str()] fontPointSize:next.fontPointSize];
    _confidentialInput.hidden = NO; _field.hidden = YES; _multiline.hidden = YES;
  } else { _confidentialInput.hidden = YES; }
#endif
  if (!ordinary && next.kind != "emoji" && next.resetRevision != previous.resetRevision) {
    _field.text = @"";
    _multiline.text = @"";
    _placeholder.hidden = NO;
  }
  [super updateProps:props oldProps:oldProps];
  if (next.kind == "wireGuardName" && next.editable && nameEditable && _wireGuardNameNeedsReconciliation && !_wireGuardNameReconciliationQueued) {
    // Resigning can commit marked Name text while publication is revoked. Wait
    // for this props/event-handler transaction to finish, then report the live
    // retained buffer under restored authority, never a captured older string.
    _wireGuardNameReconciliationQueued = YES;
    NSString *ownerID = [NSString stringWithUTF8String:next.ownerID.c_str()];
    const int resetRevision = next.resetRevision;
    __weak LavaTextFieldView *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
      LavaTextFieldView *strongSelf = weakSelf;
      if (!strongSelf) return;
      strongSelf->_wireGuardNameReconciliationQueued = NO;
      const auto &current = *std::static_pointer_cast<const LavaTextFieldProps>(strongSelf->_props);
      if (!strongSelf->_wireGuardNameNeedsReconciliation || current.kind != "wireGuardName" || current.ownerID != ownerID.UTF8String
          || current.resetRevision != resetRevision || !current.editable || !strongSelf.window
          || ![strongSelf admitsWireGuardNameEdit] || strongSelf->_field.markedTextRange) return;
      strongSelf->_wireGuardNameNeedsReconciliation = NO;
      NSString *accepted = [NSString stringWithUTF8String:current.value.c_str()];
      if (![(strongSelf->_field.text ?: @"") isEqualToString:accepted]) [strongSelf textChanged];
    });
  }
  [self setNeedsLayout];
  [self requestInitialFocus];
}
- (void)didMoveToWindow {
  [super didMoveToWindow];
  if (!self.window) { _focusGeneration++; _initialFocusQueued = NO; }
  [self requestInitialFocus];
}
- (void)requestInitialFocus {
  const auto &props = *std::static_pointer_cast<const LavaTextFieldProps>(_props);
  if (!self.window || !props.autoFocus || !props.editable || _initialFocusQueued || _initialFocusCompleted) return;
  _initialFocusQueued = YES;
  const NSUInteger generation = _focusGeneration;
  __weak LavaTextFieldView *weakSelf = self;
  // Wait for attachment, then use the sheet's real presentation completion.
  // A timer can open the keyboard halfway through UIKit's sheet animation.
  dispatch_async(dispatch_get_main_queue(), ^{
    LavaTextFieldView *strongSelf = weakSelf;
    if (!strongSelf || generation != strongSelf->_focusGeneration) return;
    void (^focus)(void) = ^{
      LavaTextFieldView *view = weakSelf;
      if (!view || generation != view->_focusGeneration) return;
      view->_initialFocusQueued = NO;
      const auto &current = *std::static_pointer_cast<const LavaTextFieldProps>(view->_props);
      if (!view.window || !current.autoFocus || !current.editable || ![view admitsWireGuardNameEdit]) return;
      view->_initialFocusCompleted = [view->_field becomeFirstResponder];
    };
    UIResponder *owner = strongSelf.nextResponder;
    while (owner && ![owner isKindOfClass:UIViewController.class]) owner = owner.nextResponder;
    id<UIViewControllerTransitionCoordinator> transition = [(UIViewController *)owner transitionCoordinator];
    if (!transition || ![transition animateAlongsideTransition:nil completion:^(id<UIViewControllerTransitionCoordinatorContext> context) {
      if (!context.isCancelled) focus();
      else {
        LavaTextFieldView *view = weakSelf;
        if (view && generation == view->_focusGeneration) view->_initialFocusQueued = NO;
      }
    }]) focus();
  });
}
- (void)layoutSubviews {
  [super layoutSubviews];
  _field.frame = self.contentView.bounds;
  const auto &props = *std::static_pointer_cast<const LavaTextFieldProps>(_props);
  CGRect multilineFrame = self.contentView.bounds;
  if (props.kind == "prose") { multilineFrame.origin.x -= 5; multilineFrame.size.width += 5; }
  _multiline.frame = multilineFrame;
#if LAVA_REACT_NATIVE
  _confidentialInput.frame = self.contentView.bounds;
#endif
  CGFloat inset = _multiline.textContainer.lineFragmentPadding;
  CGSize placeholderSize = [_placeholder sizeThatFits:CGSizeMake(_multiline.bounds.size.width-inset, CGFLOAT_MAX)];
  _placeholder.frame = (CGRect){CGPointMake(inset, _multiline.textContainerInset.top), placeholderSize};
  CGFloat height = props.kind == "prose" ? ceil([_multiline sizeThatFits:CGSizeMake(_multiline.bounds.size.width, CGFLOAT_MAX)].height) : ceil(_field.font.lineHeight + 2);
  if (height != _lastReportedHeight) {
    auto emitter = std::static_pointer_cast<const LavaTextFieldEventEmitter>(_eventEmitter);
    if (emitter) { _lastReportedHeight = height; emitter->onSizeChange({(float)height}); }
  }
}
- (void)reactUpdateResponderOffsetForScrollView:(RCTScrollViewComponentView *)scrollView {
  BOOL focused = _field.isFirstResponder || _multiline.isFirstResponder;
#if LAVA_REACT_NATIVE
  focused = focused || _confidentialInput.isEditing;
#endif
  if ([self isDescendantOfView:scrollView.scrollView] && focused) {
    scrollView.firstResponderFocus = [self convertRect:self.bounds toView:nil];
  }
}
- (void)reportFocus:(BOOL)focused {
  auto emitter = std::static_pointer_cast<const LavaTextFieldEventEmitter>(_eventEmitter);
  if (emitter) emitter->onFocusChange({(bool)focused});
}
- (void)textChanged {
  if (![self admitsWireGuardNameEdit]) return;
  const auto &props = *std::static_pointer_cast<const LavaTextFieldProps>(_props);
  if (props.kind == "emoji") {
    if (_field.markedTextRange) return;
    _field.text = [LavaEmojiTextField committedEmoji:_field.text ?: @"" fallback:[NSString stringWithUTF8String:props.value.c_str()]];
  }
  if (_field.markedTextRange) return;
  NSString *accepted = [self boundedText:_field.text ?: @""];
  if (![accepted isEqualToString:_field.text]) {
    NSInteger caret = [_field offsetFromPosition:_field.beginningOfDocument toPosition:_field.selectedTextRange.start];
    _field.text = accepted;
    UITextPosition *position = [_field positionFromPosition:_field.beginningOfDocument offset:MIN(MAX(0, caret), accepted.length)];
    if (position) _field.selectedTextRange = [_field textRangeFromPosition:position toPosition:position];
  }
  auto emitter = std::static_pointer_cast<const LavaTextFieldEventEmitter>(_eventEmitter);
  if (emitter) emitter->onChange({std::string((_field.text ?: @"").UTF8String)});
}
- (BOOL)textField:(UITextField *)field shouldChangeCharactersInRange:(NSRange)range replacementString:(NSString *)text {
  if (![self admitsWireGuardNameEdit]) return NO;
  const auto &props = *std::static_pointer_cast<const LavaTextFieldProps>(_props);
  if (props.kind != "emoji" || field.markedTextRange || text.length == 0) return YES;
  NSString *accepted = [LavaEmojiTextField committedEmoji:text fallback:@""];
  if (accepted.length == 0) return YES;
  field.text = accepted; [self textChanged]; return NO;
}
- (BOOL)textFieldShouldBeginEditing:(UITextField *)field { return [self admitsWireGuardNameEdit]; }
- (BOOL)textFieldShouldClear:(UITextField *)field { return [self admitsWireGuardNameEdit]; }
- (void)textFieldDidBeginEditing:(UITextField *)field {
  const auto &props = *std::static_pointer_cast<const LavaTextFieldProps>(_props);
  if (props.kind == "emoji") [field selectAll:nil];
  [self reportFocus:YES];
}
- (void)textFieldDidEndEditing:(UITextField *)field {
  const auto &props = *std::static_pointer_cast<const LavaTextFieldProps>(_props);
  if (props.kind == "plain" || props.kind == "search" || props.kind == "wireGuardName") { [field unmarkText]; [self textChanged]; }
  [self reportFocus:NO];
}
- (void)textViewDidBeginEditing:(UITextView *)textView { [self reportFocus:YES]; }
- (void)textViewDidEndEditing:(UITextView *)textView {
  const auto &props = *std::static_pointer_cast<const LavaTextFieldProps>(_props);
  if (props.kind == "prose") { [textView unmarkText]; [self textViewDidChange:textView]; }
  [self reportFocus:NO];
}
- (void)textViewDidChange:(UITextView *)textView {
  if (textView.markedTextRange) return;
  {
    NSString *accepted = [self boundedText:textView.text ?: @""];
    if (![accepted isEqualToString:textView.text]) {
      NSRange selection = textView.selectedRange;
      textView.text = accepted;
      textView.selectedRange = NSMakeRange(MIN(selection.location, accepted.length), 0);
    }
  }
  _placeholder.hidden = textView.text.length > 0;
  auto emitter = std::static_pointer_cast<const LavaTextFieldEventEmitter>(_eventEmitter);
  if (emitter) emitter->onChange({std::string((textView.text ?: @"").UTF8String)});
  [self setNeedsLayout];
}
- (NSString *)boundedText:(NSString *)text {
  const auto &props = *std::static_pointer_cast<const LavaTextFieldProps>(_props);
  if (props.characterLimit <= 0) return text;
  const NSInteger limit = props.characterLimit;
  __block NSInteger count = 0;
  __block NSUInteger end = text.length;
  [text enumerateSubstringsInRange:NSMakeRange(0, text.length) options:NSStringEnumerationByComposedCharacterSequences
    usingBlock:^(NSString *substring, NSRange range, NSRange enclosingRange, BOOL *stop) {
      if (++count > limit) { end = range.location; *stop = YES; }
    }];
  return end == text.length ? text : [text substringToIndex:end];
}
- (BOOL)textFieldShouldReturn:(UITextField *)textField {
  if (![self admitsWireGuardNameEdit]) return NO;
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
  _emojiSeeded = NO;
  _ordinarySeeded = NO;
  _focusGeneration++;
  _initialFocusQueued = NO;
  _initialFocusCompleted = NO;
  _wireGuardNameNeedsReconciliation = NO;
  _wireGuardNameReconciliationQueued = NO;
#if LAVA_REACT_NATIVE
  [_confidentialInput removeFromSuperview]; _confidentialInput = nil;
#endif
  [super prepareForRecycle];
}
@end
