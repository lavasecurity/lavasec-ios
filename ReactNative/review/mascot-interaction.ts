import {useCallback,useEffect,useRef,useState} from 'react';
import {AppState} from 'react-native';
import {useIsFocused} from '@react-navigation/native';
import {usePageScrollObservation,type PageScrollSample} from './primitives';
import {useFeedback} from '../src/feedback';
import {useReducedMotionPreference} from './navigation-scaffold';

/** Tap feedback and visual gratitude have separate eligibility: Guard acknowledges every
 * expression while keeping non-awake protection states visible. */
export function useMascotTapInteraction(enabled=true,animationEnabled=enabled) {
  const focused=useIsFocused();const feedback=useFeedback();const reduced=useReducedMotionPreference();
  const [foreground,setForeground]=useState(AppState.currentState==='active');
  const [grateful,setGrateful]=useState(false);const animating=useRef(false);
  const timers=useRef<ReturnType<typeof setTimeout>[]>([]);
  const active=useRef(focused&&enabled&&foreground);
  active.current=focused&&enabled&&foreground;
  const cancel=()=>{timers.current.forEach(clearTimeout);timers.current=[];animating.current=false;setGrateful(false);};
  useEffect(()=>{if(!focused||!enabled||!animationEnabled)cancel();},[focused,enabled,animationEnabled]);
  useEffect(()=>{
    const listener=AppState.addEventListener('change',state=>{
      active.current=state==='active'&&focused&&enabled;
      setForeground(state==='active');if(state!=='active')cancel();
    });
    return()=>{active.current=false;listener.remove();timers.current.forEach(clearTimeout);timers.current=[];};
  },[focused,enabled]);
  const affirm=(withFeedback:boolean)=>{
    if(!active.current)return;
    if(withFeedback)feedback.emit({semantic:'acknowledged',controlID:'mascot.tap'});
    if(!animationEnabled||animating.current)return;
    animating.current=true;setGrateful(true);
    timers.current.push(setTimeout(()=>setGrateful(false),(0.44+(reduced?0.2:0.35))*1000),
      setTimeout(()=>{animating.current=false;timers.current=[];},(0.88+(reduced?0.2:0.35))*1000));
  };
  return {grateful,active:focused&&enabled&&foreground,tap:()=>affirm(true),scrollDown:()=>affirm(false)};
}

/** Admit one silent cue when the page begins scrolling down. Moving upward rearms it. */
export class MascotDownwardScroll {
  private previousOffset?:number;
  private admitted=false;
  reset(){this.previousOffset=undefined;this.admitted=false;}
  observe(offset:number):boolean {
    const previous=this.previousOffset;
    this.previousOffset=offset;
    if(previous===undefined)return false;
    if(offset<previous)this.admitted=false;
    if(offset<=previous||this.admitted)return false;
    this.admitted=true;
    return true;
  }
}

export function useMascotDownwardScroll(active:boolean,onScrollDown:()=>void){
  const policy=useRef(new MascotDownwardScroll()).current;
  const latest=useRef({active,onScrollDown});latest.current={active,onScrollDown};
  const reset=useCallback(()=>{policy.reset();},[policy]);
  useEffect(()=>{reset();return reset;},[active,reset]);
  const observe=useCallback((sample?:PageScrollSample)=>{
    if(!sample||!latest.current.active){reset();return;}
    if(policy.observe(sample.offset))latest.current.onScrollDown();
  },[policy,reset]);
  usePageScrollObservation(observe);
  return {onLayout:reset};
}
