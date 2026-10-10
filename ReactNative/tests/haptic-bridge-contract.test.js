import {readFileSync} from 'node:fs';
import {join} from 'node:path';

// The consumer has behavioral effect-ack / failure tests in app-store.test.ts.
// This boundary check couples those fixtures to the real Swift producer:
// effects and authorized reads omit configuration; mutations still publish it.
test('native effect and query replies bypass snapshots only after final authorization',()=>{
  const bridge=readFileSync(join(__dirname,'../native-app/LavaAppBridge.swift'),'utf8');
  const command=bridge.slice(bridge.indexOf('@objc func command('),bridge.indexOf('    func perform('));
  const effect=command.match(/if name == "haptic" \|\| name.hasSuffix\("\.query"\) \{([^}]+)\}/);
  expect(effect).not.toBeNull();
  expect(effect[1]).toMatch(/completion\(json\(\["result": result\], sortedKeys: false\), nil\)\s*return/);
  expect(effect[1]).not.toMatch(/publish\(|snapshot\(/);
  expect(command.indexOf('try await perform(name, payload)')).toBeLessThan(command.indexOf(effect[0]));
  const validation=command.indexOf('try privateRead.validate()');
  expect(validation).toBeGreaterThan(command.indexOf('try await perform(name, payload)'));
  expect(validation).toBeLessThan(command.indexOf(effect[0]));
  const mutations=command.slice(command.indexOf(effect[0])+effect[0].length);
  expect(mutations).toMatch(/publish\(\)[\s\S]*completion\(json\(\["snapshot":/);
  expect(mutations).toContain('catch { completion(nil, error.localizedDescription) }');
});
