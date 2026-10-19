/** Match the .ts fallback so Metro selects these cycle-free iOS bindings first. */
import {createElement,type PropsWithChildren} from 'react';
import {View,type ColorValue} from 'react-native';
import {LavaCard} from '../components.ios';
import {colors} from '../colors.ios';
import {foundation} from '../foundation';
export {Copy} from '../../review/primitives';
export {InlineSymbolText} from './InlineSymbolText.ios';

// Native LavaInfoPanel → LavaInfoCard has no outline unless its caller supplies
// an explicit warning/accent border. Retain the canonical card geometry.
export function Panel({children,warning=false,accent}:PropsWithChildren<{warning?:boolean;accent?:ColorValue}>){
  // LavaInfoCard applies its58pt row floor after12pt top/bottom padding, centered.
  // Floor only the unpadded body so longer/multiline content keeps its own size.
  const body=createElement(View,{style:{minHeight:foundation.row.standard-foundation.space.infoPanelVerticalInset*2,justifyContent:'center'}},children);
  return createElement(View,null,createElement(LavaCard,{role:'panel',borderColor:warning||accent?accent??colors.lavaOrange:null,children:body}));
}
