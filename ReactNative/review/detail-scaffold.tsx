import {useState,type PropsWithChildren,type ReactNode} from 'react';
import {activityBranches} from './activity-model';
import {Pressable, StyleSheet, TextInput, View, type TextInputProps} from 'react-native';
import {Text, localized, localizedNumber} from '../app/presentation';
import {useTextScale} from '../app/text-metrics';
import {colors} from '../src/colors.ios';
import {foundation} from '../src/foundation';
import {Copy,Symbol} from './primitives';
import {AdaptivePair, Info, InputRow, Panel} from './scaffold';

// Counts retain their units. Equal-sized legend marks identify categories;
// proportions are used only when both values measure the same thing.
export function CountLegend({label,count,tone,detail,value,dimmed=false}:{label:string;count?:number;tone:'allowed'|'blocked'|'personal';detail?:string;value?:string;dimmed?:boolean}) {
  const empty=count===0||count===undefined;
  const displayed=`${value??(count===undefined?'—':localizedNumber(count))}${detail?` · ${detail}`:''}`;
  return <View testID={`legend.${tone}`} accessible accessibilityLabel={`${localized(label)}, ${displayed}`} style={{flexDirection:'row',alignItems:'center',gap:foundation.space.sm,opacity:dimmed?0.35:1}}>
    <View accessible={false} style={{opacity:empty?0.4:1}}><Symbol name={tone==='allowed'?foundation.outcome.allowed:foundation.outcome.blocked} size={20} tone={empty?'secondary':tone==='allowed'?'green':'accentOrange'}/></View>
    <View style={{flex:1}}><Copy role="supporting" color={colors.secondaryText}>{label}</Copy></View>
    <View style={{flex:1,alignItems:'flex-end'}}><Copy role="supporting" verbatim>{displayed}</Copy></View>
  </View>;
}
export function ProportionBar({allowed,blocked}:{allowed:number;blocked:number}) {
  return <ActivityFlowBar allowed={allowed} blocked={blocked} compact/>;
}

// Both densities share square inner ends and one clipped, rounded outer contour.
export function ActivityFlowBar({allowed,blocked,compact=false}:{allowed:number;blocked:number;compact?:boolean}) {
  const [width,setWidth]=useState(0);const branches=activityBranches(width,allowed,blocked);
  return <View testID="activity.flow-bar" accessible={false} onLayout={event=>setWidth(event.nativeEvent.layout.width)} style={[detailStyles.flowBar,compact&&{height:8},{gap:branches.gap}]}>
    {blocked>0&&<View testID="activity.flow.blocked" style={[detailStyles.blockedBar,{width:branches.blocked}]}/>}
    {allowed>0&&<View testID="activity.flow.allowed" style={[detailStyles.allowedBar,{width:branches.allowed}]}/>}
    {!compact&&<View pointerEvents="none" style={detailStyles.flowOutline}/>}
  </View>;
}

// Shared compositions for detail pages. Data geometry may vary with a query or
// board size; typography, controls and surface treatment stay defined here.
export function DetailNotice({title,description,icon,children}:PropsWithChildren<{title:string;description:string;icon:string}>) {
  return <Info title={title} description={description} icon={icon}>{children}</Info>;
}

export function DetailSteps({titles,current,furthest,onSelect,disabled=false}:{titles:readonly string[];current:number;furthest:number;onSelect:(step:number)=>void;disabled?:boolean}) {
  return <View style={detailStyles.actions}>{titles.map((title,index)=><Pressable key={title} accessibilityRole="button"
    accessibilityLabel={`${index+1}. ${localized(title)}`} accessibilityState={{selected:current===index,disabled:disabled||index>furthest}}
    disabled={disabled||index>furthest} onPress={()=>onSelect(index)} style={({pressed})=>[detailStyles.step,current===index&&detailStyles.stepSelected,(disabled||index>furthest)&&detailStyles.disabled,pressed&&detailStyles.pressed]}>
    <Copy role="caption" weight="600" center>{`${index+1}. ${localized(title)}`}</Copy>
  </Pressable>)}</View>;
}

export function DetailField({title,compactMultiline=false,...props}:TextInputProps&{title:string;compactMultiline?:boolean}) {
  const scale=useTextScale();
  const lineHeight=foundation.type.body.fontSize*1.4*scale;
  const minHeight=props.multiline?(compactMultiline?lineHeight:Math.max(foundation.control.target*3,lineHeight)):Math.max(foundation.control.target,lineHeight);
  return <InputRow title={title}><TextInput {...props} allowFontScaling={false} accessibilityLabel={localized(title)}
    placeholder={props.placeholder?localized(props.placeholder):undefined} placeholderTextColor={colors.tertiaryText}
    style={[detailStyles.input,{fontSize:foundation.type.body.fontSize*scale,minHeight}]}/></InputRow>;
}

export function DetailValues({rows,metadata=false,pending=false}:{rows:readonly (readonly string[])[];metadata?:boolean;pending?:boolean}) {
  return <View style={detailStyles.stack}>{rows.map(([label,value],index)=><View key={label} style={detailStyles.stack}>
    {index>0&&<View style={detailStyles.divider}/>}
    <View accessible accessibilityRole="text" testID={`diagnostic.${label}`} accessibilityState={{busy:pending}}
      accessibilityLabel={`${localized(label??'')}, ${pending?localized('Loading…'):localized(value??'')}`}>
      <AdaptivePair alignment="trailing" label={<Text accessible={false} allowFontScaling dynamicTypeRamp="subheadline" style={[detailStyles.valueLabel,metadata&&detailStyles.numeral]}>{label}</Text>}>
        <Text accessible={false} allowFontScaling dynamicTypeRamp="subheadline" style={[detailStyles.value,metadata&&detailStyles.numeral]}>{value}</Text>
      </AdaptivePair>
    </View>
  </View>)}</View>;
}

export function DetailReviewValue({label,children,divider=false}:{label:string;children:ReactNode;divider?:boolean}) {
  return <View style={detailStyles.tightStack}>{divider&&<View style={detailStyles.divider}/>}<InputRow title={label}><Copy role="body">{children}</Copy></InputRow></View>;
}

export const detailStyles=StyleSheet.create({
  stack:{gap:foundation.space.md},
  tightStack:{gap:foundation.space.sm},
  row:{flexDirection:'row',alignItems:'center',gap:foundation.space.sm},
  flex:{flex:1},
  right:{alignItems:'flex-end'},
  actions:{flexDirection:'row',gap:foundation.space.md},
  insetStack:{paddingHorizontal:foundation.row.horizontalInset,paddingVertical:foundation.row.verticalInset,gap:foundation.space.md},
  expanded:{paddingHorizontal:foundation.row.horizontalInset,paddingBottom:foundation.row.verticalInset,gap:foundation.space.sm},
  divider:{height:StyleSheet.hairlineWidth,backgroundColor:colors.separator},
  pressed:{opacity:foundation.interaction.pressedOpacity},
  disabled:{opacity:0.45},
  step:{flex:1,minHeight:foundation.control.target,alignItems:'center',justifyContent:'center',padding:foundation.space.sm,borderRadius:foundation.radius.control,backgroundColor:colors.cardBackground},
  stepSelected:{backgroundColor:colors.softGreen},
  input:{minHeight:foundation.control.target,fontSize:foundation.type.body.fontSize,color:colors.primaryText,textAlignVertical:'top'},
  multilineInput:{minHeight:foundation.control.target*3},
  valueLabel:{fontSize:foundation.type.supporting.fontSize,color:colors.primaryText},
  value:{fontSize:foundation.type.supporting.fontSize,color:colors.secondaryText,textAlign:'right',alignSelf:'stretch'},
  numeral:{fontVariant:['tabular-nums']},
  record:{paddingHorizontal:foundation.row.horizontalInset,paddingVertical:foundation.row.verticalInset,gap:foundation.space.sm},
  recordMeta:{flexDirection:'row',flexWrap:'wrap',alignItems:'center',gap:foundation.space.sm},
  recordTime:{fontSize:foundation.type.caption.fontSize,fontVariant:['tabular-nums'],color:colors.secondaryText},
  stat:{flexDirection:'row',alignItems:'center',gap:foundation.space.md},
  statIcon:{width:foundation.control.glyphSlot,alignItems:'center'},
  statValue:{fontSize:foundation.type.supporting.fontSize,fontWeight:'600',color:colors.ink,fontVariant:['tabular-nums'],flexShrink:1},
  flowOutline:{...StyleSheet.absoluteFill,borderWidth:1,borderRadius:foundation.radius.circle,borderColor:colors.panelStroke},
  flowBar:{height:14,borderRadius:foundation.radius.circle,overflow:'hidden',flexDirection:'row',direction:'ltr',backgroundColor:colors.disabledSurface},
  allowedBar:{height:14,backgroundColor:colors.safeGreen},
  blockedBar:{height:14,backgroundColor:colors.lavaOrange},
});
