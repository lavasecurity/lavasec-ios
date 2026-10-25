import type {PropsWithChildren} from 'react';
import {StyleSheet,View} from 'react-native';
import {Copy,Group,Section} from './ui';
import {colors} from '../colors';
import {foundation} from '../foundation';
import {useScaffoldStyles} from '../window-layout';

// Setup pages share the ordinary responsive typography and spacing policy.
// Keep badges intrinsic so larger Dynamic Type can grow their row naturally.
export function SetupSection({title,steps,footer,children}:PropsWithChildren<{title:string;steps:readonly string[];footer?:string}>){
  const styles=useScaffoldStyles(baseStyles);
  return <Section title={title} footer={footer}><Group><View style={styles.instructions}>
    {steps.map((step,index)=><View key={step} style={styles.row}>
      <View style={styles.badge}><Copy role="row" color={colors.safeGreen} verbatim>{String(index+1)}</Copy></View>
      <View style={styles.body}><Copy role="supporting" color={colors.primaryText}>{step}</Copy></View>
    </View>)}
  </View>{children}</Group></Section>;
}
const baseStyles=StyleSheet.create({
  instructions:{paddingHorizontal:foundation.space.infoPanelHorizontalInset,paddingVertical:foundation.space.infoPanelVerticalInset,gap:foundation.space.md},
  row:{flexDirection:'row',alignItems:'baseline',gap:foundation.space.md},
  badge:{minWidth:22,minHeight:22,borderRadius:11,backgroundColor:colors.softGreen,alignItems:'center',justifyContent:'center'},
  body:{flex:1},
});
