import {useLayoutEffect,useSyncExternalStore} from 'react';
import {AppState,type AppStateStatus} from 'react-native';
import {act,fireEvent,render,screen} from '@testing-library/react-native';
import {AppStore} from '../app/store';
import type {AppSnapshot} from '../app/contract';
import type {Spec} from '../specs/NativeLavaApp';
import {DeviceQAScreen} from '../review/NativePageScreen';
import {LiveRenderBoundary,ReviewContext,type ReviewState} from '../review/ReviewContext';
import {initialSession} from '../review/session';

const mockGoBack=jest.fn();
jest.mock('@react-navigation/native',()=>({useNavigation:()=>({goBack:mockGoBack}),useIsFocused:()=>true}));
jest.mock('react-native-safe-area-context',()=>require('react-native-safe-area-context/jest/mock').default);
jest.mock('../specs/NativeLavaReview',()=>({__esModule:true,default:{getGuardAccents:()=>JSON.stringify({})}}));
jest.mock('../specs/LavaNativePageNativeComponent',()=>{
  const React=require('react');const {TextInput,View}=require('react-native');
  // UIKit/SwiftUI owns this unpublished configuration buffer. Its identity is
  // intentionally opaque to DeviceQAScreen, just like PhoneQAView's @State.
  return {__esModule:true,default:(props:object)=>{
    const [draft,setDraft]=React.useState('');
    return React.createElement(View,props,React.createElement(TextInput,{
      testID:'qa-native-configuration',value:draft,onChangeText:setDraft,
    }));
  }};
});

function harness({rootLayout=true}:{rootLayout?:boolean}={}){
  const previous=AppState.currentState,originalListener=AppState.addEventListener;
  Object.defineProperty(AppState,'currentState',{configurable:true,value:'active'});
  const listeners=new Set<(state:AppStateStatus)=>void>();
  AppState.addEventListener=(_event,listener)=>{
    const callback=listener as (state:AppStateStatus)=>void;listeners.add(callback);
    return {remove:()=>{listeners.delete(callback);}};
  };
  const emitState=(state:AppStateStatus)=>act(()=>{
    Object.defineProperty(AppState,'currentState',{configurable:true,value:state});
    listeners.forEach(listener=>listener(state));
  });
  let current={schema:1,fullApp:true,revision:1,qaTools:true,backgroundPrivacyCoverRequired:true,
    security:{ownerRevision:'qa-owner',readRevision:1},session:initialSession(),
  } as unknown as AppSnapshot;
  let publish!:(value:string)=>void;
  const native={getSnapshot:()=>new Promise<string>(()=>{}),
    command:jest.fn(async()=>JSON.stringify({snapshot:current,result:null})),
    onSnapshot:(callback:(value:string)=>void)=>{publish=callback;return {remove(){}};},
  } as unknown as Spec;
  const app=new AppStore(native,current,{initial:true}),disconnect=app.connect();
  function Provider(){
    const state=useSyncExternalStore(app.subscribe,app.getSnapshot);
    const gate=useSyncExternalStore(app.subscribe,app.getPresentationHydration);
    const live=state.snapshot??undefined;
    useLayoutEffect(()=>{if(live&&rootLayout)app.completePresentationLayout(gate.epoch);},[live,gate.epoch]);
    return <ReviewContext.Provider value={{app,live,session:live?.session??initialSession()} as ReviewState}>
      <LiveRenderBoundary component={DeviceQAScreen} directScrollRoot/>
    </ReviewContext.Provider>;
  }
  const view=render(<Provider/>);
  return {app,view,emitState,async project(change:Partial<AppSnapshot>){
    current={...current,...change,revision:current.revision+1};
    await act(async()=>publish(JSON.stringify(current)));
  },close(){
    view.unmount();act(()=>disconnect());AppState.addEventListener=originalListener;
    Object.defineProperty(AppState,'currentState',{configurable:true,value:previous});
  }};
}

const viewport=(width=390,height=844)=>({nativeEvent:{layout:{x:0,y:0,width,height}}});
async function measureQA(width=390,height=844){
  await act(async()=>fireEvent(screen.getByTestId('device-qa-page',{includeHiddenElements:true}),'layout',viewport(width,height)));
}

test('cold Device QA stays covered after the root layout until its focused native viewport is nonzero',async()=>{
  const {app,close}=harness();
  try{
    await act(async()=>{});
    expect(app.getPresentationHydration().required).toBe(true);
    expect(screen.getByTestId('lava-route-privacy-cover')).toBeTruthy();
    expect(screen.queryByTestId('qa-native-configuration')).toBeNull();
    const host=screen.getByTestId('device-qa-page',{includeHiddenElements:true});
    await measureQA(390,0);
    expect(app.getPresentationHydration().required).toBe(true);
    await measureQA(0,844);
    expect(app.getPresentationHydration().required).toBe(true);
    await measureQA();
    expect(app.getPresentationHydration().required).toBe(false);
    expect(screen.queryByTestId('lava-route-privacy-cover')).toBeNull();
    expect(screen.getByTestId('device-qa-page')).toBe(host);
    expect(screen.getByTestId('qa-native-configuration')).toHaveProp('value','');
  }finally{close();}
});

test('availability loss retires an unmeasured Device QA ticket without stranding the root cover',async()=>{
  const {app,project,close}=harness();
  try{
    await act(async()=>{});
    expect(app.getPresentationHydration().required).toBe(true);
    await project({qaTools:false});
    expect(screen.queryByTestId('device-qa-page',{includeHiddenElements:true})).toBeNull();
    expect(app.getPresentationHydration().required).toBe(false);
  }finally{close();}
});

test('Device QA reenablement admits a fresh host whose own viewport must satisfy pending readiness',async()=>{
  const {app,project,close}=harness({rootLayout:false});
  try{
    const first=screen.getByTestId('device-qa-page',{includeHiddenElements:true});
    const oldLayout=first.props.onLayout;
    await project({qaTools:false});
    expect(screen.queryByTestId('device-qa-page',{includeHiddenElements:true})).toBeNull();
    await project({qaTools:true});
    const next=screen.getByTestId('device-qa-page',{includeHiddenElements:true});
    expect(next).not.toBe(first);
    await act(async()=>app.completePresentationLayout(app.getPresentationHydration().epoch));
    await act(async()=>oldLayout(viewport()));
    expect(app.getPresentationHydration().required).toBe(true);
    await measureQA(390,0);
    expect(app.getPresentationHydration().required).toBe(true);
    await measureQA();
    expect(app.getPresentationHydration().required).toBe(false);
    expect(screen.getByTestId('device-qa-page')).toBe(next);
  }finally{close();}
});

test('Device QA retains its native configuration host while same-owner fields are revoked and reauthorized',async()=>{
  const {app,emitState,project,close}=harness();
  try{
    await measureQA();
    const host=screen.getByTestId('device-qa-page');
    const field=screen.getByTestId('qa-native-configuration');
    fireEvent.changeText(field,'[Interface]\nPrivateKey = unpublished-native-buffer');
    emitState('background');
    expect(app.getSnapshot().snapshot).toBeNull();
    expect(screen.getByTestId('lava-route-privacy-cover')).toBeTruthy();
    expect(screen.getByTestId('device-qa-page',{includeHiddenElements:true})).toBe(host);
    expect(screen.getByTestId('qa-native-configuration',{includeHiddenElements:true})).toBe(field);
    expect(screen.queryByTestId('qa-native-configuration')).toBeNull();
    expect(host).toHaveProp('pointerEvents','none');
    expect(host).toHaveProp('accessibilityElementsHidden',true);
    emitState('active');
    await project({security:{ownerRevision:'qa-owner',readRevision:2} as AppSnapshot['security']});
    expect(screen.queryByTestId('lava-route-privacy-cover')).toBeNull();
    expect(screen.getByTestId('device-qa-page')).toBe(host);
    expect(screen.getByTestId('qa-native-configuration')).toBe(field);
    expect(field).toHaveProp('value','[Interface]\nPrivateKey = unpublished-native-buffer');
    expect(host).toHaveProp('pointerEvents','auto');
    expect(host).toHaveProp('accessibilityElementsHidden',false);
  }finally{close();}
});

test('Device QA removes its host on explicit availability loss and retires native drafts on owner replacement',async()=>{
  const {app,emitState,project,close}=harness();
  try{
    await measureQA();
    const first=screen.getByTestId('device-qa-page');
    const oldLayout=first.props.onLayout;
    fireEvent.changeText(screen.getByTestId('qa-native-configuration'),'Previous owner draft');
    emitState('background');emitState('active');
    await project({security:{ownerRevision:'next-qa-owner',readRevision:2} as AppSnapshot['security']});
    const next=screen.getByTestId('device-qa-page',{includeHiddenElements:true});
    expect(next).not.toBe(first);
    expect(app.getPresentationHydration().required).toBe(true);
    expect(screen.queryByTestId('qa-native-configuration')).toBeNull();
    await act(async()=>oldLayout(viewport()));
    expect(app.getPresentationHydration().required).toBe(true);
    await measureQA();
    expect(app.getPresentationHydration().required).toBe(false);
    expect(screen.getByTestId('qa-native-configuration')).toHaveProp('value','');
    fireEvent.changeText(screen.getByTestId('qa-native-configuration'),'Withdrawn QA draft');
    await project({qaTools:false});
    expect(screen.queryByTestId('device-qa-page',{includeHiddenElements:true})).toBeNull();
    expect(screen.queryByTestId('qa-native-configuration',{includeHiddenElements:true})).toBeNull();
    emitState('background');emitState('active');
    await project({qaTools:true});
    expect(app.getPresentationHydration().required).toBe(true);
    await measureQA();
    expect(app.getPresentationHydration().required).toBe(false);
    expect(screen.getByTestId('device-qa-page')).not.toBe(next);
    expect(screen.getByTestId('qa-native-configuration')).toHaveProp('value','');
  }finally{close();}
});
