import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {readFileSync} from 'node:fs';
import test from 'node:test';
import {restoreSimplePushAnimator} from '../scripts/native-navigation/simple-push-patch.mjs';

const original = readFileSync(new URL('./fixtures/native-navigation/RNSScreenStackAnimator-4.27.0.mm', import.meta.url), 'utf8');
const sha256 = source => createHash('sha256').update(source).digest('hex');

// Recreate only the historical fixture. Production preparation has no path that
// installs this experiment again; its exact digest is checked before migration.
const start = original.indexOf('- (void)animateSimplePushWithShadowEnabled:');
const end = original.indexOf('\n- (void)animateSlideFromLeftWithTransitionContext:', start);
const legacy = original.slice(0, start) + original.slice(start, end).replace(
  /^([ \t]*)(fromViewController|toViewController)\.view\.transform = (rightTransform|leftTransform|CGAffineTransformIdentity);$/gm,
  (_, indent, controller, transform) => `${indent}[${controller}.view.layer setAffineTransform:${transform}];`) + original.slice(end);

test('pristine upstream dependency stays byte-for-byte unchanged', () => {
  assert.equal(sha256(original), 'bd991a1f32dad21f89172cced78edf8f76b16d95c6e75127e7931cbe89dd5cea');
  assert.equal(restoreSimplePushAnimator(original), original);
});

test('existing layer-transform install migrates exactly to upstream and is idempotent', () => {
  assert.equal(sha256(legacy), 'f54d7371f28f8dc2a726744fae78369647e1b07f4ad1bb3bdb6b3e2eb45d1513');
  const restored = restoreSimplePushAnimator(legacy);
  assert.equal(restored, original);
  assert.equal(restoreSimplePushAnimator(restored), original);
});

test('a partial layer patch is rejected rather than silently completed', () => {
  const partial = original.replace('toViewController.view.transform = rightTransform;',
    '[toViewController.view.layer setAffineTransform:rightTransform];');
  assert.notEqual(partial, original);
  assert.throws(() => restoreSimplePushAnimator(partial), /changed or is partially patched/);
});

test('upstream changes outside simple_push require review', () => {
  const changed = original.replace('static constexpr NSTimeInterval RNSDefaultTransitionDuration = 0.5;',
    'static constexpr NSTimeInterval RNSDefaultTransitionDuration = 0.6;');
  assert.notEqual(changed, original);
  assert.throws(() => restoreSimplePushAnimator(changed), /changed or is partially patched/);
});

test('an unknown modification to the legacy owner is rejected', () => {
  assert.throws(() => restoreSimplePushAnimator(legacy + '\n// Unreviewed change\n'),
    /changed or is partially patched/);
});

test('restoration leaves every byte outside simple_push unchanged', () => {
  const restored = restoreSimplePushAnimator(legacy);
  const methodStart = '- (void)animateSimplePushWithShadowEnabled:';
  const nextMethod = '\n- (void)animateSlideFromLeftWithTransitionContext:';
  assert.equal(restored.slice(0, restored.indexOf(methodStart)), legacy.slice(0, legacy.indexOf(methodStart)));
  assert.equal(restored.slice(restored.indexOf(nextMethod)), legacy.slice(legacy.indexOf(nextMethod)));
});
