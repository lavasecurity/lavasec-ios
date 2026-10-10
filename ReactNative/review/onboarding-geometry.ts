import {createContext,useContext,useEffect,useState,type ComponentRef} from 'react';
import {AppState,Dimensions,View} from 'react-native';
import type {OnboardingFrame,OnboardingSetup} from '../app/contract';
import {validOnboardingDestination,type OnboardingDestination} from './onboarding-motion';
export type Anchor={current:ComponentRef<typeof View>|null};
type Geometry={panel:Anchor;mascot:Anchor;action:Anchor;source:Anchor;root:Anchor;frames?:OnboardingDestination;origin:{x:number;y:number};size:{width:number;height:number};sourceFrame?:OnboardingFrame;setup?:OnboardingSetup};
const idle:Anchor={current:null};
export const OnboardingGeometryContext=createContext<Geometry>({panel:idle,mascot:idle,action:idle,source:idle,root:idle,origin:{x:0,y:0},size:{width:0,height:0}});
export const useOnboardingDestination=()=>useContext(OnboardingGeometryContext);

type Anchors=Pick<Geometry,'root'|'source'|'panel'|'mascot'|'action'>;
/** Measurements stay in the shared tree. Invalid, rotated or retired geometry
 * must never leave a previous destination available to the traveling mascot. */
export function useOnboardingMeasurements(visit:string|undefined,{root,source,panel,mascot,action}:Anchors){
  const [origin,setOrigin]=useState({x:0,y:0});
  const [frames,setFrames]=useState<OnboardingDestination>();
  const [sourceFrame,setSourceFrame]=useState<OnboardingFrame>();
  useEffect(()=>{
    setFrames(undefined);setSourceFrame(undefined);
    if(!visit)return;let active=true,busy=false,last='',epoch=0;
    const invalidate=()=>{epoch++;last='';setFrames(undefined);setSourceFrame(undefined);};
    const measure=(anchor:Anchor)=>new Promise<OnboardingFrame|undefined>(resolve=>{
      if(!anchor.current){resolve(undefined);return;}
      // Fabric may drop a callback when its native view retires during layout.
      // One absent Guard destination must not starve the setup source forever.
      const timeout=setTimeout(()=>resolve(undefined),200);
      anchor.current.measureInWindow((x,y,width,height)=>{clearTimeout(timeout);resolve({x,y,width,height});});
    });
    const finite=(f:OnboardingFrame|undefined):f is OnboardingFrame=>!!f&&[f.x,f.y,f.width,f.height].every(Number.isFinite)&&f.width>0&&f.height>0;
    const report=async()=>{
      if(busy||AppState.currentState!=='active')return;busy=true;const generation=epoch;
      try{
        const [r,s]=await Promise.all([measure(root),measure(source)]);
        if(!active||generation!==epoch)return;
        if(!finite(r)){invalidate();return;}
        setOrigin(old=>old.x===r.x&&old.y===r.y?old:{x:r.x,y:r.y});
        const relative=(f:OnboardingFrame)=>({...f,x:f.x-r.x,y:f.y-r.y});
        const withinRoot=(f:OnboardingFrame)=>f.x>=-1&&f.y>=-1&&f.x+f.width<=r.width+1&&f.y+f.height<=r.height+1;
        const nextSource=finite(s)?relative(s):undefined;
        setSourceFrame(old=>nextSource&&withinRoot(nextSource)?JSON.stringify(old)===JSON.stringify(nextSource)?old:nextSource:undefined);
        const [p,m,a]=await Promise.all([measure(panel),measure(mascot),measure(action)]);
        if(!active||generation!==epoch)return;
        if(finite(p)&&finite(m)&&finite(a)){
          const next={panel:relative(p),mascot:relative(m),action:relative(a)},key=JSON.stringify(next);
          if(validOnboardingDestination(next)&&withinRoot(next.panel)){if(key!==last){last=key;setFrames(next);}return;}
        }
        last='';setFrames(undefined);
      }finally{busy=false;}
    };
    void report();const interval=setInterval(()=>void report(),160);
    const rotation=Dimensions.addEventListener('change',()=>{invalidate();void report();});
    const lifecycle=AppState.addEventListener('change',value=>{if(value!=='active')invalidate();else void report();});
    return()=>{active=false;clearInterval(interval);rotation.remove();lifecycle.remove();};
  },[visit,root,source,panel,mascot,action]);
  return {origin,frames,sourceFrame};
}
