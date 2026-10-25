import {windowLayout} from '../src/window-layout';
import {useLayoutEffect,useRef,useState,type PropsWithChildren, type ReactNode} from 'react';
import {ActivityIndicator,Animated,Easing,Pressable,ScrollView,StyleSheet,View} from 'react-native';
import {LavaActionButton} from '../src';
import {colors} from '../src/colors';
import {foundation} from '../src/foundation';
import {Text,localized,localizedFormat} from '../app/presentation';
import {useTextScale} from '../app/text-metrics';
import {Copy,Symbol} from './primitives';
import {Group,ListRow} from './scaffold';
import {useReducedMotionPreference} from './navigation-scaffold';
import {OnboardingLavaDrawing} from '../src/OnboardingDrawing';
import type {Anchor} from './onboarding-geometry';

/** A completed welcome exit retires its native animation layer. Resizing a
 * later page must not reconnect an old native-driver interpolation. */
export function OnboardingCurtain({welcome,width,height,reduced,crossFade=false,opacity=1,returnProgress,wavesActive=welcome,onReturnReady}:{welcome:boolean;width:number;height:number;reduced:boolean;crossFade?:boolean;opacity?:number|Animated.Value;returnProgress?:Animated.Value;wavesActive?:boolean;onReturnReady?:()=>void}){
  const [mounted,setMounted]=useState(welcome);
  const curtain=useRef(new Animated.Value(welcome?0:1)).current;
  useLayoutEffect(()=>{
    let active=true;if(welcome)setMounted(true);
    // Recreate the retired drawing with paused paths. The second layout effect
    // acknowledges its committed mount before the owner starts the return clock.
    if(welcome&&returnProgress){curtain.setValue(0);return()=>{active=false;};}
    const motion=Animated.timing(curtain,{toValue:welcome?0:1,duration:welcome?(reduced||crossFade?200:320):reduced?250:1100,easing:Easing.bezier(.42,0,.58,1),useNativeDriver:true});
    motion.start(({finished})=>{if(active&&finished&&!welcome)setMounted(false);});
    return()=>{active=false;motion.stop();};
  },[welcome,reduced,crossFade,returnProgress]);
  useLayoutEffect(()=>{if(welcome&&mounted&&width>0&&height>0&&returnProgress)onReturnReady?.();},[welcome,mounted,returnProgress,width,height]);
  if(!mounted)return null;
  return <Animated.View testID="onboarding.floor" pointerEvents="none" accessibilityElementsHidden importantForAccessibility="no-hide-descendants" style={[StyleSheet.absoluteFill,{opacity,transform:[{translateY:reduced||crossFade?0:welcome&&returnProgress?returnProgress.interpolate({inputRange:[0,1],outputRange:[height*1.1,0]}):curtain.interpolate({inputRange:[0,1],outputRange:[0,height*1.1]})}]}]}>
    <OnboardingLavaDrawing width={width} height={height} active={welcome&&wavesActive} floor/>
  </Animated.View>;
}

/** One scroll owner centers the complete composition when it fits and grows
 * naturally when text or a short window needs scrolling. The retained source
 * is measured only for the mascot's journey; flex alignment places the scene. */
export function OnboardingStageLayout({source,mascot,width,height,left=0,right=0,welcome=false,children}:PropsWithChildren<{source:Anchor;mascot?:ReactNode;width:number;height:number;left?:number;right?:number;welcome?:boolean}>){
  const layout=windowLayout({width,height});const sourceSize=128*layout.scale;
  return <ScrollView testID="onboarding.stage" removeClippedSubviews={false} showsVerticalScrollIndicator={false} contentInsetAdjustmentBehavior="never" style={{flex:1}} contentContainerStyle={{flexGrow:1,justifyContent:'center',paddingLeft:24+left,paddingRight:24+right,paddingVertical:24}}>
    <View collapsable={false} testID="onboarding.composition" style={{width:'100%',maxWidth:layout.readingWidth+(layout.landscape&&!welcome?sourceSize+24:0),alignSelf:'center',flexDirection:layout.landscape?'row':'column',alignItems:'center',gap:welcome?0:24}}>
      <View testID="onboarding.source.column" pointerEvents={welcome?'none':'auto'} accessibilityElementsHidden={welcome} importantForAccessibility={welcome?'no-hide-descendants':'auto'} style={{width:sourceSize,flexShrink:0,...(welcome?{position:'absolute' as const,opacity:0}:{})}}>
        <View ref={source} testID="onboarding.source" collapsable={false} style={{width:sourceSize,height:sourceSize,alignItems:'center',justifyContent:'center'}}>{mascot}</View>
      </View>
      <View collapsable={false} testID="onboarding.pages.viewport" style={{width:'100%',flexShrink:1,minWidth:0}}>{children}</View>
    </View>
  </ScrollView>;
}

const pageTitles=['The internet is lava','Lava stands guard here','First, let’s get Lava ready to help.','Pick how much Lava blocks','Lastly, let’s keep your connection running smoothly.'];
export const onboardingPageTitle=(page:number)=>pageTitles[page]??'';
export function OnboardingStep({title,description,showTitle=true,children}:PropsWithChildren<{title:string;description?:string;showTitle?:boolean}>){
  return <View style={{gap:foundation.space.xl}}>{(showTitle||description)&&<View style={{gap:foundation.space.md}}>{showTitle&&<Copy role="setupHeading" center accessibilityRole="header">{title}</Copy>}{description&&<Copy role="body" center color={colors.secondaryText}>{description}</Copy>}</View>}{children}</View>;
}
export function OnboardingWelcome({showTitle=true}:{showTitle?:boolean}){return <View style={{gap:24,paddingHorizontal:4}}>
  {showTitle&&<Text allowFontScaling dynamicTypeRamp="title1" accessibilityRole="header" style={{fontSize:34,fontWeight:'700',color:'white',textAlign:'center',textShadowColor:'rgba(0,0,0,.22)',textShadowRadius:12,textShadowOffset:{width:0,height:6}}}>{onboardingPageTitle(0)}</Text>}
  <Text allowFontScaling dynamicTypeRamp="title3" style={{fontSize:22,fontWeight:'700',color:'rgba(255,255,255,.78)',textAlign:'center'}}>Malicious domains are the hot spots. Your device can step around them before apps and websites connect.</Text>
</View>;}
export function OnboardingFeature({title,symbol}:{title:string;symbol:string}){const scale=useTextScale('subheadline');return <View style={{paddingHorizontal:foundation.row.horizontalInset,paddingVertical:foundation.row.verticalInset,minHeight:foundation.row.standard,backgroundColor:colors.cardBackground,borderRadius:foundation.radius.control,borderCurve:'continuous',flexDirection:'row',alignItems:'center',gap:12}}>
  <Symbol name={symbol} tone="primary" size={24} pointSize={foundation.control.glyph}/><View style={{flex:1,marginVertical:-scale}}><Copy role="row" lineHeight={20}>{title}</Copy></View>
</View>;}
// Choices use the same neutral surface, label, and selection accessory as the
// catalogs. Their owner decides whether a press selects one option or toggles it.
export function OnboardingChoice({title,summary,emoji,symbol,selected,disabled=false,onPress,testID}:{title:string;summary?:string;emoji?:string;symbol?:string;selected:boolean;disabled?:boolean;onPress:()=>void;testID?:string}){
  return <Group><ListRow title={title} subtitle={summary} icon={symbol} selected={selected} disabled={disabled} onPress={onPress} testID={testID}
    leading={emoji?<View accessible={false} accessibilityElementsHidden importantForAccessibility="no-hide-descendants"><Copy verbatim role="row">{emoji}</Copy></View>:undefined}/></Group>;
}
// Installation and permission rows report completed work, rather than a current
// choice. Keep their progress and success presentation separate from selection.
export function OnboardingSetupAction({title,symbol,completed,busy=false,disabled=false,onPress,testID}:{title:string;symbol:string;completed:boolean;busy?:boolean;disabled?:boolean;onPress?:()=>void;testID?:string}){
  const body=<><View style={{flex:1}}><Copy role="row" color={completed?'white':colors.primaryText}>{title}</Copy></View>
    <View style={{width:foundation.control.accessory,height:foundation.control.glyphSlot,alignItems:'center',justifyContent:'center'}}>{busy?<ActivityIndicator/>:<Symbol name={completed?'checkmark.circle.fill':symbol} tone={completed?'white':'primary'} size={24} pointSize={foundation.control.glyph}/>}</View></>;
  const style={flexDirection:'row' as const,alignItems:'center' as const,gap:12,paddingHorizontal:foundation.row.horizontalInset,paddingVertical:foundation.row.verticalInset,minHeight:foundation.row.standard,borderRadius:foundation.radius.control,borderCurve:'continuous' as const,backgroundColor:completed?colors.safeControlGreen:colors.cardBackground};
  const a11y={testID,accessibilityLabel:localized(title),accessibilityValue:{text:localized(completed?'On':'Off')},accessibilityState:{selected:completed,disabled,busy}};
  return onPress?<Pressable {...a11y} accessible accessibilityRole="button" disabled={disabled||busy} onPress={onPress} style={({pressed})=>[style,{opacity:pressed?.65:1}]}>{body}</Pressable>:<View {...a11y} accessible style={style}>{body}</View>;
}
export function OnboardingPageContent({children}:PropsWithChildren){return <View style={{width:'100%'}}>{children}</View>;}
export function OnboardingProgress({page,visited,busy,vpnInstalled,onPage,duration,smooth}: {page:number;visited:number[];busy:boolean;vpnInstalled:boolean;onPage:(page:number)=>void;duration:number;smooth:boolean}){
  return <View testID="onboarding.steps" style={{flexDirection:'row',alignSelf:'center'}}>{Array.from({length:6},(_,index)=><OnboardingDot key={index} index={index} page={page} disabled={busy||index===page||!visited.includes(index)||index>2&&!vpnInstalled} onPress={()=>onPage(index)} duration={duration} smooth={smooth}/>)}</View>;
}
export function OnboardingFooter({page,busy,vpnInstalled,onNext,bottom,left=0,right=0,progress,outlineTransitionDuration}: {page:number;busy:boolean;vpnInstalled:boolean;onNext:()=>void;bottom:number;left?:number;right?:number;progress?:ReactNode;outlineTransitionDuration?:number}){
  const reduced=useReducedMotionPreference();
  const titles=['Meet Lava','Set Up Protection',vpnInstalled?'Next step':'Install VPN first','Next step','Next step',''];
  return <View testID="onboarding.footer" style={{gap:16,paddingHorizontal:20,...(left||right?{paddingLeft:20+left,paddingRight:20+right}:{}),paddingTop:12,paddingBottom:18+bottom}}>{progress}<LavaActionButton testID="onboarding.primary" title={titles[page]??''} whiteOutline={page===0} outlineTransitionDuration={outlineTransitionDuration??(reduced?250:1100)} busy={busy&&page===4} disabled={busy||page===2&&!vpnInstalled} onPress={onNext}/></View>;
}
function OnboardingDot({index,page,disabled,onPress,duration,smooth}:{index:number;page:number;disabled:boolean;onPress:()=>void;duration:number;smooth:boolean}){
  const selected=index===page;const amount=useRef(new Animated.Value(selected?1:0)).current;
  const previousSelected=useRef(selected);
  useLayoutEffect(()=>{
    const changed=previousSelected.current!==selected;previousSelected.current=selected;
    if(!changed||!duration){amount.setValue(selected?1:0);return;}
    const motion=Animated.timing(amount,{toValue:selected?1:0,duration,easing:smooth?Easing.bezier(.42,0,.58,1):Easing.bezier(0,0,.58,1),useNativeDriver:false});
    motion.start();return()=>motion.stop();
  },[selected,duration,smooth]);
  return <Animated.View style={{width:amount.interpolate({inputRange:[0,1],outputRange:[20,32]})}}><Pressable accessible accessibilityRole="button" accessibilityLabel={localizedFormat('Step %lld of %lld',index+1,6)} accessibilityState={{selected,disabled}} disabled={disabled} onPress={onPress} style={{height:44,alignItems:'center',justifyContent:'center',opacity:disabled&&!selected?.5:1}}>
    <Animated.View style={{width:amount.interpolate({inputRange:[0,1],outputRange:[8,24]}),height:8,borderRadius:4,backgroundColor:page===0?'white':selected?colors.safeGreen:colors.secondaryText,opacity:amount.interpolate({inputRange:[0,1],outputRange:[page===0?.28:.22,1]})}}/>
  </Pressable></Animated.View>;
}
