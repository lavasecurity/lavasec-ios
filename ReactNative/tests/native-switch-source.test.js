const fs=require('node:fs');
const path=require('node:path');
const source=fs.readFileSync(path.join(__dirname,'../ios/LavaSecUIReview/LavaSwitchView.mm'),'utf8');

// This source boundary protects the native ordering JS mocks cannot exercise.
// Actual UIKit rendering and VoiceOver still require the native journey gate.
test('confirmed native switches restore authoritative state before emitting the captured gesture intent',()=>{
  const changed=source.slice(source.indexOf('- (void)changed {'),source.indexOf('- (void)prepareForRecycle'));
  const capture=changed.indexOf('const BOOL requestedValue = _control.on;');
  const restore=changed.indexOf('if (!props.optimistic) [_control setOn:props.value animated:NO];');
  const emit=changed.indexOf('emitter->onValueChange({static_cast<bool>(requestedValue)})');
  expect(capture).toBeGreaterThan(0);
  expect(restore).toBeGreaterThan(capture);
  expect(emit).toBeGreaterThan(restore);
  expect(changed).toContain('if (props.disabled || props.pending)');
  expect(changed).toContain('requestedValue != props.value');
});

test('the actual UISwitch retains the public hint and remains the only accessibility control',()=>{
  expect(source).toContain('_control.accessibilityHint = self.accessibilityHint;');
  expect(source).toContain('_control.isAccessibilityElement = YES;');
  expect(source).toContain('self.accessibilityElements = @[_control];');
  expect(source).toContain('- (BOOL)isAccessibilityElement { return NO; }');
  expect(source).toContain('_control.accessibilityHint = nil;');
});

test('unrelated prop publications cannot reverse an unacknowledged UIKit gesture',()=>{
  const update=source.slice(source.indexOf('- (void)updateProps:'),source.indexOf('- (BOOL)isAccessibilityElement'));
  expect(update).toContain('std::static_pointer_cast<const LavaSwitchProps>(_props)');
  expect(update).not.toContain('std::static_pointer_cast<const LavaSwitchProps>(oldProps)');
  expect(update).toContain('next.value != previous.value || next.resetRevision != previous.resetRevision');
  expect(update).toContain('if (reconcile && _control.on != next.value)');
  expect(update).toContain('if (reconcile || next.pending) _awaitingAcknowledgement = NO;');
  const changed=source.slice(source.indexOf('- (void)changed {'),source.indexOf('- (void)prepareForRecycle'));
  const acknowledge=changed.indexOf('_awaitingAcknowledgement = YES;');
  const emit=changed.indexOf('emitter->onValueChange');
  expect(acknowledge).toBeGreaterThan(0);
  expect(emit).toBeGreaterThan(acknowledge);
  expect(changed).toContain('if (_awaitingAcknowledgement)');
  expect(source.slice(source.indexOf('- (void)prepareForRecycle'))).toContain('_awaitingAcknowledgement = NO;');
});
