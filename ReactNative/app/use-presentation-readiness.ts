import {useLayoutEffect,useRef,useState,useSyncExternalStore} from 'react';
import {AppState,type LayoutChangeEvent} from 'react-native';
import {useIsFocused} from '@react-navigation/native';
import {useOptionalReview} from '../review/ReviewContext';
import type {AppStore} from './store';
import type {PresentationReadTicket} from './presentation-hydration';

const noSubscribe=()=>()=>{};
/** Native fields authorize internal presentation work before the covered screen becomes interactive. */
export function usePresentationAuthority(app?:AppStore):boolean {
  return useSyncExternalStore(app?.subscribe??noSubscribe,()=>app?.getSnapshot?!!app.getSnapshot().snapshot:true);
}

/** Focused scoped reads/preparation release a warm-resume cover only after their readiness is committed. */
export function usePresentationReadiness(app:AppStore|undefined,required:boolean,ready:boolean,scope:string):boolean {
  const authoritative=usePresentationAuthority(app);
  const epoch=useSyncExternalStore(app?.subscribe??noSubscribe,()=>app?.getPresentationHydration?.().epoch??0);
  const ticket=useRef<PresentationReadTicket|undefined>(undefined);
  useLayoutEffect(()=>{
    if(!app||!required||!authoritative||typeof app.getSnapshot==='function'&&AppState.currentState!=='active')return;
    const registered=app.registerPresentationRead?.();ticket.current=registered;
    return()=>{if(ticket.current===registered)ticket.current=undefined;app.settlePresentationRead?.(registered);};
  },[app,required,scope,authoritative,epoch]);
  useLayoutEffect(()=>{
    // A resolved promise can precede React's commit. Release from layout so the
    // complete value/error is painted beneath the cover before it disappears.
    if(required&&ready&&authoritative)app?.settlePresentationRead?.(ticket.current);
  },[app,required,ready,scope,authoritative,epoch]);
  return authoritative;
}

/** The focused scaffold's actual native viewport must exist before first reveal.
 * A same-visit retained viewport stays measured while its data is reauthorized. */
export function usePresentationNativeLayout(required=true) {
  const app=useOptionalReview()?.app;const focused=useIsFocused();
  const [ready,setReady]=useState(false);
  usePresentationReadiness(app,!!app&&focused&&required,ready,'native-scaffold-layout');
  return (event:LayoutChangeEvent)=>setReady(event.nativeEvent.layout.width>0&&event.nativeEvent.layout.height>0);
}
