import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {readFileSync} from 'node:fs';

// LavaScrollView inherits two implementation hooks from this exact RN owner.
// Its source accompanies the pinned prebuilt core; upgrades require review of
// the hooks and the normal/cross-fade full-app geometry regressions.
export function verifyScrollOwner(source){
  assert.equal(createHash('sha256').update(source).digest('hex'),
    '787df789fab4fab9cb205f591d2ebc5aa12a8db4132c46308f65fff48e04e86b',
    'Native scroll owner changed; review LavaScrollView before building.');
}
export function verifyInstalledScrollOwner(){
  verifyScrollOwner(readFileSync(new URL('../../node_modules/react-native/React/Fabric/Mounting/ComponentViews/ScrollView/RCTScrollViewComponentView.mm',import.meta.url)));
}
