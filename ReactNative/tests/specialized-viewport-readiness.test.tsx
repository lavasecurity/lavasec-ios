import {useLayoutEffect,useSyncExternalStore,type ComponentType} from 'react';
import {AppState,ScrollView} from 'react-native';
import {act,fireEvent,render,screen} from '@testing-library/react-native';
import {AppStore} from '../app/store';
import type {AppSnapshot,OnboardingSetup} from '../app/contract';
import type {Spec} from '../specs/NativeLavaApp';
import {ComponentsScreen} from '../review/screens';
import {LicenseReader} from '../review/form-scaffold';
import {OnboardingFlow} from '../review/OnboardingFlow';
import {OnboardingGeometryContext,type Anchor} from '../review/onboarding-geometry';
import {ReviewContext,useReview,type ReviewState} from '../review/ReviewContext';
import {initialSession} from '../review/session';

let mockFocused=true;
const mockNavigation={setOptions:jest.fn(),navigate:jest.fn(),goBack:jest.fn(),addListener:()=>()=>{}};
jest.mock('@react-navigation/native',()=>({useNavigation:()=>mockNavigation,useIsFocused:()=>mockFocused,useRoute:()=>({params:undefined}),usePreventRemove:jest.fn(),useScrollToTop:jest.fn()}));
jest.mock('react-native-safe-area-context',()=>require('react-native-safe-area-context/jest/mock').default);
jest.mock('../review/navigation-scaffold',()=>({...jest.requireActual('../review/navigation-scaffold'),useReducedMotionPreference:()=>true,useCrossFadePreference:()=>false}));
jest.mock('../specs/LavaDecorationNativeComponent',()=>({__esModule:true,default:require('react-native').View}));
jest.mock('../specs/LavaTextFieldNativeComponent',()=>({__esModule:true,default:require('react-native').View}));
jest.mock('../specs/LavaSliderNativeComponent',()=>({__esModule:true,default:require('react-native').View}));
jest.mock('../specs/LavaChoiceNativeComponent',()=>require('./native-choice-mock'));
jest.mock('../specs/NativeLavaReview',()=>({__esModule:true,default:{getGuardAccents:()=>JSON.stringify({})}}));
jest.mock('../src/GuardianDrawing',()=>({GuardianDrawing:require('react-native').View}));
jest.mock('../src/OnboardingDrawing',()=>({OnboardingBackground:require('react-native').View,OnboardingLavaDrawing:require('react-native').View}));

const initialSetup:OnboardingSetup={id:'onboarding-visit',mock:false,page:0,history:[],visited:[0],level:'balanced',fallback:true,dnsProfile:false,supportsDNSProfile:true,vpnInstalled:false,notifications:false,busy:'',error:'',phase:'setup'};
function License(){return <LicenseReader text="Current bundled license text"/>;}
let geometrySize={width:0,height:0};
function Onboarding(){
  const {live}=useReview();
  const anchor:Anchor={current:null};
  return <OnboardingGeometryContext.Provider value={{panel:anchor,mascot:anchor,action:anchor,source:anchor,root:anchor,
    origin:{x:0,y:0},size:geometrySize,setup:live?.onboardingSetup??undefined,
  }}><OnboardingFlow/></OnboardingGeometryContext.Provider>;
}
function harness(Component:ComponentType,onboarding=false){
  const previous=AppState.currentState;Object.defineProperty(AppState,'currentState',{configurable:true,value:'active'});
  let current={schema:1,fullApp:true,revision:1,backgroundPrivacyCoverRequired:true,qaTools:true,
    security:{ownerRevision:'viewport-owner',readRevision:1},session:initialSession(),
    ...(onboarding?{onboardingSetup:initialSetup}:{}),
  } as unknown as AppSnapshot;
  let publish!:(value:string)=>void;
  const native={getSnapshot:()=>new Promise<string>(()=>{}),command:jest.fn(async()=>JSON.stringify({snapshot:current,result:null})),
    onSnapshot:(callback:(value:string)=>void)=>{publish=callback;return {remove(){}};},
  } as unknown as Spec;
  const app=new AppStore(native,current,{initial:true}),disconnect=app.connect();
  function Provider({visible=true}:{visible?:boolean}){
    const state=useSyncExternalStore(app.subscribe,app.getSnapshot),gate=useSyncExternalStore(app.subscribe,app.getPresentationHydration);
    const live=state.snapshot??undefined;
    useLayoutEffect(()=>{if(live)app.completePresentationLayout(gate.epoch);},[live,gate.epoch]);
    return <ReviewContext.Provider value={{app,live,look:'original',session:live?.session??initialSession()} as ReviewState}>{visible&&<Component/>}</ReviewContext.Provider>;
  }
  const view=render(<Provider/>);
  return {app,view,rerender(visible=true){view.rerender(<Provider visible={visible}/>);},async retireSetup(){
    current={...current,revision:current.revision+1,onboardingSetup:undefined};await act(async()=>publish(JSON.stringify(current)));
  },close(){view.unmount();act(()=>disconnect());Object.defineProperty(AppState,'currentState',{configurable:true,value:previous});}};
}
const layout=(node:ReturnType<typeof screen.getByTestId>,width:number,height:number)=>fireEvent(node,'layout',{nativeEvent:{layout:{x:0,y:0,width,height}}});
beforeEach(()=>{mockFocused=true;geometrySize={width:0,height:0};});

test.each([['licenses',License],['Components',ComponentsScreen]] as const)('%s preserves its direct native scroll root and holds initial admission until a nonzero viewport',async(_name,Component)=>{
  const runtime=harness(Component);
  try{
    await act(async()=>{});const scroll=screen.UNSAFE_getByType(ScrollView);
    expect(runtime.app.getPresentationHydration().required).toBe(true);
    layout(scroll,0,0);await act(async()=>{});
    expect(runtime.app.getPresentationHydration().required).toBe(true);
    layout(scroll,390,844);await act(async()=>{});
    expect(runtime.app.getPresentationHydration().required).toBe(false);
    expect(screen.UNSAFE_getByType(ScrollView)).toBe(scroll);
  }finally{runtime.close();}
});
test.each([['licenses',License],['Components',ComponentsScreen]] as const)('%s retires an unmeasured layout ticket when its route loses focus or unmounts',async(_name,Component)=>{
  const runtime=harness(Component);
  try{
    await act(async()=>{});expect(runtime.app.getPresentationHydration().required).toBe(true);
    mockFocused=false;runtime.rerender();await act(async()=>{});
    expect(runtime.app.getPresentationHydration().required).toBe(false);
  }finally{runtime.close();}
  mockFocused=true;const retired=harness(Component);
  try{
    await act(async()=>{});expect(retired.app.getPresentationHydration().required).toBe(true);
    retired.rerender(false);await act(async()=>{});
    expect(retired.app.getPresentationHydration().required).toBe(false);
  }finally{retired.close();}
});
test('the separate Onboarding modal requires its actual native viewport and current drawing size before initial reveal',async()=>{
  const runtime=harness(Onboarding,true);
  try{
    await act(async()=>{});expect(runtime.app.getPresentationHydration().required).toBe(true);
    const viewport=screen.getByTestId('onboarding.flow.viewport');
    layout(viewport,0,0);await act(async()=>{});
    expect(runtime.app.getPresentationHydration().required).toBe(true);
    layout(viewport,390,844);await act(async()=>{});
    expect(runtime.app.getPresentationHydration().required).toBe(true);
    geometrySize={width:390,height:844};runtime.rerender();await act(async()=>{});
    expect(runtime.app.getPresentationHydration().required).toBe(false);
    expect(screen.getByTestId('onboarding.flow.viewport')).toBe(viewport);
  }finally{runtime.close();}
});
test('missing or retired Onboarding visits cannot leave an unmeasured modal ticket behind',async()=>{
  const absent=harness(Onboarding);
  try{
    await act(async()=>{});expect(absent.app.getPresentationHydration().required).toBe(false);
    expect(screen.queryByTestId('onboarding.flow.viewport')).toBeNull();
  }finally{absent.close();}
  const runtime=harness(Onboarding,true);
  try{
    await act(async()=>{});expect(runtime.app.getPresentationHydration().required).toBe(true);
    await runtime.retireSetup();
    expect(screen.queryByTestId('onboarding.flow.viewport')).toBeNull();
    expect(runtime.app.getPresentationHydration().required).toBe(false);
  }finally{runtime.close();}
});
