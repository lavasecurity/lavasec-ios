import {readFileSync} from 'node:fs';
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {fileURLToPath} from 'node:url';
import {validateReviewSpec, validateGeneratedProjects} from './review-host-policy.mjs';
const root = new URL('../', import.meta.url);
const read = path => JSON.parse(readFileSync(new URL(path, root), 'utf8'));
validateReviewSpec(read('ios/project.json'));
if (process.argv[2]) {
  const policy = read('ios/native-dependencies.json');
  validateGeneratedProjects(JSON.parse(readFileSync(process.argv[2], 'utf8')), policy);
  for (const [path, expected] of Object.entries(policy.scriptFiles)) {
    assert.equal(createHash('sha256').update(readFileSync(new URL(path, root))).digest('hex'), expected, `Dependency script changed: ${path}`);
  }
}
console.log(`Review host boundary passed: ${fileURLToPath(root)}`);
