import type {NativeStackHeaderItem} from '@react-navigation/native-stack';
import {localized} from '../../../app/presentation';
import {colors} from '../../colors.ios';
import type {LavaToolbarAction} from '../contracts';
import {toolbarSymbols,toolbarActionSymbols} from './ios/icons';

export type ToolbarSymbol = keyof typeof toolbarSymbols;
// All actions use the navigation bar's own item pipeline, including Import.
// Stable semantic identifiers let UIKit match like actions across transitions.
export const toolbarButton = (label: string, symbol: keyof typeof toolbarSymbols, onPress: () => void, disabled = false, testID?:string, background:'shared'|'none'='shared'): NativeStackHeaderItem & {label:string;onPress:()=>void;disabled:boolean} => {
  const action=toolbarSymbols[symbol];
  if(!action)throw new Error(`Unregistered toolbar glyph: ${symbol}`);
  const tintColor=action==='confirm'?colors.safeControlGreen:action==='delete'?colors.errorText:colors.navigationForeground;
  return {type:'button',label:localized(label),accessibilityLabel:localized(label),identifier:action==='import'?'lava.toolbar.labeled.import':testID??`lava.toolbar.${action}`,
    icon:{type:'sfSymbol',name:symbol},tintColor,variant:action==='confirm'?'prominent':'plain',onPress,disabled,sharesBackground:action!=='confirm',hidesSharedBackground:background==='none'};
};
export function toolbarToggle(label:string,symbol:keyof typeof toolbarSymbols,selected:boolean,onPress:()=>void,disabled=false,testID?:string) {
  return {...toolbarButton(label,symbol,onPress,disabled,testID),selected,sharesBackground:false,
    variant:selected?'prominent' as const:'plain' as const,tintColor:selected?colors.safeControlGreen:colors.navigationForeground};
}
/** Semantic entry point; legacy symbol callers keep the same native pipeline. */
export function toolbarAction(label:string,action:LavaToolbarAction,onPress:()=>void,disabled=false,testID?:string,background:'shared'|'none'='shared') {
  return toolbarButton(label,toolbarActionSymbols[action],onPress,disabled,testID,background);
}
