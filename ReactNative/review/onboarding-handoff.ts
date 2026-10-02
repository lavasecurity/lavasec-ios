import {useEffect,useRef,type ComponentRef} from 'react';
import {View} from 'react-native';
import type {AppStore} from '../app/store';
import type {OnboardingFrame,OnboardingPresentation} from '../app/contract';

/** Real window geometry, including native bars/insets; never guessed coordinates. */
export function useOnboardingHandoff(app:AppStore|undefined,presentation:OnboardingPresentation|undefined) {
  const panel=useRef<ComponentRef<typeof View>>(null),mascot=useRef<ComponentRef<typeof View>>(null),action=useRef<ComponentRef<typeof View>>(null);
  useEffect(()=>{
    if(!app||!presentation)return;
    let active=true,busy=false,last='';
    const measure=(ref:typeof panel)=>new Promise<OnboardingFrame|undefined>(resolve=>{
      if(!ref.current){resolve(undefined);return;}
      ref.current.measureInWindow((x,y,width,height)=>resolve({x,y,width,height}));
    });
    const report=async()=>{
      if(busy)return;busy=true;
      try {
        const [p,m,a]=await Promise.all([measure(panel),measure(mascot),measure(action)]);
        if(!active||!p||!m||!a||[p,m,a].some(f=>![f.x,f.y,f.width,f.height].every(Number.isFinite)||f.width<=0||f.height<=0))return;
        const frames={panel:p,mascot:m,action:a},key=JSON.stringify(frames);
        if(key===last)return;
        const accepted=await app.command<boolean>({type:'onboarding.geometry',session:presentation.session,phase:presentation.phase,layoutRevision:presentation.layoutRevision,frames});
        if(active&&accepted)last=key;
      } catch {last='';} finally {busy=false;}
    };
    void report();
    // Native inset/font changes may move the view without its own Yoga onLayout.
    const timer=setInterval(()=>void report(),160);
    return()=>{active=false;clearInterval(timer);};
  },[app,presentation?.session,presentation?.phase,presentation?.layoutRevision]);
  return {panel,mascot,action};
}
