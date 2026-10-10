import type {PropsWithChildren} from 'react';
import {Platform,PlatformColor,Pressable,StyleSheet,View,type ColorValue} from 'react-native';
import {Text} from '../app/presentation';
import {colors} from './colors.ios';
import {foundation} from './foundation';

// Navigation, status and labeled controls share the actual title/summary stack.
// Interaction and surfaces belong to their respective containing components.
export function LavaRowLabel({title,summary,titleRole='rowTitle',verbatimTitle=false,verbatimSummary=false,disabled=false,accessible,titleColor,strike=false,children}:PropsWithChildren<{
  title:string;summary?:string;titleRole?:'rowTitle'|'cardTitle';verbatimTitle?:boolean;verbatimSummary?:boolean;disabled?:boolean;accessible?:boolean;titleColor?:ColorValue;strike?:boolean;
}>) {
  const type=titleRole==='cardTitle'?foundation.type.section:foundation.type.row;
  return <View style={styles.labelStack}>
    <Text accessible={accessible} verbatim={verbatimTitle} allowFontScaling dynamicTypeRamp={type.dynamicTypeRamp}
      style={[styles.title,{fontSize:type.fontSize,fontWeight:type.fontWeight},titleRole==='cardTitle'&&{color:Platform.OS==='ios'?PlatformColor('label'):colors.primaryText},titleColor!==undefined&&{color:titleColor},disabled&&styles.muted,strike&&styles.strike]}>{title}</Text>
    {!!summary&&<Text accessible={accessible} verbatim={verbatimSummary} allowFontScaling dynamicTypeRamp={foundation.type.supporting.dynamicTypeRamp}
      style={styles.summary}>{summary}</Text>}
    {children}
  </View>;
}

export function LavaControlContent({title,summary,titleRole,verbatimTitle=false,children,onLabelPress,disabled=false,testID}:PropsWithChildren<{
  title?:string;summary?:string;titleRole?:'rowTitle'|'cardTitle';verbatimTitle?:boolean;onLabelPress?:()=>void;disabled?:boolean;testID?:string;
}>) {
  const label=title&&<LavaRowLabel title={title} summary={summary} titleRole={titleRole} verbatimTitle={verbatimTitle} disabled={disabled} accessible={onLabelPress?false:undefined}/>;
  return <View style={styles.control}>
    {label&&(onLabelPress
      ? <Pressable testID={testID===undefined?undefined:`${testID}.label`} accessible={false} disabled={disabled} onPress={onLabelPress}
          hitSlop={{left:foundation.row.horizontalInset,right:foundation.space.sm}} style={styles.label}>{label}</Pressable>
      : <View style={styles.label}>{label}</View>)}
    <View style={[styles.controlSlot,!title&&styles.fill]}>{children}</View>
  </View>;
}

const styles=StyleSheet.create({
  labelStack:{gap:foundation.row.metadataGap},
  title:{fontSize:foundation.type.row.fontSize,fontWeight:foundation.type.row.fontWeight,color:colors.primaryText},
  summary:{fontSize:foundation.type.supporting.fontSize,fontWeight:foundation.type.supporting.fontWeight,color:colors.secondaryText},
  muted:{color:colors.secondaryText},
  strike:{textDecorationLine:'line-through'},
  control:{alignSelf:'stretch',minHeight:foundation.row.standard,paddingHorizontal:foundation.row.horizontalInset,flexDirection:'row',alignItems:'center',gap:foundation.row.gap},
  // The label owns its vertical inset so the entire row height stays tappable.
  label:{flex:1,minWidth:0,alignSelf:'stretch',justifyContent:'center',paddingVertical:foundation.row.verticalInset},
  // Center touch targets beside the padded label, without padding them a second time.
  controlSlot:{minHeight:foundation.control.target,flexDirection:'row',alignItems:'center'},
  fill:{flex:1},
});
