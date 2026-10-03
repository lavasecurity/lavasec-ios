import './native-navigation/discovery-symbol.mjs';
import {readFileSync,writeFileSync} from 'node:fs';
import {createHash} from 'node:crypto';
import assert from 'node:assert/strict';
import {restoreSimplePushAnimator} from './native-navigation/simple-push-patch.mjs';
import {renderToolbarAdapter} from './native-navigation/toolbar-adapter.mjs';
import {parseTokens,sourceURL as tokenSourceURL} from './generate-tokens.mjs';
import {restoreNativeTabTransition} from './native-navigation/native-tab-baseline.mjs';
const root=new URL('../',import.meta.url);
const url=new URL('node_modules/react-native-screens/ios/tabs/host/RNSTabBarController.mm',root);
const source=readFileSync(url,'utf8');
// UIKit owns peer-tab animation as well as selection and lifecycle. The legacy
// frame-based slide is retained only as a migration fixture for existing installs.
const updated=restoreNativeTabTransition(source);
if(updated!==source)writeFileSync(url,updated);

const toolbarURL=new URL('node_modules/react-native-screens/ios/RNSBarButtonItem.mm',root);
const toolbarSource=readFileSync(toolbarURL,'utf8');
const toolbarOriginal=toolbarSource.replace(/  \/\/ Lava: visible icon \+ title[\s\S]*?  \/\/ Lava: end native labeled toolbar item\.\n/,'');
// The PR's fixed symbol metrics may already be installed by an earlier bundle.
const toolbarUpstream=toolbarOriginal.replace(/                         \/\/ Lava fixed toolbar symbol metrics\.\n[\s\S]*?                         \/\/ End Lava toolbar symbol metrics\.\n/,'');
assert.equal(createHash('sha256').update(toolbarUpstream).digest('hex'),'869bd57c319e3618f21bd5e67a85bda8322edb3610744380f1eb0b021876bc44','Native toolbar owner changed; review the labeled-item adapter before applying it.');
const toolbarAdapter=renderToolbarAdapter(readFileSync(new URL('native-navigation/labeled-toolbar.inc',import.meta.url),'utf8'),parseTokens(readFileSync(tokenSourceURL,'utf8')).toolbar);
const toolbarUpdated=toolbarOriginal.replace('  return self;\n}',toolbarAdapter+'  return self;\n}');
if(toolbarUpdated!==toolbarSource)writeFileSync(toolbarURL,toolbarUpdated);

const stackAnimatorURL=new URL('node_modules/react-native-screens/ios/RNSScreenStackAnimator.mm',root);
const stackAnimatorSource=readFileSync(stackAnimatorURL,'utf8');
const stackAnimatorUpdated=restoreSimplePushAnimator(stackAnimatorSource);
if(stackAnimatorUpdated!==stackAnimatorSource)writeFileSync(stackAnimatorURL,stackAnimatorUpdated);
