import assert from 'node:assert/strict';
import test from 'node:test';
import {formatSignature} from '../localization-formats.mjs';

test('translations may reorder arguments using positional placeholders', () => {
  assert.equal(formatSignature('%@ has %lld items'), formatSignature('%2$lld items for %1$@'));
  assert.equal(formatSignature('%@ %@'), formatSignature('%2$@ %1$@'));
});

test('missing, repeated and ABI-incompatible format arguments fail parity', () => {
  for (const value of ['%@', '%@ %d', '%@ %@', '%1$@ %1$@', '%@ %ld']) {
    assert.notEqual(formatSignature('%@ %lld'), formatSignature(value));
  }
  assert.notEqual(formatSignature('%d%%'), formatSignature('%d%'));
  assert.notEqual(formatSignature('Switch to ${filter}'), formatSignature('Switch to ${name}'));
});
