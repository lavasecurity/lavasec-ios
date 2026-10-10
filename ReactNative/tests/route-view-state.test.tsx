import {useEffect} from 'react';
import {AppState,Text} from 'react-native';
import {act,render} from '@testing-library/react-native';
import {useRouteViewState} from '../app/use-route-view-state';
import {LiveRenderBoundary,ReviewContext,type ReviewState} from '../review/ReviewContext';
import type {AppSnapshot} from '../app/contract';

test('same-owner selection remains dormant through concealment and old callbacks cannot adopt the restored epoch',()=>{
  const original=AppState.currentState;Object.defineProperty(AppState,'currentState',{configurable:true,value:'active'});
  let epoch=1,current:AppSnapshot|null=null,mounts=0,setSelection!:(value:string)=>void,resetSelection!:()=>void;
  const app={getSnapshot:()=>({snapshot:current}),getReadEpoch:()=>epoch};
  const live={security:{ownerRevision:'owner-1',readRevision:1},session:{protectedActions:{},passcode:true}} as unknown as AppSnapshot;
  function Body(){const [selection,set,reset]=useRouteViewState('Today');setSelection=set;resetSelection=reset;useEffect(()=>{mounts++;},[]);return <Text>{selection}</Text>;}
  const content=(snapshot?:AppSnapshot)=>{current=snapshot??null;return <ReviewContext.Provider value={{app,live:snapshot} as unknown as ReviewState}><LiveRenderBoundary component={Body}/></ReviewContext.Provider>;};
  try{
    const view=render(content(live));act(()=>setSelection('Custom'));const text=view.getByText('Custom'),oldSetter=setSelection,oldReset=resetSelection;
    epoch++;view.rerender(content());act(()=>oldSetter('Fallback'));
    expect(view.queryByText('Custom')).toBeNull();expect(view.getByText('Custom',{includeHiddenElements:true})).toBe(text);
    view.rerender(content({...live,security:{...live.security,readRevision:2}}));
    expect(view.getByText('Custom')).toBe(text);expect(mounts).toBe(1);act(()=>oldSetter('Stale'));
    expect(view.getByText('Custom')).toBe(text);act(()=>setSelection('Week'));expect(view.getByText('Week')).toBeTruthy();
    epoch++;view.rerender(content({...live,security:{...live.security,ownerRevision:'owner-2'}}));
    expect(view.getByText('Today')).toBeTruthy();expect(mounts).toBe(2);
    act(()=>setSelection('New owner selection'));act(()=>oldReset());
    expect(view.getByText('New owner selection')).toBeTruthy();view.unmount();
  }finally{Object.defineProperty(AppState,'currentState',{configurable:true,value:original});}
});


test('internal lifecycle reset can only restore initial state while the same visit is concealed',()=>{
  const original=AppState.currentState;Object.defineProperty(AppState,'currentState',{configurable:true,value:'active'});
  let epoch=1,current:AppSnapshot|null=null,setSelection!:(value:string)=>void,reset!:()=>void;
  const app={getSnapshot:()=>({snapshot:current}),getReadEpoch:()=>epoch};
  const live={security:{ownerRevision:'owner',readRevision:1},session:{protectedActions:{},passcode:true}} as unknown as AppSnapshot;
  function Body(){const [selection,set,clear]=useRouteViewState('None');setSelection=set;reset=clear;return <Text>{selection}</Text>;}
  const content=(snapshot?:AppSnapshot)=>{current=snapshot??null;return <ReviewContext.Provider value={{app,live:snapshot} as unknown as ReviewState}><LiveRenderBoundary component={Body}/></ReviewContext.Provider>;};
  try{
    const view=render(content(live));act(()=>setSelection('Selected'));const oldSetter=setSelection;
    Object.defineProperty(AppState,'currentState',{configurable:true,value:'background'});epoch++;view.rerender(content());
    act(()=>oldSetter('Stale edit'));expect(view.getByText('Selected',{includeHiddenElements:true})).toBeTruthy();
    act(()=>reset());expect(view.getByText('None',{includeHiddenElements:true})).toBeTruthy();
    Object.defineProperty(AppState,'currentState',{configurable:true,value:'active'});view.rerender(content(live));
    act(()=>oldSetter('Stale edit'));expect(view.getByText('None')).toBeTruthy();view.unmount();
  }finally{Object.defineProperty(AppState,'currentState',{configurable:true,value:original});}
});
