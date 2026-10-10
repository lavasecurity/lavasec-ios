import {useLayoutEffect,useSyncExternalStore,type ComponentType} from 'react';
import {AppState,ScrollView,type AppStateStatus} from 'react-native';
import {act,fireEvent,render,screen} from '@testing-library/react-native';
import {AppStore} from '../app/store';
import type {AppSnapshot} from '../app/contract';
import type {Spec} from '../specs/NativeLavaApp';
import NativeTextField from '../specs/LavaTextFieldNativeComponent';
import {AddDomainScreen,ReviewScreen} from '../review/FilterScreens';
import {LiveRenderBoundary,ReviewContext,type ReviewState} from '../review/ReviewContext';
import {Sheet} from '../review/scaffold';
import {LavaActionButton} from '../src';
import {initialPreviewDraft} from '../review/preview-model';
import {initialSession} from '../review/session';

let mockDecision:'blocked'|'allowed'='blocked';
const mockNavigation={navigate:jest.fn(),goBack:jest.fn(),setOptions:jest.fn(),addListener:()=>()=>{}};
jest.mock('@react-navigation/native',()=>({useNavigation:()=>mockNavigation,useRoute:()=>({params:{id:'saved',decision:mockDecision}}),useIsFocused:()=>true,usePreventRemove:jest.fn(),useScrollToTop:jest.fn()}));
jest.mock('react-native-safe-area-context',()=>require('react-native-safe-area-context/jest/mock').default);
jest.mock('../specs/LavaDecorationNativeComponent',()=>({__esModule:true,default:require('react-native').View}));
jest.mock('../specs/LavaSliderNativeComponent',()=>({__esModule:true,default:require('react-native').View}));
jest.mock('../specs/LavaChoiceNativeComponent',()=>require('./native-choice-mock'));
jest.mock('../specs/NativeLavaReview',()=>({__esModule:true,default:{getGuardAccents:()=>JSON.stringify({original:{light:'#BF4000',dark:'#FF8855'}})}}));
jest.mock('../specs/LavaTextFieldNativeComponent',()=>({__esModule:true,default:function NativeBuffer(props:any){
  const React=require('react');const {TextInput}=require('react-native');
  // DomainInput is an uncontrolled UIKit field: a new native instance starts
  // empty, whereas a retained instance owns its existing text and selection.
  const [buffer,setBuffer]=React.useState('');
  return React.createElement(TextInput,{accessibilityLabel:props.inputLabel,value:buffer,editable:props.editable??true,
    onChangeText:(text:string)=>{setBuffer(text);props.onChange({nativeEvent:{text}});},
    onSubmitEditing:()=>props.onSubmit({nativeEvent:{text:buffer}})});
}}));

function lifecycle(component:ComponentType){
  const previous=AppState.currentState,originalListener=AppState.addEventListener;
  Object.defineProperty(AppState,'currentState',{configurable:true,value:'active'});
  const listeners=new Set<(state:AppStateStatus)=>void>();
  AppState.addEventListener=(_event,listener)=>{const callback=listener as (state:AppStateStatus)=>void;listeners.add(callback);return {remove:()=>{listeners.delete(callback);}};};
  let current={schema:1,fullApp:true,revision:1,backgroundPrivacyCoverRequired:true,
    security:{ownerRevision:'form-owner',readRevision:1},look:'original',
    session:{...initialSession(),passcode:true,filterID:'saved',activeFilterID:'saved',editing:true},
    filters:[{id:'saved',name:'Private saved filter',frozen:false}],
    draft:initialPreviewDraft(),savedDraft:initialPreviewDraft(),
    limits:{maxBlockedDomains:25,maxAllowedDomains:25},plus:{enabled:false},
    filterEditing:{reviewCanConfirm:true},
  } as unknown as AppSnapshot;
  let publish!:(value:string)=>void;
  const native={getSnapshot:()=>new Promise<string>(()=>{}),
    command:jest.fn(async(raw:string)=>JSON.stringify({snapshot:current,result:JSON.parse(raw).type==='filter.review'?`review-${current.revision}`:null})),
    onSnapshot:(callback:(value:string)=>void)=>{publish=callback;return {remove(){}};},
  } as unknown as Spec;
  const app=new AppStore(native,current),disconnect=app.connect();
  function Provider(){
    const state=useSyncExternalStore(app.subscribe,app.getSnapshot);
    const gate=useSyncExternalStore(app.subscribe,app.getPresentationHydration);
    const live=state.snapshot??undefined;
    useLayoutEffect(()=>{if(live)app.completePresentationLayout(gate.epoch);},[live,gate.epoch]);
    return <ReviewContext.Provider value={{app,live,session:live?.session??initialSession(),look:'original',
      draft:live?.draft??initialPreviewDraft(),savedDraft:live?.savedDraft??initialPreviewDraft(),
    } as ReviewState}><LiveRenderBoundary component={component} directScrollRoot/></ReviewContext.Provider>;
  }
  const view=render(<Provider/>);
  const emit=(state:AppStateStatus)=>act(()=>{Object.defineProperty(AppState,'currentState',{configurable:true,value:state});listeners.forEach(listener=>listener(state));});
  const project=async(overrides:Omit<Partial<AppSnapshot>,'security'>&{security?:Partial<AppSnapshot['security']>}={})=>{current={...current,...overrides,revision:current.revision+1,
    security:{...current.security,...overrides.security,readRevision:(current.security?.readRevision??0)+1}};
    await act(async()=>publish(JSON.stringify(current)));
  };
  const layout=()=>fireEvent(screen.UNSAFE_getByType(ScrollView),'layout',{nativeEvent:{layout:{x:0,y:0,width:390,height:844}}});
  const dispose=()=>{view.unmount();act(()=>disconnect());AppState.addEventListener=originalListener;Object.defineProperty(AppState,'currentState',{configurable:true,value:previous});};
  return {app,native,emit,project,layout,dispose};
}

test.each(['blocked','allowed'] as const)('the %s domain field retains the visible draft and scroll through unlock, rejects old callbacks, and submits exactly the visible text',async decision=>{
  mockDecision=decision;mockNavigation.goBack.mockClear();
  const runtime=lifecycle(AddDomainScreen),label=decision==='blocked'?'Domain to block':'Domain to allow';
  try{
    runtime.layout();await act(async()=>{});
    const field=screen.UNSAFE_getByType(NativeTextField),scroll=screen.UNSAFE_getByType(ScrollView);
    fireEvent.changeText(screen.getByLabelText(label),'visible.example');
    const oldChange=field.props.onChange,oldSubmit=field.props.onSubmit;
    const oldAdd=screen.UNSAFE_getByType(LavaActionButton).props.onPress;
    runtime.emit('background');
    expect(runtime.app.getSnapshot().snapshot).toBeNull();
    expect(screen.getByTestId('lava-route-privacy-cover')).toBeTruthy();
    expect(screen.UNSAFE_getByType(ScrollView)).toBe(scroll);
    expect(screen.UNSAFE_getByType(NativeTextField)).toBe(field);
    expect(screen.getByLabelText(label,{includeHiddenElements:true})).toHaveProp('value','visible.example');
    expect(screen.getByLabelText(label,{includeHiddenElements:true})).toHaveProp('editable',false);
    expect(screen.UNSAFE_getByType(LavaActionButton).props.disabled).toBe(true);
    await act(async()=>{oldSubmit({nativeEvent:{text:'stale.example'}});oldAdd();});
    expect(runtime.native.command).not.toHaveBeenCalled();
    runtime.emit('active');await runtime.project();
    expect(screen.queryByTestId('lava-route-privacy-cover')).toBeNull();
    expect(screen.UNSAFE_getByType(ScrollView)).toBe(scroll);
    expect(screen.UNSAFE_getByType(NativeTextField)).toBe(field);
    expect(screen.getByLabelText(label)).toHaveProp('value','visible.example');
    await act(async()=>{oldChange({nativeEvent:{text:'stale.example'}});oldSubmit({nativeEvent:{text:'stale.example'}});oldAdd();});
    expect(runtime.native.command).not.toHaveBeenCalled();
    await act(async()=>screen.UNSAFE_getByType(LavaActionButton).props.onPress());
    expect((runtime.native.command as jest.Mock).mock.calls.map(([raw])=>JSON.parse(raw))).toEqual([{type:'filter.domain',id:'saved',domain:'visible.example',decision}]);
    expect(mockNavigation.goBack).toHaveBeenCalledTimes(1);
  }finally{runtime.dispose();}
});

test('an actual domain-form owner replacement retires the draft and native input together',async()=>{
  mockDecision='blocked';const runtime=lifecycle(AddDomainScreen);
  try{
    runtime.layout();await act(async()=>{});
    const field=screen.UNSAFE_getByType(NativeTextField);
    fireEvent.changeText(screen.getByLabelText('Domain to block'),'prior-owner.example');
    const oldAdd=screen.UNSAFE_getByType(LavaActionButton).props.onPress;
    await runtime.project({security:{ownerRevision:'replacement-owner',readRevision:2}});
    runtime.layout();await act(async()=>{});
    expect(screen.UNSAFE_getByType(NativeTextField)).not.toBe(field);
    expect(screen.getByLabelText('Domain to block')).toHaveProp('value','');
    expect(screen.UNSAFE_getByType(LavaActionButton).props.disabled).toBe(true);
    await act(async()=>oldAdd());
    expect(runtime.native.command).not.toHaveBeenCalled();
  }finally{runtime.dispose();}
});

test('the review sheet retains its native scroll while old validation retires and current authorization prepares under the cover',async()=>{
  const runtime=lifecycle(ReviewScreen);
  try{
    runtime.layout();await act(async()=>{});
    const sheet=screen.UNSAFE_getByType(Sheet),scroll=screen.UNSAFE_getByType(ScrollView);
    expect(sheet.props.footer.props.disabled).toBe(false);
    runtime.emit('background');
    expect(screen.getByTestId('lava-route-privacy-cover')).toBeTruthy();
    expect(screen.UNSAFE_getByType(Sheet)).toBe(sheet);
    expect(screen.UNSAFE_getByType(ScrollView)).toBe(scroll);
    expect(sheet.props.footer.props.disabled).toBe(true);
    runtime.emit('active');await runtime.project();
    expect(screen.UNSAFE_getByType(Sheet)).toBe(sheet);
    expect(screen.UNSAFE_getByType(ScrollView)).toBe(scroll);
    expect(screen.queryByTestId('lava-route-privacy-cover')).toBeNull();
    expect(sheet.props.footer.props.disabled).toBe(false);
    expect((runtime.native.command as jest.Mock).mock.calls.map(([raw])=>JSON.parse(raw).type)).toEqual(['filter.review','filter.review']);
  }finally{runtime.dispose();}
});
