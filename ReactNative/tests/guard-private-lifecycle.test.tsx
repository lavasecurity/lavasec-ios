import {useLayoutEffect,useSyncExternalStore} from 'react';
import {AppState,type AppStateStatus} from 'react-native';
import {act,fireEvent,render,screen} from '@testing-library/react-native';
import {AppStore} from '../app/store';
import type {AppSnapshot} from '../app/contract';
import type {Spec} from '../specs/NativeLavaApp';
import {GuardScreen} from '../review/screens';
import {LiveRenderBoundary,ReviewContext,type ReviewState} from '../review/ReviewContext';
import {GuardSummaries,ProtectionHero} from '../review/story-scaffold';
import {GuardianDrawing} from '../src/GuardianDrawing';
import {initialSession} from '../review/session';

jest.mock('@react-navigation/native',()=>({useNavigation:()=>({navigate:jest.fn(),setOptions:jest.fn()}),useIsFocused:()=>true,usePreventRemove:jest.fn(),useScrollToTop:jest.fn()}));
jest.mock('react-native-safe-area-context',()=>require('react-native-safe-area-context/jest/mock').default);
jest.mock('../specs/LavaDecorationNativeComponent',()=>({__esModule:true,default:require('react-native').View}));
jest.mock('../specs/LavaSliderNativeComponent',()=>({__esModule:true,default:require('react-native').View}));
jest.mock('../specs/LavaChoiceNativeComponent',()=>require('./native-choice-mock'));
jest.mock('../specs/LavaTextFieldNativeComponent',()=>({__esModule:true,default:require('react-native').View}));
jest.mock('../specs/NativeLavaReview',()=>({__esModule:true,default:{getGuardAccents:()=>JSON.stringify({original:{light:'#BF4000',dark:'#FF8855'}})}}));

test('retained onboarding Guard preview clears native values under its background cover and resumes the same scaffold',async()=>{
  const previous=AppState.currentState,originalListener=AppState.addEventListener;
  Object.defineProperty(AppState,'currentState',{configurable:true,value:'active'});
  const listeners=new Set<(state:AppStateStatus)=>void>();
  AppState.addEventListener=(_event,listener)=>{const callback=listener as (state:AppStateStatus)=>void;listeners.add(callback);return {remove:()=>{listeners.delete(callback);}};};
  const emitState=(state:AppStateStatus)=>act(()=>{Object.defineProperty(AppState,'currentState',{configurable:true,value:state});listeners.forEach(listener=>listener(state));});
  let current={schema:1,fullApp:true,revision:1,backgroundPrivacyCoverRequired:true,
    security:{ownerRevision:'guard-preview-owner',readRevision:1},look:'original',
    session:{...initialSession(),passcode:true,activeFilterID:'private-filter'},
    filters:[{id:'private-filter',name:'Native private filter',count:'12'}],
    protection:{title:'Native private status',subtitle:'Native private subtitle',action:'Native private action',mood:'awake',disabled:false,canPause:true,
      today:{countsEnabled:true,allowed:10,blocked:5}},
  } as unknown as AppSnapshot;
  let publish!:(value:string)=>void;
  const native={getSnapshot:()=>new Promise<string>(()=>{}),
    command:jest.fn(async()=>JSON.stringify({snapshot:current,result:null})),
    onSnapshot:(callback:(value:string)=>void)=>{publish=callback;return {remove(){}};},
  } as unknown as Spec;
  const app=new AppStore(native,current),disconnect=app.connect();
  function Provider(){
    const state=useSyncExternalStore(app.subscribe,app.getSnapshot);
    const gate=useSyncExternalStore(app.subscribe,app.getPresentationHydration);
    const live=state.snapshot??undefined;
    useLayoutEffect(()=>{if(live)app.completePresentationLayout(gate.epoch);},[live,gate.epoch]);
    return <ReviewContext.Provider value={{app,live,onboardingPreview:true,session:live?.session??initialSession(),look:live?.look??'original'} as ReviewState}>
      <LiveRenderBoundary component={GuardScreen} directScrollRoot/>
    </ReviewContext.Provider>;
  }
  const view=render(<Provider/>);
  try{
    fireEvent(screen.getByTestId('screen.scroll'),'layout',{nativeEvent:{layout:{x:0,y:0,width:390,height:844}}});
    await act(async()=>{});
    const body=screen.UNSAFE_getByType(GuardScreen),scroll=screen.getByTestId('screen.scroll');
    expect(screen.getByLabelText('Protection status')).toHaveProp('accessibilityValue',expect.objectContaining({text:expect.stringMatching(/^Protection off\./)}));
    expect(screen.getByText(/Native private filter/)).toBeTruthy();
    expect(screen.UNSAFE_getByType(GuardSummaries).props.today).toMatchObject({allowed:10,blocked:5});
    emitState('background');
    expect(app.getSnapshot().snapshot).toBeNull();
    expect(screen.UNSAFE_getByType(GuardianDrawing).props.active).toBe(false);
    expect(screen.UNSAFE_getByType(ProtectionHero).props.active).toBe(false);
    expect(screen.getByTestId('lava-route-privacy-cover')).toBeTruthy();
    expect(screen.getByTestId('screen.scroll',{includeHiddenElements:true})).toBe(scroll);
    expect(screen.UNSAFE_getByType(GuardScreen)).toBe(body);
    expect(scroll).toHaveProp('pointerEvents','none');
    expect(scroll).toHaveProp('accessibilityElementsHidden',true);
    expect(screen.queryByText(/Native private filter/,{includeHiddenElements:true})).toBeNull();
    expect(screen.UNSAFE_getByType(GuardSummaries).props.today).toEqual({value:'No requests yet',detail:undefined});
    emitState('active');
    current={...current,revision:2,security:{...current.security,readRevision:2},filters:[{...current.filters[0]!,name:'Current authorized filter'}]};
    await act(async()=>publish(JSON.stringify(current)));
    expect(screen.queryByTestId('lava-route-privacy-cover')).toBeNull();
    expect(screen.getByTestId('screen.scroll')).toBe(scroll);
    expect(screen.UNSAFE_getByType(GuardScreen)).toBe(body);
    expect(screen.getByLabelText('Protection status')).toHaveProp('accessibilityValue',expect.objectContaining({text:expect.stringMatching(/^Protection off\./)}));
    expect(screen.getByText(/Current authorized filter/)).toBeTruthy();
    expect(screen.UNSAFE_getByType(GuardianDrawing).props.active).toBe(true);
    expect(screen.UNSAFE_getByType(ProtectionHero).props.active).toBe(true);
    expect(screen.queryByText(/Native private filter/,{includeHiddenElements:true})).toBeNull();
  }finally{
    view.unmount();act(()=>disconnect());AppState.addEventListener=originalListener;Object.defineProperty(AppState,'currentState',{configurable:true,value:previous});
  }
});
