import {animationNow} from './animation-clock';
import {useEffect,useRef,useState} from 'react';
import {AppState,View} from 'react-native';
import Svg,{Defs,G,LinearGradient,Mask,Path,Rect,Stop} from 'react-native-svg';
import {colorForScheme} from './colors';
import {useLavaColorScheme} from './appearance';
import {lavaWavePath,lavaWavePhase,type OnboardingDestination} from '../review/onboarding-motion';

export function OnboardingBackground({width,height,frames,reveal=0}:{width:number;height:number;frames?:OnboardingDestination;reveal?:number}){
  const scheme=useLavaColorScheme();
  return <Svg width={width} height={height}><Defs><Mask id="onboarding-cover" maskType="luminance" x={0} y={0} width={width} height={height}><Rect width={width} height={height} fill="white"/>{frames&&<Rect x={frames.panel.x} y={frames.panel.y} width={frames.panel.width} height={frames.panel.height} fill="black" opacity={reveal}/>}</Mask></Defs>
    <Rect width={width} height={height} fill={colorForScheme('groupedBackground',scheme)} mask="url(#onboarding-cover)"/>
  </Svg>;
}
export function OnboardingLavaDrawing({width,height,active,floor=false}:{width:number;height:number;active:boolean;floor?:boolean}){
  const scheme=useLavaColorScheme();const [phase,setPhase]=useState(0);const start=useRef(animationNow());
  // Only the floor contains moving paths. The gradient backdrop is static and
  // must not schedule React renders on every frame of a page transition.
  useEffect(()=>{if(!active||!floor)return;let alive=true,request=0;const tick=()=>{if(!alive||AppState.currentState!=='active')return;setPhase(lavaWavePhase(animationNow()-start.current));request=requestAnimationFrame(tick);};
    tick();const subscription=AppState.addEventListener('change',state=>{cancelAnimationFrame(request);if(state==='active')tick();});return()=>{alive=false;cancelAnimationFrame(request);subscription.remove();};},[active,floor]);
  const path=floor?lavaWavePath(width,height,phase,18*1.35,.18):undefined;
  return <View pointerEvents="none" style={{width,height}} accessible={false} accessibilityElementsHidden><Svg width={width} height={height}>
    <Defs><LinearGradient id={floor?'lava-floor':'lava-backdrop'} x1={0} y1={0} x2={0} y2={height} gradientUnits="userSpaceOnUse"><Stop offset={0} stopColor={colorForScheme('lavaOrange',scheme)} stopOpacity={.86}/><Stop offset={.5} stopColor="rgb(212,20,5)"/><Stop offset={1} stopColor="rgb(122,5,3)"/></LinearGradient>
      {floor&&<Mask id="lava-leading-edge" x={0} y={0} width={width} height={height} maskType="luminance"><Path d={path} fill="white"/></Mask>}</Defs>
    <G mask={floor?'url(#lava-leading-edge)':undefined}>
    {floor&&<Rect width={width} height={height} fill={colorForScheme('groupedBackground',scheme)}/>}
    <Rect width={width} height={height} fill={floor?'url(#lava-floor)':'url(#lava-backdrop)'}/>
    {floor&&[[phase,18,.18,'rgb(255,128,33)',.74],[-phase+Math.PI*.35,22,.34,'rgb(235,51,10)',.78],[phase*2+Math.PI,14,.48,'rgb(140,8,3)',.70]].map(([p,a,b,color,opacity],index)=><Path key={index} d={lavaWavePath(width,height,Number(p),Number(a)*1.35,Number(b))} fill={String(color)} opacity={Number(opacity)}/>)}
  </G></Svg></View>;
}
