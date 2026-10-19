import type {ReactNode} from 'react';
import {View,type ColorValue} from 'react-native';
import {Text} from '../../../app/presentation';
import {colors} from '../../colors';
import type {PasscodeState} from './types';

/** Platform input and glyph atoms keep their native implementation; RN owns the composition. */
export function PasscodeScreen({state,digits,input,glyph,onRefocus,contentInsets,messageColor=colors.errorText,titleColor=colors.primaryText,titleContent,subtitleContent,messageContent}:{
  state:PasscodeState;digits:ReactNode;input:ReactNode;glyph:ReactNode;onRefocus?:()=>void;
  contentInsets?:Readonly<{top:number;right:number;bottom:number;left:number}>;messageColor?:ColorValue;titleColor?:ColorValue;
  titleContent?:ReactNode;subtitleContent?:ReactNode;messageContent?:ReactNode;
}){
  return <View testID="passcode-screen" onTouchEnd={onRefocus} style={{flex:1,padding:24,
    paddingTop:24+(contentInsets?.top??0),paddingRight:24+(contentInsets?.right??0),
    paddingBottom:24+(contentInsets?.bottom??0),paddingLeft:24+(contentInsets?.left??0),
    gap:28,alignItems:'center',backgroundColor:colors.groupedBackground}}>
    <View style={{flex:1}}/>{glyph}
    <View style={{gap:8,alignItems:'center',alignSelf:'stretch'}}>
      {titleContent===undefined?<Text verbatim dynamicTypeRamp="title1" style={{fontSize:28,fontWeight:'700',color:titleColor}}>{state.title}</Text>:titleContent}
      {subtitleContent===undefined?<Text verbatim dynamicTypeRamp="subheadline" style={{fontSize:15,color:colors.secondaryText,textAlign:'center'}}>{state.subtitle}</Text>:subtitleContent}
    </View>
    {digits}
    {!!state.message&&(messageContent===undefined?<Text verbatim dynamicTypeRamp="footnote" style={{fontSize:13,fontWeight:'600',color:messageColor}}>{state.message}</Text>:messageContent)}
    {input}<View style={{flex:1}}/>
  </View>;
}
