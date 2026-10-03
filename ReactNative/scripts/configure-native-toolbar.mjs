// RNScreens' default SF Symbols inherit navigation-bar Dynamic Type metrics.
// At AXXXXL, square.and.pencil produces 45 × 44 chrome. Apply the same fixed
// optical sizes as NativeToolbarIconButton, leaving the native chrome/target intact.
import {readFileSync,writeFileSync} from 'node:fs';
import {createHash} from 'node:crypto';
import assert from 'node:assert/strict';
import {fileURLToPath} from 'node:url';
import {parseTokens,sourceURL} from './generate-tokens.mjs';

const nativePath=new URL('../node_modules/react-native-screens/ios/RNSBarButtonItem.mm',import.meta.url);
const upstreamHash='869bd57c319e3618f21bd5e67a85bda8322edb3610744380f1eb0b021876bc44';
const anchor='                         self.image = img;';
const start='                         // Lava fixed toolbar symbol metrics.\n';
const end='                         // End Lava toolbar symbol metrics.\n';

export function configuredToolbar(source,metrics) {
  // Strip only our delimited insertion before verifying the exact pinned upstream.
  const begin=source.indexOf(start),finish=source.indexOf(end);
  const clean=begin<0?source:source.slice(0,begin)+source.slice(finish+end.length);
  assert.ok(begin<0||finish>begin,'Incomplete native toolbar patch');
  // Main also adapts this file for labeled toolbar items during native setup.
  // Verify the dependency after removing only that delimited adapter.
  const upstream=clean.replace(/  \/\/ Lava: visible icon \+ title[\s\S]*?  \/\/ Lava: end native labeled toolbar item\.\n/,'');
  assert.equal(createHash('sha256').update(upstream).digest('hex'),upstreamHash,'Native toolbar dependency changed; review its implementation before updating the patch');
  for(const key of ['chevronIconPointSize','xmarkIconPointSize','plusIconPointSize','checkmarkIconPointSize','wideIconPointSize','framedIconPointSize']) {
    assert.ok(Number.isFinite(metrics[key])&&metrics[key]>0&&metrics[key]<=24,`Invalid toolbar metric ${key}`);
  }
  const patch=start+`                         NSString *symbolName = dict[@"sfSymbolName"];
                         if (symbolName != nil) {
                           CGFloat pointSize = [symbolName isEqualToString:@"chevron.left"] ? ${metrics.chevronIconPointSize}
                             : [symbolName isEqualToString:@"xmark"] ? ${metrics.xmarkIconPointSize}
                             : [symbolName isEqualToString:@"plus"] ? ${metrics.plusIconPointSize}
                             : [symbolName isEqualToString:@"checkmark"] ? ${metrics.checkmarkIconPointSize}
                             : [symbolName isEqualToString:@"trash"] ? ${metrics.wideIconPointSize} : ${metrics.framedIconPointSize};
                           img = [img imageByApplyingSymbolConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:pointSize weight:UIImageSymbolWeightSemibold]];
                           if ([dict[@"variant"] isEqualToString:@"prominent"] && ![dict[@"disabled"] boolValue]) {
                             img = [img imageWithTintColor:UIColor.whiteColor renderingMode:UIImageRenderingModeAlwaysOriginal];
                           }
                         }
`+end;
  return clean.replace(anchor,patch+anchor);
}

export function configureNativeToolbar() {
  const source=readFileSync(nativePath,'utf8');
  const output=configuredToolbar(source,parseTokens(readFileSync(sourceURL,'utf8')).toolbar);
  if(source!==output)writeFileSync(nativePath,output);
}
if(process.argv[1]===fileURLToPath(import.meta.url))configureNativeToolbar();
