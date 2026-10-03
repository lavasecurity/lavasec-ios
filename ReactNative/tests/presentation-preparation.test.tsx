import {useLayoutEffect,useSyncExternalStore,type PropsWithChildren} from 'react';
import {AppState,Text,View,type AppStateStatus} from 'react-native';
import {act,renderHook,render,screen} from '@testing-library/react-native';
import {useFilterRoute} from '../review/filter-route';
import {ReviewScreen} from '../review/FilterScreens';
import {ReviewContext,type ReviewState} from '../review/ReviewContext';
import {initialSession} from '../review/session';
import {AppStore} from '../app/store';
import type {AppSnapshot,AppCommand} from '../app/contract';
import type {Spec} from '../specs/NativeLavaApp';
const mockBack=jest.fn();
jest.mock('@react-navigation/native',()=>({useIsFocused:()=>true,useNavigation:()=>({goBack:mockBack,navigate:jest.fn(),setOptions:jest.fn()}),useRoute:()=>({params:{id:'one'}}),usePreventRemove:jest.fn()}));
jest.mock('../review/scaffold',()=>{
  const React=require('react');const {View}=require('react-native');const Wrapper=({children}:{children:import('react').ReactNode})=>React.createElement(View,null,children);
  return new Proxy({useToolbar:()=>{},Sheet:({children,footer}:{children:import('react').ReactNode;footer:import('react').ReactNode})=>React.createElement(View,null,children,footer)}, {get:(target:Record<string,unknown>,key:string)=>key in target?target[key]:Wrapper});
});
jest.mock('../review/primitives',()=>{
  const React=require('react');const {Text}=require('react-native');return new Proxy({Info:({description}:{description:string})=>React.createElement(Text,null,description)}, {get:(target:Record<string,unknown>,key:string)=>key in target?target[key]:({children}:{children:import('react').ReactNode})=>React.createElement(Text,null,children)});
});
jest.mock('../specs/NativeLavaReview',()=>({__esModule:true,default:{getGuardAccents:()=>JSON.stringify({})}}));
jest.mock('../specs/LavaDecorationNativeComponent',()=>({__esModule:true,default:require('react-native').View}));
const deferred=<T,>()=>{let resolve!:(value:T)=>void;let reject!:(error:Error)=>void;const promise=new Promise<T>((yes,no)=>{resolve=yes;reject=no;});return {resolve,reject,promise};};
const snapshot=(revision:number,selected='one',editing=true):AppSnapshot=>({schema:1,fullApp:true,revision,backgroundPrivacyCoverRequired:true,
  session:{...initialSession(),filterID:selected,activeFilterID:'one',editing},filters:[{id:'one',name:'One',frozen:false}],draft:{blocked:['private.example'],allowed:[]},savedDraft:{blocked:[],allowed:[]},
  filterEditing:{reviewCanConfirm:true},security:{unavailable:false,readRevision:0,sourceRevision:'source-1',ownerRevision:'owner-1',displayClearRevision:'clear-1'}} as unknown as AppSnapshot);
function setup(initial:AppSnapshot){
  const listeners=new Set<(state:AppStateStatus)=>void>();const original=AppState.currentState;AppState.currentState='active';
  const lifecycle=jest.spyOn(AppState,'addEventListener').mockImplementation((_event,listener)=>{listeners.add(listener);return {remove:()=>listeners.delete(listener)};});
  const replies:{request:AppCommand;read:ReturnType<typeof deferred<string>>}[]=[];let publish!:(value:string)=>void;let fresh=JSON.stringify(initial);
  const native={getSnapshot:jest.fn(async()=>fresh),onSnapshot:(callback:(value:string)=>void)=>{publish=callback;return {remove(){}};},command:jest.fn((value:string)=>{const read=deferred<string>();replies.push({request:JSON.parse(value),read});return read.promise;})} as unknown as Spec;
  const app=new AppStore(native,initial);const disconnect=app.connect();
  const emit=(value:AppSnapshot)=>{fresh=JSON.stringify(value);publish(fresh);};
  const move=(state:AppStateStatus)=>{AppState.currentState=state;for(const listener of [...listeners])listener(state);};
  function Wrapper({children}:PropsWithChildren){const state=useSyncExternalStore(app.subscribe,app.getSnapshot),gate=useSyncExternalStore(app.subscribe,app.getPresentationHydration);
    useLayoutEffect(()=>{if(state.snapshot&&AppState.currentState==='active')app.completePresentationLayout(gate.epoch);},[state.snapshot,gate.epoch]);
    const live=state.snapshot??state.displaySnapshot??undefined;
    return <ReviewContext.Provider value={{app,live,session:live?.session??initial.session,draft:live?.draft??initial.draft,savedDraft:live?.savedDraft??initial.savedDraft} as unknown as ReviewState}><View>{children}<Text>{gate.required?'covered':'revealed'}</Text></View></ReviewContext.Provider>;}
  return {app,native,replies,Wrapper,emit,move,finish:()=>{disconnect();lifecycle.mockRestore();AppState.currentState=original;}};
}
test('a restored filter detail prepares its original native owner before the warm cover releases',async()=>{
  const harness=setup(snapshot(1));
  try{
    await act(async()=>{});act(()=>harness.move('inactive'));act(()=>harness.move('active'));
    act(()=>harness.emit(snapshot(2,'other',false)));
    const hook=renderHook(()=>useFilterRoute(true),{wrapper:harness.Wrapper});
    await act(async()=>{});expect(harness.app.getPresentationHydration().required).toBe(true);expect(hook.result.current.ready).toBe(false);
    expect(harness.replies.at(-1)?.request).toEqual({type:'filter.open',id:'one'});
    await act(async()=>harness.replies.at(-1)!.read.resolve(JSON.stringify({snapshot:snapshot(3,'one',false),result:null})));
    expect(hook.result.current.ready).toBe(true);expect(harness.app.getPresentationHydration().required).toBe(false);hook.unmount();
  }finally{harness.finish();}
});
test('a focused review validates a new resume capability beneath the cover and does not loop on source revisions',async()=>{
  const harness=setup(snapshot(1));
  try{
    await act(async()=>{});act(()=>harness.move('inactive'));act(()=>harness.move('active'));act(()=>harness.emit(snapshot(2)));
    const view=render(<harness.Wrapper><ReviewScreen/></harness.Wrapper>);
    await act(async()=>{});expect(screen.getByText('covered')).toBeTruthy();expect(harness.replies).toHaveLength(1);
    expect(harness.replies[0]!.request).toEqual({type:'filter.review',id:'one'});
    await act(async()=>harness.replies[0]!.read.resolve(JSON.stringify({snapshot:{...snapshot(3),security:{...snapshot(3).security,sourceRevision:'source-2'}},result:'review-capability'})));
    expect(screen.getByText('revealed')).toBeTruthy();expect(screen.getByRole('button',{name:'Confirm changes'})).toBeEnabled();expect(harness.replies).toHaveLength(1);
    view.unmount();
  }finally{harness.finish();}
});
test('a review invalidates its old capability as soon as native authority is revoked and validates again after resume',async()=>{
  const harness=setup({...snapshot(1),backgroundPrivacyCoverRequired:false});
  try{
    const view=render(<harness.Wrapper><ReviewScreen/></harness.Wrapper>);await act(async()=>{});
    await act(async()=>harness.replies[0]!.read.resolve(JSON.stringify({snapshot:{...snapshot(2),backgroundPrivacyCoverRequired:false},result:'old-capability'})));
    expect(screen.getByRole('button',{name:'Confirm changes'})).toBeEnabled();
    act(()=>harness.move('inactive'));expect(screen.getByRole('button',{name:'Confirm changes'})).toBeDisabled();
    act(()=>harness.move('active'));act(()=>harness.emit({...snapshot(3),backgroundPrivacyCoverRequired:false}));await act(async()=>{});
    expect(harness.replies.filter(value=>value.request.type==='filter.review')).toHaveLength(2);
    expect(screen.getByRole('button',{name:'Confirm changes'})).toBeDisabled();
    await act(async()=>harness.replies.at(-1)!.read.resolve(JSON.stringify({snapshot:{...snapshot(4),backgroundPrivacyCoverRequired:false},result:'new-capability'})));
    expect(screen.getByRole('button',{name:'Confirm changes'})).toBeEnabled();view.unmount();
  }finally{harness.finish();}
});
