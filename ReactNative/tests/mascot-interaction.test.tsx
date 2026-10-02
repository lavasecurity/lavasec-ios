import {act,renderHook} from '@testing-library/react-native';
import {AppState,type AppStateStatus} from 'react-native';
import {FeedbackProvider} from '../src/feedback';
import {useMascotTapInteraction,MascotDownwardScroll,useMascotDownwardScroll} from '../review/mascot-interaction';
import type {PropsWithChildren} from 'react';
let mockObserve:((sample?:{offset:number;windowHeight:number})=>void)|undefined;
jest.mock('../review/primitives',()=>({usePageScrollObservation:(observe:typeof mockObserve)=>{mockObserve=observe;}}));
jest.mock('@react-navigation/native',()=>({useIsFocused:()=>true}));
jest.mock('../review/navigation-scaffold',()=>({useReducedMotionPreference:()=>false}));
beforeEach(()=>{jest.useFakeTimers();Object.defineProperty(AppState,'currentState',{configurable:true,value:'active'});});
afterEach(()=>{jest.useRealTimers();jest.restoreAllMocks();});
test('tap affirms independently and bounds overlapping animation',()=>{
 const emit=jest.fn();const wrapper=({children}:PropsWithChildren)=><FeedbackProvider value={{emit}}>{children}</FeedbackProvider>;
 const hook=renderHook(()=>useMascotTapInteraction(),{wrapper});
 act(()=>hook.result.current.tap());expect(hook.result.current.grateful).toBe(true);
 act(()=>hook.result.current.tap());expect(emit).toHaveBeenCalledTimes(2);expect(jest.getTimerCount()).toBe(2);
 expect(emit).toHaveBeenLastCalledWith({semantic:'acknowledged',controlID:'mascot.tap'});
 act(()=>jest.advanceTimersByTime(790));expect(hook.result.current.grateful).toBe(false);
 act(()=>jest.advanceTimersByTime(440));act(()=>hook.result.current.tap());expect(hook.result.current.grateful).toBe(true);
 hook.unmount();expect(jest.getTimerCount()).toBe(0);
});
test('background cancels gratitude and stale taps, foreground permits a fresh tap; disabled stays silent',()=>{
 let listener:(state:AppStateStatus)=>void=()=>{};jest.spyOn(AppState,'addEventListener').mockImplementation((_event,callback)=>{listener=callback;return {remove:jest.fn()};});
 const emit=jest.fn();const wrapper=({children}:PropsWithChildren)=><FeedbackProvider value={{emit}}>{children}</FeedbackProvider>;
 const hook=renderHook(({enabled}:{enabled:boolean})=>useMascotTapInteraction(enabled),{initialProps:{enabled:true},wrapper});
 act(()=>hook.result.current.tap());const staleTap=hook.result.current.tap;
 act(()=>listener('inactive'));act(()=>staleTap());expect(emit).toHaveBeenCalledTimes(1);expect(hook.result.current.grateful).toBe(false);expect(jest.getTimerCount()).toBe(0);
 act(()=>listener('active'));act(()=>hook.result.current.tap());expect(emit).toHaveBeenCalledTimes(2);
 hook.rerender({enabled:false});act(()=>hook.result.current.tap());expect(emit).toHaveBeenCalledTimes(2);expect(hook.result.current.grateful).toBe(false);
});

test('feedback remains eligible when visual gratitude is disabled and a state change cancels old gratitude',()=>{
 const emit=jest.fn();const wrapper=({children}:PropsWithChildren)=><FeedbackProvider value={{emit}}>{children}</FeedbackProvider>;
 const hook=renderHook(({animationEnabled}:{animationEnabled:boolean})=>useMascotTapInteraction(true,animationEnabled),{initialProps:{animationEnabled:true},wrapper});
 act(()=>hook.result.current.tap());expect(hook.result.current.grateful).toBe(true);
 hook.rerender({animationEnabled:false});expect(hook.result.current.grateful).toBe(false);expect(jest.getTimerCount()).toBe(0);
 act(()=>hook.result.current.tap());expect(emit).toHaveBeenCalledTimes(2);expect(hook.result.current.grateful).toBe(false);expect(jest.getTimerCount()).toBe(0);
 hook.rerender({animationEnabled:true});expect(hook.result.current.grateful).toBe(false);
 hook.unmount();
});


test('downward scrolling admits one silent cue and rearms after upward scrolling',()=>{
 const policy=new MascotDownwardScroll();
 expect(policy.observe(0)).toBe(false);
 expect(policy.observe(25)).toBe(true);
 expect(policy.observe(50)).toBe(false);
 expect(policy.observe(20)).toBe(false);
 expect(policy.observe(45)).toBe(true);
 policy.reset();expect(policy.observe(45)).toBe(false);
 expect(policy.observe(45)).toBe(false);
});
test('scroll affirmation is silent and shares the bounded tap animation',()=>{
 const emit=jest.fn();const wrapper=({children}:PropsWithChildren)=><FeedbackProvider value={{emit}}>{children}</FeedbackProvider>;
 const hook=renderHook(()=>useMascotTapInteraction(),{wrapper});
 act(()=>hook.result.current.scrollDown());expect(hook.result.current.grateful).toBe(true);expect(emit).not.toHaveBeenCalled();
 act(()=>hook.result.current.tap());expect(emit).toHaveBeenCalledTimes(1);expect(jest.getTimerCount()).toBe(2);
 hook.unmount();
});
test('downward scroll resets on layout and inactive lifetimes',()=>{
 const cue=jest.fn();
 const hook=renderHook(({active}:{active:boolean})=>useMascotDownwardScroll(active,cue),{initialProps:{active:true}});
 act(()=>mockObserve?.({offset:0,windowHeight:800}));
 act(()=>mockObserve?.({offset:300,windowHeight:800}));expect(cue).toHaveBeenCalledTimes(1);
 act(()=>hook.result.current.onLayout());
 act(()=>mockObserve?.({offset:301,windowHeight:800}));expect(cue).toHaveBeenCalledTimes(1);
 hook.rerender({active:false});
 act(()=>mockObserve?.({offset:600,windowHeight:800}));expect(cue).toHaveBeenCalledTimes(1);
 hook.unmount();
});
