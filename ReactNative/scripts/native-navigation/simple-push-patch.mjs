import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';

// react-native-screens 4.27.0, captured before/after the cancelled-pop experiment.
// Normal page navigation uses UIKit. Restore the previous local modification
// on existing installs; reject dependency drift instead of rewriting unknown code.
export const simplePushOriginalSHA256 = 'bd991a1f32dad21f89172cced78edf8f76b16d95c6e75127e7931cbe89dd5cea';
export const simplePushPatchedSHA256 = 'f54d7371f28f8dc2a726744fae78369647e1b07f4ad1bb3bdb6b3e2eb45d1513';
const sha256 = source => createHash('sha256').update(source).digest('hex');

export function restoreSimplePushAnimator(source) {
  const hash = sha256(source);
  if (hash === simplePushOriginalSHA256) return source;
  assert.equal(hash, simplePushPatchedSHA256,
    'Native stack animator changed or is partially patched; review the simple-push adapter before restoring it.');

  const start = source.indexOf('- (void)animateSimplePushWithShadowEnabled:');
  const end = source.indexOf('\n- (void)animateSlideFromLeftWithTransitionContext:', start);
  assert.ok(start >= 0 && end > start, 'Pinned simple-push method boundaries are missing.');
  let replacements = 0;
  // Only the frozen layer-transform experiment can reach this migration.
  // Recover UIView assignments byte-for-byte, including cancellation cleanup.
  const method = source.slice(start, end).replace(
    /^([ \t]*)\[(fromViewController|toViewController)\.view\.layer setAffineTransform:(rightTransform|leftTransform|CGAffineTransformIdentity)\];$/gm,
    (_, indent, controller, transform) => {
      replacements += 1;
      return `${indent}${controller}.view.transform = ${transform};`;
    });
  assert.equal(replacements, 10, 'Pinned simple-push transform assignments changed.');
  const updated = source.slice(0, start) + method + source.slice(end);
  assert.equal(sha256(updated), simplePushOriginalSHA256, 'Restored stack animator differs from the pinned upstream owner.');
  return updated;
}
