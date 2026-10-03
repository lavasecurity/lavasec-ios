import {readFileSync} from 'node:fs';
import {join} from 'node:path';

// The consumer has behavioral effect-ack / failure tests in app-store.test.ts.
// This boundary check couples those fixtures to the real Swift producer: only
// an already-performed haptic can use the reply that omits configuration state.
test('native haptic acknowledgement bypasses snapshot work only after performing the validated command',()=>{
  const bridge=readFileSync(join(__dirname,'../native-app/LavaAppBridge.swift'),'utf8');
  const command=bridge.slice(bridge.indexOf('@objc func command('),bridge.indexOf('    func perform('));
  const effect=command.match(/if name == "haptic" \{([^}]+)\}/);
  expect(effect).not.toBeNull();
  expect(effect[1]).toMatch(/completion\(json\(\["result": result\]\), nil\)\s*return/);
  expect(effect[1]).not.toMatch(/publish\(|snapshot\(/);
  expect(command.indexOf('try await perform(name, payload)')).toBeLessThan(command.indexOf(effect[0]));
  const mutations=command.slice(command.indexOf(effect[0])+effect[0].length);
  expect(mutations).toMatch(/publish\(\)[\s\S]*completion\(json\(\["snapshot":/);
  expect(mutations).toContain('catch { completion(nil, error.localizedDescription) }');
});
