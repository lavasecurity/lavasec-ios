import {animationNow} from './animation-clock';
import {useEffect,useId,useRef,useState} from 'react';
import {AppState,View} from 'react-native';
import Svg,{Defs,G,LinearGradient,Mask,Path,Rect,Stop} from 'react-native-svg';
import {guardianEye,guardianFrame,guardianPlan,stableGuardianFrame,unit,type GuardianFrame,type GuardianState} from './guardian-motion';
import {guardianPalettes,guardianPaletteKeys} from './guardian-palettes';
import {useLavaColorScheme} from './appearance';

export const guardianShieldPath='M110 8 C141 8 193 31 204 50 C216 72 209 166 200 187 C189 211 136 238 119 245 C113 248 107 248 101 245 C84 238 31 211 20 187 C11 166 4 72 16 50 C27 31 79 8 110 8 Z';
const sleepingPalette={innerTop:[.73,.76,.74,1],innerMid:[.56,.60,.58,1],innerBottom:[.42,.46,.44,1],shellTop:[.76,.79,.77,1],shellMid:[.58,.62,.60,1],shellDeep:[.30,.33,.31,1],shellBottom:[.12,.14,.13,1],rightFacet:[.28,.31,.30,.82],lowerRightFacet:[.10,.12,.11,.62],warmSideFacet:[.47,.50,.48,.72]};
type RGBA=readonly number[];
const rgb=(c:RGBA)=>`rgb(${Math.round(c[0]!*255)},${Math.round(c[1]!*255)},${Math.round(c[2]!*255)})`;
const blended=(a:RGBA,b:RGBA,t:number)=>a.map((v,i)=>v+(b[i]!-v)*unit(t));
const stateFor=(mood:string):GuardianState=>['sleeping','waking','awake','paused','retrying','concerned','grateful'].includes(mood)?mood as GuardianState:'sleeping';

/** Only one clock owns expression paint. An interrupted plan starts at its
 * current frame; inactive/off-route drawings settle and retire queued frames. */
export function GuardianDrawing({size,mood,look,active=true,blinkTrigger=0,finishTrigger=0,keepsColorWhenSleeping=false,frame:fixedFrame,colorScheme}: {
  size:number;mood:string;look:string;active?:boolean;blinkTrigger?:number;finishTrigger?:number;keepsColorWhenSleeping?:boolean;frame?:GuardianFrame;colorScheme?:'light'|'dark';
}){
  const systemScheme=useLavaColorScheme();const dark=(colorScheme??systemScheme)==='dark';
  const state=stateFor(mood);const initialStartState:GuardianState=state==='waking'?'sleeping':state;
  const [frame,setFrame]=useState(()=>stableGuardianFrame(initialStartState));
  const current=useRef(frame);const previous=useRef<GuardianState>(initialStartState);const trigger=useRef({blink:blinkTrigger,finish:finishTrigger});
  const generation=useRef(0);const [foreground,setForeground]=useState(AppState.currentState==='active');
  const update=(f:GuardianFrame)=>{current.current=f;setFrame(f);};
  useEffect(()=>{const subscription=AppState.addEventListener('change',value=>{++generation.current;setForeground(value==='active');});return()=>{++generation.current;subscription.remove();};},[]);
  useEffect(()=>{
    if(fixedFrame)return;
    const epoch=++generation.current;let request=0;
    const finishing=trigger.current.finish!==finishTrigger;
    const blinking=trigger.current.blink!==blinkTrigger;
    trigger.current={blink:blinkTrigger,finish:finishTrigger};
    const from=finishing&&previous.current==='grateful'?'awake':previous.current;
    const plan=guardianPlan(from,state,blinking?'blink':'transition');previous.current=state;
    if(from===state&&!blinking&&!finishing){update(guardianFrame(plan,plan.duration));return;}
    if(!active||!foreground){update(guardianFrame(plan,plan.duration));return;}
    const starting=finishing?stableGuardianFrame(from):current.current;const start=animationNow();
    const tick=()=>{
      if(generation.current!==epoch)return;
      const elapsed=animationNow()-start;
      let next=guardianFrame(plan,elapsed);
      // Preserve continuity when native truth supersedes a still-moving face.
      // The authored gratitude/wake phases retain their canonical equations.
      if(!blinking&&!plan.sequence&&!(from==='awake'&&state==='grateful'||from==='grateful'&&state==='awake')){
        const canonicalStart=guardianFrame(plan,0),remaining=1-unit(elapsed/plan.duration);
        next=Object.fromEntries(Object.keys(next).map(key=>{const k=key as keyof GuardianFrame;return [k,next[k]+(starting[k]-canonicalStart[k])*remaining*remaining*(3-2*remaining)];})) as GuardianFrame;
      }
      update(next);if(elapsed<plan.duration)request=requestAnimationFrame(tick);
    };
    tick();return()=>{++generation.current;cancelAnimationFrame(request);};
  },[state,active,foreground,blinkTrigger,finishTrigger,fixedFrame]);
  const painted=fixedFrame??frame;const wake=keepsColorWhenSleeping?1:painted.shieldWakeAmount;
  const id=useId().replace(/[^a-zA-Z0-9]/g,'');const palette=guardianPaletteKeys[look]?guardianPalettes[guardianPaletteKeys[look]]:undefined;
  const tint=dark?[1,.54,.34,1]:[.95,.34,.18,1],sleep=dark?[.36,.40,.38,1]:[.67,.71,.69,1],face=dark?[.94,.98,.95,1]:[1,.98,.93,1];
  const glow=look==='purpleObsidian'?[.62,.38,.95,1]:look==='obsidian'?[.50,.55,.54,1]:look==='strawberryObsidian'?[1,.58,.78,1]:look==='emerald'?[.16,.47,.34,1]:look==='kiwiCreme'?(dark?[1,.94,.84,1]:[.46,.39,.32,1]):look==='aquamarine'?[138/255,221/255,229/255,1]:tint;
  const stop=(key:keyof typeof sleepingPalette)=>blended(sleepingPalette[key],palette![key],wake);
  const maxOpen=Math.max(painted.leftEyeOpenAmount,painted.rightEyeOpenAmount),happy=unit(painted.happyEyeAmount),concern=unit(painted.concernAmount);
  const happyLength=Math.max(1-maxOpen,unit(happy/.85)),smile=happy>0?unit(maxOpen+happy):maxOpen;
  const spacing=size*(.34+smile*.09-(happy>0?happyLength*.066:0)-concern*.04);
  const left=guardianEye(painted,size),right=guardianEye(painted,size,true);
  const total=left.width+spacing+right.width,eyeY=size/2-size*(.06+maxOpen*.01-concern*.005);
  const mouthWidth=size*(.48+painted.gratitudeAmount*.04),mouthY=size/2+size*.11;
  const gradient=(suffix:string,keys:(keyof typeof sleepingPalette)[])=><LinearGradient id={id+suffix} gradientUnits="userSpaceOnUse" x1={-15} y1={0} x2={235} y2={250}>{keys.map((key,index)=>{const c=stop(key);return <Stop key={key} offset={index/(keys.length-1)} stopColor={rgb(c)} stopOpacity={c[3]}/>;})}</LinearGradient>;
  return <View pointerEvents="none" style={{width:size,height:size,shadowColor:rgb(glow),shadowOpacity:.18*painted.glowAmount,shadowRadius:12,shadowOffset:{width:0,height:8}}} accessible={false} accessibilityElementsHidden>
    <Svg width={size} height={size} viewBox="0 0 250 250">
      <G transform="translate(15 0)">
        <Defs>
          <LinearGradient id={id+'original'} gradientUnits="userSpaceOnUse" x1={0} y1={0} x2={0} y2={250}><Stop offset={0} stopColor={rgb(tint)} stopOpacity={.82}/><Stop offset={1} stopColor={rgb(tint)}/></LinearGradient>
          {palette&&<>{gradient('inner',['innerTop','innerMid','innerBottom'])}{gradient('shell',['shellTop','shellMid','shellDeep','shellBottom'])}
            <Mask id={id+'rim'} maskUnits="userSpaceOnUse" x={-15} y={0} width={250} height={250} maskType="luminance"><Path d={guardianShieldPath} fill="white"/><Path d={guardianShieldPath} fill="black" transform="translate(110 125) scale(.91) translate(-110 -125)"/></Mask></>}
        </Defs>
        <G transform={`translate(110 125) scale(${painted.shieldScale}) translate(-110 -125)`}>
          {palette?<><Path d={guardianShieldPath} fill={`url(#${id}inner)`}/><G mask={`url(#${id}rim)`}><Rect x={-15} width={250} height={250} fill={`url(#${id}shell)`}/>
            {(['rightFacet','lowerRightFacet','warmSideFacet'] as const).map((key,index)=>{const c=stop(key);return <Path key={key} fill={rgb(c)} opacity={c[3]} d={['M147 0 L214 43 L208 158 L155 120 Z','M157 118 L208 158 L193 205 L128 236 Z','M147 2 L198 43 L156 119 L122 17 Z'][index]}/>;})}</G></>
            :<><Path d={guardianShieldPath} fill={rgb(sleep)} opacity={1-wake}/><Path d={guardianShieldPath} fill={`url(#${id}original)`} opacity={wake}/></>}
        </G>
      </G>
      <G transform={`scale(${250/size})`}>{[left,right].map((eye,index)=>{const x=size/2-total/2+(index?left.width+spacing:0),y=eyeY-eye.height/2;return <G key={index} transform={`translate(${x} ${y}) rotate(${eye.rotation} ${eye.width/2} ${eye.height/2})`}><Path d={eye.path} fill="none" stroke={rgb(face)} strokeWidth={eye.lineWidth} strokeLinecap="round"/></G>;})}
      <Path d={`M ${(size-mouthWidth)/2} ${mouthY} Q ${size/2} ${mouthY+size*.12*painted.mouthCurve*.48} ${(size+mouthWidth)/2} ${mouthY}`} fill="none" stroke={rgb(face)} strokeWidth={Math.max(3,size*.038)} strokeLinecap="round"/>
    </G></Svg>
  </View>;
}
