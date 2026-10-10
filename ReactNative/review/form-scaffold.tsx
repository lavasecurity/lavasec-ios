import {createContext,useContext,useLayoutEffect,useRef,useState,type ComponentRef,type PropsWithChildren,type ReactNode,type Ref,type RefObject} from 'react';
import {KeyboardAvoidingView,Platform,PlatformColor,Pressable,ScrollView,StyleSheet,View,useWindowDimensions,type TextProps} from 'react-native';
import {SafeAreaInsetsContext} from 'react-native-safe-area-context';
import {colors} from '../src/colors';
import {foundation} from '../src/foundation';
import {lavaTokens} from '../src/generated/tokens';
import {useLavaColorScheme} from '../src/appearance';
import Decoration from '../specs/LavaDecorationNativeComponent';
import {localized,localizedFormat,localizedNumber,Text} from '../app/presentation';
import {useTextScale} from '../app/text-metrics';
import {usePresentationNativeLayout} from '../app/use-presentation-readiness';
import {Group,InputRow,useSheetHeaderInset} from './scaffold';
import {Copy} from './primitives';
import {BufferedInput,type BufferedInputHandle,type BufferedInputProps} from './BufferedInput';

const SheetScrollContext=createContext<{height:number;headerInset:number;scroll:RefObject<ComponentRef<typeof ScrollView>|null>}>({height:0,headerInset:0,scroll:{current:null}});
/** Match the native fixed editor: shorten to the measured scroll viewport and
 * reveal only on focus/viewport changes, never on typing or a manual scroll. */
export function useSheetEditorViewport(input:RefObject<BufferedInputHandle|null>,focused:boolean,fixedHeight:number){
  const {height:viewport,headerInset,scroll}=useContext(SheetScrollContext);
  const height=focused&&viewport>0?Math.min(fixedHeight,Math.max(44,viewport-16)):fixedHeight;
  useLayoutEffect(()=>{
    if(!focused||viewport<=0)return;
    const frame=requestAnimationFrame(()=>{
      const inner=scroll.current?.getInnerViewRef();
      if(inner)input.current?.measureLayout(inner,(_x,y)=>scroll.current?.scrollTo({y:Math.max(-headerInset,y-headerInset-8),animated:false}),()=>{});
    });
    return()=>cancelAnimationFrame(frame);
  },[focused,viewport,headerInset,height,input,scroll]);
  return height;
}

/** Native ViewThatFits chooses one row or a complete vertical action group. */
export function FormActions({titles,children}:{titles:readonly string[];children:readonly ReactNode[]}){
  const [width,setWidth]=useState(0);const [natural,setNatural]=useState<Record<string,number>>({});
  const inset=foundation.row.horizontalInset*2;
  const measured=titles.every(title=>natural[title]!==undefined);
  const total=titles.reduce((sum,title)=>sum+(natural[title]??0)+inset,0)+(titles.length-1)*12;
  const stacked=width>0&&measured&&total>width;
  return <View onLayout={event=>setWidth(event.nativeEvent.layout.width)}>
    <View pointerEvents="none" accessibilityElementsHidden importantForAccessibility="no-hide-descendants" style={{position:'absolute',width:10000,opacity:0,flexDirection:'row'}}>
      {titles.map(title=><Text key={title} allowFontScaling dynamicTypeRamp="headline" onTextLayout={event=>{const value=event.nativeEvent.lines[0]?.width??0;setNatural(old=>old[title]===value?old:{...old,[title]:value});}} style={{fontSize:17,fontWeight:'600'}}>{title}</Text>)}
    </View>
    <View style={{flexDirection:stacked?'column':'row',gap:12}}>{children.map((child,index)=><View key={index} style={stacked?{}:{flex:1,...(measured?{minWidth:natural[titles[index]!]!+inset}:{})}}>{child}</View>)}</View>
  </View>;
}

// A native-hosted modal already has a UIKit sheet. Its RN content owns ordinary
// scrolling and the bottom action inset without presenting a second sheet.
export function FlowSheet({children,header,footer,scrolls=true,feedback=false,centered=false,nativeKeyboardAvoidance=false}:PropsWithChildren<{header?:ReactNode;footer?:ReactNode;scrolls?:boolean;feedback?:boolean;centered?:boolean;nativeKeyboardAvoidance?:boolean}>){
  const nativeLayout=usePresentationNativeLayout();
  const insets=useContext(SafeAreaInsetsContext);const {width,height}=useWindowDimensions();const compact=!centered&&width>height;
  const horizontalPadding=insets&&(insets.left!==0||insets.right!==0)?{
    paddingLeft:foundation.space.screenHorizontal+insets.left,paddingRight:foundation.space.screenHorizontal+insets.right,
  }:undefined;
  const horizontalReadingInsets=horizontalPadding?{...horizontalPadding,maxWidth:foundation.layout.readingWidth+insets!.left+insets!.right}:undefined;
  const headerInset=useSheetHeaderInset();
  const scroll=useRef<ComponentRef<typeof ScrollView>>(null);const [viewport,setViewport]=useState(0);
  const content=<View style={{gap:18,...(centered?{flexGrow:1,justifyContent:'center' as const}: {})}}>{children}{compact&&footer&&<View style={{paddingBottom:24}}>{footer}</View>}</View>;
  // The native WireGuard host already shortens for UIKit's keyboard. Applying
  // padding again creates transient viewports and changes its retained offset.
  // Safe sides pad each content slot once; inline compact actions inherit their
  // scroll body's padding. The scroll viewport remains full-width for UIKit.
  return <SheetScrollContext.Provider value={{height:Math.max(0,viewport-headerInset),headerInset,scroll}}><KeyboardAvoidingView behavior={Platform.OS==='ios'&&!nativeKeyboardAvoidance?'padding':undefined} style={{flex:1,backgroundColor:colors.groupedBackground}}>
    {header&&<View style={{paddingHorizontal:foundation.space.screenHorizontal,paddingTop:12,paddingBottom:10,...horizontalPadding}}>{header}</View>}
    {scrolls?<ScrollView ref={scroll} onLayout={event=>{nativeLayout(event);setViewport(event.nativeEvent.layout.height);}} keyboardShouldPersistTaps="handled" keyboardDismissMode="interactive"
      contentInsetAdjustmentBehavior="automatic" showsVerticalScrollIndicator={false}
      contentContainerStyle={{width:'100%',maxWidth:foundation.layout.readingWidth,alignSelf:'center',paddingHorizontal:foundation.space.screenHorizontal,paddingTop:centered?18:feedback?16:28,paddingBottom:centered?18:compact&&footer?0:44,...(centered?{flexGrow:1}: {}),...horizontalReadingInsets}}>{content}</ScrollView>
      :<View onLayout={nativeLayout} style={{flex:1,paddingHorizontal:foundation.space.screenHorizontal,paddingTop:16,paddingBottom:24,...horizontalPadding}}>{content}</View>}
    {!compact&&footer&&<View>{feedback&&<FormDivider/>}<View style={{width:'100%',maxWidth:foundation.layout.readingWidth,alignSelf:'center',paddingHorizontal:foundation.space.screenHorizontal,paddingTop:12,paddingBottom:(feedback?12:24)+(insets?.bottom??0),...horizontalReadingInsets}}>{footer}</View></View>}
  </KeyboardAvoidingView></SheetScrollContext.Provider>;
}
const formLabel=Platform.OS==='ios'?PlatformColor('label'):colors.primaryText;

// Native text captures retain a natural first/last line box and add leading
// between lines. These roles reproduce the form/diagnostics paragraph metrics
// without changing existing settings and story typography.
export function FormParagraph({children,textRole='supporting',verbatim=false,...props}:TextProps&{textRole?:'supporting'|'note'|'body';verbatim?:boolean}){
  const metrics=textRole==='body'?{fontSize:17,lineHeight:22,ramp:'body' as const,leading:5/6,color:formLabel}:
    textRole==='note'?{fontSize:13,lineHeight:18,ramp:'footnote' as const,leading:1,color:colors.secondaryText}:
    {fontSize:15,lineHeight:20,ramp:'subheadline' as const,leading:1,color:colors.secondaryText};
  const scale=useTextScale(metrics.ramp);
  return <Text {...props} verbatim={verbatim} allowFontScaling dynamicTypeRamp={metrics.ramp}
    style={[{fontSize:metrics.fontSize,lineHeight:metrics.lineHeight,marginVertical:-metrics.leading*scale,color:metrics.color},props.style]}>{children}</Text>;
}
export function FormCardTitle({children}:PropsWithChildren){return <Copy role="section" color={formLabel}>{children}</Copy>;}
export function FormReviewValue({label,value,divider=false,dividerGap=12}:{label:string;value:string;divider?:boolean;dividerGap?:number}){
  return <View style={{gap:dividerGap}}>{divider&&<FormDivider/>}<InputRow title={label}><FormParagraph textRole="body" verbatim>{value}</FormParagraph></InputRow></View>;
}
export function FormIntro({summary}:{summary:string}){
  return <Group tone="green"><View style={{padding:foundation.space.lg}}><FormParagraph style={{color:colors.primaryText}}>{summary}</FormParagraph></View></Group>;
}

/** Match LavaDiagnosticValueRow: adjacent natural-width values, or the whole
 * label/value pair stacked when it cannot fit. Values remain verbatim. */
export function DiagnosticValue({label,value}:{label:string;value:string}){
  const {width:windowWidth}=useWindowDimensions();
  const [width,setWidth]=useState(Math.min(windowWidth,foundation.layout.readingWidth)-foundation.space.screenHorizontal*2-foundation.space.lg*2);
  const [natural,setNatural]=useState<Record<string,number>>({});
  const stacked=natural.label!==undefined&&natural.value!==undefined&&natural.label+natural.value+12>width;
  return <View onLayout={event=>setWidth(event.nativeEvent.layout.width)}>
    <View pointerEvents="none" accessibilityElementsHidden importantForAccessibility="no-hide-descendants" style={{position:'absolute',width:10000,opacity:0,flexDirection:'row'}}>
      <Text allowFontScaling dynamicTypeRamp="subheadline" onTextLayout={event=>{const size=event.nativeEvent.lines[0]?.width??0;setNatural(old=>old.label===size?old:{...old,label:size});}} style={{fontSize:15,fontWeight:'600'}}>{label}</Text>
      <Text verbatim allowFontScaling dynamicTypeRamp="subheadline" onTextLayout={event=>{const size=event.nativeEvent.lines[0]?.width??0;setNatural(old=>old.value===size?old:{...old,value:size});}} style={{fontSize:15,fontVariant:['tabular-nums']}}>{value}</Text>
    </View>
    <View accessible accessibilityRole="text" accessibilityLabel={`${localized(label)}, ${value}`} style={{flexDirection:stacked?'column':'row',alignItems:'flex-start',gap:stacked?4:12}}>
      <Copy role="row" color={colors.secondaryText}>{label}</Copy>
      <FormParagraph verbatim style={{color:colors.primaryText,fontVariant:['tabular-nums'],...(stacked?{}:{flexShrink:0})}}>{value}</FormParagraph>
    </View>
  </View>;
}

export function FormPanel({children}:PropsWithChildren){return <Group><View style={{padding:foundation.space.lg,gap:foundation.space.md}}>{children}</View></Group>;}
export function FormDivider(){
  const colorScheme=useLavaColorScheme();
  const style={height:StyleSheet.hairlineWidth,width:'100%' as const};
  return Platform.OS==='ios'
    ?<Decoration symbol="form.separator" colorScheme={colorScheme} guardianGestures={false} pointerEvents="none" accessible={false} accessibilityElementsHidden importantForAccessibility="no-hide-descendants" style={style}/>
    :<View pointerEvents="none" accessible={false} importantForAccessibility="no-hide-descendants" style={[style,{backgroundColor:colors.separator}]}/>;
}
/** Native step chips hug their labels. At large text all chips become a
 * vertical group together, so no partially wrapped row changes their order. */
export function FormSteps({titles,current,furthest,onSelect,disabled=false}:{titles:readonly string[];current:number;furthest:number;onSelect:(step:number)=>void;disabled?:boolean}){
  const [width,setWidth]=useState(0);const [natural,setNatural]=useState<Record<number,number>>({});
  const total=titles.reduce((sum,_,index)=>sum+(natural[index]??0)+24,0)+(titles.length-1)*8;
  const stacked=width>0&&Object.keys(natural).length===titles.length&&total>width;
  return <View onLayout={event=>setWidth(event.nativeEvent.layout.width)}><View pointerEvents="none" accessibilityElementsHidden importantForAccessibility="no-hide-descendants" style={{position:'absolute',width:10000,opacity:0,flexDirection:'row'}}>
    {titles.map((title,index)=><Text key={title} allowFontScaling dynamicTypeRamp="subheadline" onTextLayout={event=>{const value=event.nativeEvent.lines[0]?.width??0;setNatural(old=>old[index]===value?old:{...old,[index]:value});}} style={{fontSize:15,fontWeight:index===current?'800':'600'}}>{`${index+1}. ${localized(title)}`}</Text>)}
  </View><View style={{flexDirection:stacked?'column':'row',gap:8}}>{titles.map((title,index)=><Pressable key={title} accessibilityRole="button" accessibilityLabel={`${index+1}. ${localized(title)}`} accessibilityState={{selected:current===index,disabled:disabled||index>furthest}} disabled={disabled||index>furthest} onPress={()=>onSelect(index)}
      style={({pressed})=>({minWidth:44,minHeight:44,paddingVertical:10,paddingHorizontal:12,borderRadius:lavaTokens.surface.selectionCornerRadius,borderCurve:'continuous',opacity:!disabled&&index<=furthest&&pressed?.65:1,alignItems:'center',justifyContent:'center'})}>
      {/* SwiftUI's disabled plain step dims its fill and label separately. Keep
          their semantic colors; fading the whole chip changes their composite. */}
      <View pointerEvents="none" accessible={false} accessibilityElementsHidden importantForAccessibility="no-hide-descendants" style={[StyleSheet.absoluteFill,{borderRadius:lavaTokens.surface.selectionCornerRadius,borderCurve:'continuous',backgroundColor:index===current?colors.softGreen:colors.cardBackground,opacity:disabled||index>furthest?.5:1}]}/>
      <View style={{opacity:disabled||index>furthest?.5:1}}><Copy role="row" weight={current===index?'800':'600'} color={index>furthest?colors.secondaryText:colors.primaryText} center>{`${index+1}. ${localized(title)}`}</Copy></View>
    </Pressable>)}</View></View>;
}
export function CharacterCounter({count,limit}:{count:number;limit:number}){
  return <Text verbatim allowFontScaling dynamicTypeRamp="caption2"
    accessibilityLabel={localizedFormat('%lld of %lld characters used',localizedNumber(count),localizedNumber(limit))}
    style={{textAlign:'right',fontSize:11,fontVariant:['tabular-nums'],color:count>=limit?colors.lavaOrangeText:colors.tertiaryText}}>{`${localizedNumber(count)}/${localizedNumber(limit)}`}</Text>;
}
export function SelectableCode({children}:PropsWithChildren){
  return <Text verbatim selectable allowFontScaling dynamicTypeRamp="footnote" style={{fontFamily:Platform.OS==='ios'?'Menlo':'monospace',fontSize:13,color:colors.secondaryText}}>{children}</Text>;
}
export function LicenseReader({text}:{text:string}){
  const onLayout=usePresentationNativeLayout();
  const insets=useContext(SafeAreaInsetsContext);
  const horizontalPadding=insets&&(insets.left!==0||insets.right!==0)?{paddingLeft:16+insets.left,paddingRight:16+insets.right}:undefined;
  return <ScrollView onLayout={onLayout} contentInsetAdjustmentBehavior="automatic" contentContainerStyle={{padding:16,...horizontalPadding}}>
    <Text verbatim selectable allowFontScaling dynamicTypeRamp="footnote" style={{fontFamily:Platform.OS==='ios'?'Menlo':'monospace',fontSize:13,color:colors.primaryText}}>{text}</Text>
  </ScrollView>;
}
export function FormField({ref,title,labelTestID,verbatimPlaceholder=false,minHeight,value,defaultValue,resetRevision=0,characterLimit=0,grows=false,...props}:BufferedInputProps&{title:string;labelTestID?:string;verbatimPlaceholder?:boolean;minHeight?:number}){
  const scale=useTextScale();
  // UIKit owns uninterrupted editing. Echoing React values on each keystroke
  // can overwrite newer native text while the sheet or validation rerenders.
  // A delayed React acknowledgement is not an external reset. Only the caller's
  // explicit reset revision may replace the native buffer.
  return <InputRow title={title} labelTestID={labelTestID}><BufferedInput {...props} ref={ref} value={value} defaultValue={defaultValue} resetRevision={resetRevision} characterLimit={characterLimit} grows={grows}
    accessibilityLabel={localized(title)} allowFontScaling={false}
    placeholder={props.placeholder?(verbatimPlaceholder?props.placeholder:localized(props.placeholder)):undefined}
    placeholderTextColor={Platform.OS==='ios'&&!props.multiline?PlatformColor('placeholderText'):colors.tertiaryText} autoCorrect={props.autoCorrect??!!props.multiline} autoCapitalize={props.autoCapitalize??(props.multiline?'sentences':'none')}
    spellCheck={props.spellCheck??!!props.multiline} smartInsertDelete={props.smartInsertDelete??!!props.multiline}
    returnKeyType={props.returnKeyType??(props.multiline?'default':'done')} selectionColor={props.selectionColor??(props.multiline?colors.primaryText:colors.safeGreen)}
    style={[{padding:0,minHeight:minHeight??Math.ceil(22*scale),fontSize:foundation.type.body.fontSize*scale,...(props.multiline?{lineHeight:22*scale}:{}),color:Platform.OS==='ios'?PlatformColor('label'):colors.primaryText},props.style]}/></InputRow>;
}
