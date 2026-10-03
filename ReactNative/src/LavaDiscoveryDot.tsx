import type {NativeBottomTabNavigationOptions} from '@react-navigation/bottom-tabs/unstable';
import {View} from 'react-native';
import {colors} from './colors.ios';
import {foundation} from './foundation';
import {lavaTokens} from './generated/tokens';

/** Non-interactive discovery mark; its enclosing control owns the “New” hint. */
export function LavaDiscoveryDot({testID}:{testID?:string}) {
  return <View testID={testID} accessible={false} accessibilityElementsHidden
    style={{width:foundation.discovery.dotSize,height:foundation.discovery.dotSize,
      borderRadius:foundation.radius.circle,backgroundColor:colors.lavaOrange}}/>;
}

/** Native tabs compose the mark into the symbol; UIKit badges cannot be made this small. */
export function discoveryTabIcon(symbol:string,unseen:boolean,scheme:'light'|'dark',focused:boolean) {
  const hex=(values:readonly number[])=>values.map(value=>Math.round(value*255).toString(16).padStart(2,'0')).join('');
  const tint=focused?hex(lavaTokens.colors.safeGreen[scheme]):scheme==='dark'?'ffffff':'000000';
  return {type:'sfSymbol' as const,name:unseen
    ? `lava.discovery|${symbol}|${tint}|${hex(lavaTokens.colors.lavaOrange[scheme])}`
    : symbol} as Exclude<NativeBottomTabNavigationOptions['tabBarIcon'],Function|undefined>;
}
