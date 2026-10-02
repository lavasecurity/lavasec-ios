import {createContext,useCallback,useContext,useEffect,useRef,type RefObject} from 'react';
import {AppState,type ScrollViewInstance} from 'react-native';

type ScrollLock=(owner:symbol,locked:boolean)=>void;
export const ScrollInteractionContext=createContext<ScrollLock>(()=>{});

/** A page restores its normal scrolling only after every active contact releases. */
export function useScrollInteractionController(scroll:RefObject<ScrollViewInstance|null>,enabled=true,focused=true):ScrollLock {
  const owners=useRef(new Set<symbol>());
  const normal=useRef(enabled);normal.current=enabled;
  const update=useCallback(()=>scroll.current?.setNativeProps({scrollEnabled:normal.current&&owners.current.size===0}),[scroll]);
  const lock=useCallback<ScrollLock>((owner,locked)=>{if(locked)owners.current.add(owner);else owners.current.delete(owner);update();},[update]);
  useEffect(()=>{if(!focused)owners.current.clear();update();},[enabled,focused,update]);
  useEffect(()=>{
    const listener=AppState.addEventListener('change',state=>{if(state!=='active'){owners.current.clear();update();}});
    return()=>{listener?.remove();owners.current.clear();update();};
  },[update]);
  return lock;
}

/** Sliders, inspection and held actions share contact lifetime, including cancellation. */
export function useScrollInteractionLock(controller?:ScrollLock){
  const context=useContext(ScrollInteractionContext);
  const setLocked=controller??context;
  const owner=useRef(Symbol('scroll interaction'));
  const lock=useCallback((locked:boolean)=>setLocked(owner.current,locked),[setLocked]);
  useEffect(()=>()=>lock(false),[lock]);
  return lock;
}

export function useHeldActionScrollLock(enabled:boolean){
  const lock=useScrollInteractionLock();
  useEffect(()=>{if(!enabled)lock(false);},[enabled,lock]);
  return enabled?{
    onPressIn:()=>lock(true),onPressOut:()=>lock(false),
    pressRetentionOffset:{top:44,bottom:44,left:44,right:44},
  }:{};
}
