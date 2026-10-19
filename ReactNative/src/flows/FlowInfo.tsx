import type {PropsWithChildren} from 'react';
import {View} from 'react-native';
import {localized} from '../../app/presentation';
import {colors} from '../colors';
import {Copy,Panel,InlineSymbolText} from './info-ui';

export type FlowInfoProps=PropsWithChildren<{title:string;description?:string;icon?:string;warning?:boolean;tone?:'green'|'warning'|'neutral'}>;
/** RN owns the information panel. The platform supplies one inline text run. */
export function FlowInfo({title,description,icon,warning=false,tone=warning?'warning':'green',children}:FlowInfoProps){
  const label=[localized(title),description&&localized(description)].filter(Boolean).join(', ');
  return <Panel warning={warning}><View style={{gap:8}}><View accessible accessibilityLabel={label} style={{gap:10}}>
    <InlineSymbolText title={title} symbol={icon??''} tintColor={tone==='warning'?colors.lavaOrange:tone==='neutral'?colors.secondaryText:colors.safeGreen}
      textColor={colors.ink} fontSize={17} fontWeight="semibold"/>
    {description&&<Copy role="supporting" color={colors.secondaryText}>{description}</Copy>}
  </View>{children}</View></Panel>;
}
