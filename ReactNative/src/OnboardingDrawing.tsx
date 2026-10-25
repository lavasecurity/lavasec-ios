import {useEffect,useState} from 'react';
import {Animated,AppState,Easing,View} from 'react-native';
import Svg,{Defs,LinearGradient,Path,Rect,Stop} from 'react-native-svg';
import {colorForScheme} from './colors';
import {useLavaColorScheme} from './appearance';
import {lavaWavePath,type OnboardingDestination} from '../review/onboarding-motion';

export function OnboardingBackground({width,height,frames,reveal=0}:{width:number;height:number;frames?:OnboardingDestination;reveal?:number}){
  const scheme=useLavaColorScheme();const fill=colorForScheme('groupedBackground',scheme);
  const panel=frames?.panel;const opacity=1-Math.min(1,Math.max(0,reveal));
  // Paint the rectangular surroundings and fade only the panel. A luminance
  // mask would allocate and convert a screen-sized bitmap on every reveal frame.
  return <Svg width={width} height={height}>{!panel||opacity===1?<Rect width={width} height={height} fill={fill}/>:<>
    <Path d={`M0 0 H${width} V${height} H0 Z M${panel.x} ${panel.y} h${panel.width} v${panel.height} h${-panel.width} Z`} fillRule="evenodd" fill={fill}/>
    <Rect x={panel.x} y={panel.y} width={panel.width} height={panel.height} fill={fill} opacity={opacity}/>
  </>}</Svg>;
}
const waves=[
  {amplitude:18*1.35,baseline:.18,phase:0,color:'rgb(255,128,33)',opacity:.74,duration:18000,reverse:false},
  {amplitude:22*1.35,baseline:.34,phase:Math.PI*.35,color:'rgb(235,51,10)',opacity:.78,duration:18000,reverse:true},
  {amplitude:14*1.35,baseline:.48,phase:Math.PI,color:'rgb(140,8,3)',opacity:.70,duration:9000,reverse:false},
];
export function OnboardingLavaDrawing({width,height,active,floor=false}:{width:number;height:number;active:boolean;floor?:boolean}){
  const scheme=useLavaColorScheme();const [progress]=useState(()=>waves.map(()=>new Animated.Value(0)));
  const drawable=width>0&&height>0;
  useEffect(()=>{
    if(!active||!floor||!drawable)return;
    // Only compositor transforms repeat. The SVG paths and gradient never
    // rebuild per frame; each moving surface is just a narrow tiled crest.
    const motions=progress.map((value,index)=>Animated.loop(Animated.timing(value,{toValue:1,duration:waves[index]!.duration,easing:Easing.linear,useNativeDriver:true,isInteraction:false})));
    const update=(state:typeof AppState.currentState)=>{motions.forEach(motion=>state==='active'?motion.start():motion.stop());};
    update(AppState.currentState);const subscription=AppState.addEventListener('change',update);
    return()=>{motions.forEach(motion=>motion.stop());subscription.remove();};
  },[active,floor,progress,drawable]);
  if(!drawable)return <View pointerEvents="none"/>;
  const gradient=(id:string,offset=0)=><Defs><LinearGradient id={id} x1={0} y1={-offset} x2={0} y2={height-offset} gradientUnits="userSpaceOnUse"><Stop offset={0} stopColor={colorForScheme('lavaOrange',scheme)} stopOpacity={.86}/><Stop offset={.5} stopColor="rgb(212,20,5)"/><Stop offset={1} stopColor="rgb(122,5,3)"/></LinearGradient></Defs>;
  return <View pointerEvents="none" style={{width,height,overflow:'hidden'}} accessible={false} accessibilityElementsHidden>{!floor?<Svg width={width} height={height}>
    {gradient('lava-backdrop')}<Rect width={width} height={height} fill="url(#lava-backdrop)"/>
  </Svg>:waves.map((wave,index)=>{
    const radius=Math.ceil(wave.amplitude*1.5)+1,bandHeight=radius*2;
    const top=height*wave.baseline-radius,bottom=top+bandHeight,bodyHeight=Math.max(0,height-bottom);
    const path=lavaWavePath(width*2,bandHeight,wave.phase,wave.amplitude,.5,width);
    return <View key={index} style={{position:'absolute',width,height}}>
      <Animated.View testID={`onboarding.wave.${index}`} style={{position:'absolute',top,width:width*2,height:bandHeight,transform:[{translateX:progress[index]!.interpolate({inputRange:[0,1],outputRange:wave.reverse?[-width,0]:[0,-width]})}]}}>
        <Svg width={width*2} height={bandHeight}>{index===0&&<>{gradient('lava-crest',top)}<Path d={path} fill={colorForScheme('groupedBackground',scheme)}/><Path d={path} fill="url(#lava-crest)"/></>}
          <Path d={path} fill={wave.color} opacity={wave.opacity}/>
        </Svg>
      </Animated.View>
      <Svg width={width} height={bodyHeight} style={{position:'absolute',top:bottom}}>{index===0&&<>{gradient('lava-body',bottom)}<Rect width={width} height={bodyHeight} fill={colorForScheme('groupedBackground',scheme)}/><Rect width={width} height={bodyHeight} fill="url(#lava-body)"/></>}
        <Rect width={width} height={bodyHeight} fill={wave.color} opacity={wave.opacity}/>
      </Svg>
    </View>;
  })}</View>;
}
