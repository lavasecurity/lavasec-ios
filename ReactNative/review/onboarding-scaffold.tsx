import {useLayoutEffect,useRef,useState,type PropsWithChildren, type ReactNode} from 'react';
import {ActivityIndicator,Animated,Easing,Pressable,ScrollView,StyleSheet,View} from 'react-native';
import {LavaActionButton} from '../src';
import {colors} from '../src/colors';
import {foundation} from '../src/foundation';
import {Text,localized,localizedFormat} from '../app/presentation';
import {useTextScale} from '../app/text-metrics';
import {Copy,Symbol} from './primitives';
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

/** Keep the source anchor and scrolling page in one flexible stage. A short
 * landscape window uses the source slot beside the page, above the same footer.
 * Each page owns its horizontal inset, so an outgoing page keeps its geometry
 * while Welcome uses the full width. The decorative anchor stays in place. */
export function OnboardingStageLayout({source,progress,width,height,left=0,right=0,welcome=false,children}:PropsWithChildren<{source:Anchor;progress?:ReactNode;width:number;height:number;left?:number;right?:number;welcome?:boolean}>){
  const compact=width>height&&height<foundation.layout.expandedSceneMinHeight;
  return <View testID="onboarding.stage" style={{flex:1,flexDirection:compact?'row':'column',paddingLeft:compact?left:0,paddingRight:compact?right:0}}>
    <View testID="onboarding.source.column" style={compact?{position:'absolute' as const,left,width:128}:{}}>
      <View ref={source} testID="onboarding.source" collapsable={false} style={compact?{width:128,height:128}:{height:128}}/>
      {progress}
    </View>
    <View testID="onboarding.pages.viewport" style={{flex:1,minWidth:0,overflow:'hidden'}}>{children}</View>
  </View>;
}

const pageTitles=['The internet is lava','Lava stands guard here','First, let’s get Lava ready to help.','Pick how much Lava blocks','Lastly, let’s keep your connection running smoothly.'];
export const onboardingPageTitle=(page:number)=>pageTitles[page]??'';
export function OnboardingStep({title,description,showTitle=true,children}:PropsWithChildren<{title:string;description?:string;showTitle?:boolean}>){
  return <View style={{paddingTop:showTitle?foundation.space.lg:0,gap:foundation.space.xl}}>{(showTitle||description)&&<View style={{gap:foundation.space.md}}>{showTitle&&<Copy role="setupHeading" accessibilityRole="header">{title}</Copy>}{description&&<Copy role="body" color={colors.secondaryText}>{description}</Copy>}</View>}{children}</View>;
}
export function OnboardingWelcome({showTitle=true}:{showTitle?:boolean}){return <View style={{gap:24,paddingHorizontal:4}}>
  {showTitle&&<Text allowFontScaling dynamicTypeRamp="title1" accessibilityRole="header" style={{fontSize:28,fontWeight:'700',color:'white',textAlign:'center',textShadowColor:'rgba(0,0,0,.22)',textShadowRadius:12,textShadowOffset:{width:0,height:6}}}>{onboardingPageTitle(0)}</Text>}
  <Text allowFontScaling dynamicTypeRamp="title3" style={{fontSize:20,fontWeight:'700',color:'rgba(255,255,255,.78)',textAlign:'center'}}>Malicious domains are the hot spots. Your device can step around them before apps and websites connect.</Text>
</View>;}
export function OnboardingFeature({title,symbol}:{title:string;symbol:string}){const scale=useTextScale('subheadline');return <View style={{paddingHorizontal:foundation.row.horizontalInset,paddingVertical:foundation.row.verticalInset,minHeight:foundation.row.standard,backgroundColor:colors.cardBackground,borderRadius:foundation.radius.control,borderCurve:'continuous',flexDirection:'row',alignItems:'center',gap:12}}>
  <Symbol name={symbol} tone="primary" size={24} pointSize={foundation.control.glyph}/><View style={{flex:1,marginVertical:-scale}}><Copy role="row" lineHeight={20}>{title}</Copy></View>
</View>;}
export function OnboardingChoice({title,summary,emoji,symbol,selected,busy=false,disabled=false,onPress,testID}:{title:string;summary?:string;emoji?:string;symbol?:string;selected:boolean;busy?:boolean;disabled?:boolean;onPress?:()=>void;testID?:string}){
  const body=<><View style={{flex:1,gap:4}}><View style={{flexDirection:'row',gap:8,alignItems:'baseline'}}>{emoji&&<Copy verbatim role="row">{emoji}</Copy>}<View style={{flex:1}}><Copy role="row" color={selected?'white':colors.primaryText}>{title}</Copy></View></View>
    {summary&&<Copy role="supporting" color={selected?'rgba(255,255,255,.85)':colors.secondaryText}>{summary}</Copy>}</View>
    <View style={{width:foundation.control.accessory,height:foundation.control.glyphSlot,alignItems:'center',justifyContent:'center'}}>{busy?<ActivityIndicator/>:selected||symbol?<Symbol name={selected?'checkmark.circle.fill':symbol!} tone={selected?'white':'primary'} size={24} pointSize={foundation.control.glyph}/>:null}</View></>;
  const style={flexDirection:'row' as const,alignItems:'center' as const,gap:12,paddingHorizontal:foundation.row.horizontalInset,paddingVertical:foundation.row.verticalInset,minHeight:foundation.row.standard,borderRadius:foundation.radius.control,borderCurve:'continuous' as const,backgroundColor:selected?colors.safeControlGreen:colors.cardBackground};
  const a11y={testID,accessibilityLabel:[localized(title),summary?localized(summary):undefined].filter(Boolean).join(', '),accessibilityValue:{text:localized(selected?'On':'Off')},accessibilityState:{selected,disabled,busy}};
  return onPress?<Pressable {...a11y} accessible accessibilityRole="button" disabled={disabled||busy} onPress={onPress} style={({pressed})=>[style,{opacity:pressed?.65:1}]}>{body}</Pressable>:<View {...a11y} accessible style={style}>{body}</View>;
}
export function OnboardingPageScroll({welcome,landscape=false,children}:PropsWithChildren<{welcome?:boolean;landscape?:boolean}>){return <ScrollView showsVerticalScrollIndicator={false} contentInsetAdjustmentBehavior="never" contentContainerStyle={{paddingHorizontal:24,paddingTop:welcome&&!landscape?72:8,paddingBottom:24,width:'100%',maxWidth:600,alignSelf:'center'}}>{children}</ScrollView>;}
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
