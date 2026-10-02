import {readFileSync} from 'node:fs';
import {resolve} from 'node:path';

// Wiring pins complement the executable pending/cancellation tests. The native
// controller owns provider UI and networking; returning its actual Task lets the
// bridge preserve that operation's lifetime without polling busy snapshots.
const controller=readFileSync(resolve(__dirname,'../../LavaSecApp/AccountController.swift'),'utf8');
const bridge=readFileSync(resolve(__dirname,'../native-app/LavaAppBridge.swift'),'utf8');
test.each(['Apple','Google'])('RN awaits the actual native %s sign-in task',provider=>{
  expect(controller).toMatch(new RegExp(`@discardableResult\\s+func beginSignInWith${provider}\\(\\) -> Task<Void, Never> \\{`));
  expect(bridge).toContain(`await model.account.beginSignInWith${provider}().value`);
});
