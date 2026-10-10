import {render} from '@testing-library/react-native';
import {LinearGradient,Mask,Stop} from 'react-native-svg';
import {GuardianDrawing} from '../src/GuardianDrawing';
import {guardianPalettes,guardianPaletteKeys} from '../src/guardian-palettes';
import {stableGuardianFrame} from '../src/guardian-motion';
import * as motion from '../src/guardian-motion';

const {readFileSync}=require('node:fs') as {readFileSync:(path:string,encoding:'utf8')=>string};
declare const __dirname:string;
const native=readFileSync(require('node:path').join(__dirname,'../../Shared/LavaActivityAttributes.swift'),'utf8');
const style=native.slice(native.indexOf('enum GuardianShieldStyle'),native.indexOf('    var id:'));
const ids=[...style.matchAll(/^    case (\w+)(?: = "([^"]+)")?/gm)].map(match=>match[2]??match[1]!);
const rgb=(color:readonly number[])=>`rgb(${color.slice(0,3).map(value=>Math.round(value*255)).join(',')})`;

test('mounting a waking guardian paints the sleeping origin before the first animation effect',()=>{
  const eye=jest.spyOn(motion,'guardianEye');
  const view=render(<GuardianDrawing size={128} mood="waking" look="original"/>);
  expect(eye.mock.calls[0]?.[0]).toEqual(stableGuardianFrame('sleeping'));
  view.unmount();eye.mockRestore();
});

test('every persisted native Guard ID selects its shared palette without using Swift case aliases',()=>{
  expect(ids).toEqual(['original','emberObsidian','purpleObsidian','obsidian','strawberryObsidian','emerald','kiwiCreme','aquamarine']);
  expect(Object.keys(guardianPaletteKeys).sort()).toEqual(ids.filter(id=>id!=='original').sort());
  expect(guardianPaletteKeys.emberObsidian).toBe('ember');
  expect(guardianPaletteKeys.strawberryObsidian).toBe('cherryQuartz');
});

test.each(ids)('actual drawing paints the native persisted look %s',look=>{
  const view=render(<GuardianDrawing size={128} mood="awake" look={look} frame={stableGuardianFrame('awake')} colorScheme="light"/>);
  const key=guardianPaletteKeys[look];
  const gradients=view.UNSAFE_getAllByType(LinearGradient);
  const masks=view.UNSAFE_queryAllByType(Mask);
  if(!key){expect(gradients).toHaveLength(1);expect(masks).toHaveLength(0);}
  else {
    expect(gradients).toHaveLength(3);expect(masks).toHaveLength(1);
    const palette=guardianPalettes[key];
    const inner=gradients.find(gradient=>String(gradient.props.id).endsWith('inner'))!;
    expect(inner.findAllByType(Stop).map((stop:{props:{stopColor:string}})=>stop.props.stopColor)).toEqual([
      rgb(palette.innerTop),rgb(palette.innerMid),rgb(palette.innerBottom),
    ]);
    const shell=gradients.find(gradient=>String(gradient.props.id).endsWith('shell'))!;
    expect(shell.findAllByType(Stop).map((stop:{props:{stopColor:string}})=>stop.props.stopColor)).toEqual([
      rgb(palette.shellTop),rgb(palette.shellMid),rgb(palette.shellDeep),rgb(palette.shellBottom),
    ]);
  }
  if(look==='strawberryObsidian'){
    const shadow=view.UNSAFE_getAllByType(require('react-native').View).find(node=>node.props.style?.shadowColor);
    expect(shadow?.props.style.shadowColor).toBe('rgb(255,148,199)');
  }
});
