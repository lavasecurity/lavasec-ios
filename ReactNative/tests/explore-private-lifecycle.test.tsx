import {AppState,ScrollView,View,type AppStateStatus} from 'react-native';
import {act,cleanup,fireEvent,render,screen} from '@testing-library/react-native';
import {LavaUIReview} from '../review/LavaUIReview';
import {ExploreScreen} from '../review/ExploreScreen';
import {LiveRenderBoundary} from '../review/ReviewContext';
import {DemoTransport,StoryLink} from '../review/story-scaffold';
import {initialSession} from '../review/session';
import {colors} from '../src/colors.ios';
import type {AppCommand,AppSnapshot} from '../app/contract';

const mockGetSnapshot=jest.fn<Promise<string>,[]>();
const mockCommand=jest.fn<Promise<string>,[string]>();
const mockOnSnapshot=jest.fn();
const mockNavigate=jest.fn(),mockGoBack=jest.fn(),mockDispatch=jest.fn();
const mockStopDemo=jest.fn(),mockSpeakDemo=jest.fn().mockResolvedValue(false);
let mockFocused=true;
const mockNavigation={navigate:mockNavigate,goBack:mockGoBack,dispatch:mockDispatch,setOptions:jest.fn(),
  getState:()=>({index:1,routes:[{name:'Settings',key:'settings'},{name:'Explore',key:'explore'}]}),
  getParent:()=>undefined,addListener:()=>()=>{}};

jest.mock('../specs/NativeLavaApp',()=>({__esModule:true,default:{
  getSnapshot:()=>mockGetSnapshot(),command:(value:string)=>mockCommand(value),
  onSnapshot:(listener:(value:string)=>void)=>mockOnSnapshot(listener),
}}));
jest.mock('../specs/NativeLavaAppearance',()=>({__esModule:true,default:{
  getSnapshot:async()=>({preference:'light',revision:1}),onSnapshot:()=>({remove(){}}),
}}));
jest.mock('../specs/NativeLavaReview',()=>({__esModule:true,default:{
  stopDemo:()=>mockStopDemo(),speakDemo:(...args:unknown[])=>mockSpeakDemo(...args),
  getGuardAccents:()=>JSON.stringify({}),
}}));
jest.mock('../specs/LavaDecorationNativeComponent',()=>({__esModule:true,default:require('react-native').View}));
jest.mock('../specs/LavaSliderNativeComponent',()=>({__esModule:true,default:require('react-native').View}));
jest.mock('react-native-safe-area-context',()=>require('react-native-safe-area-context/jest/mock').default);
jest.mock('@react-navigation/native',()=>({
  DarkTheme:{colors:{}},DefaultTheme:{colors:{}},
  useNavigation:()=>mockNavigation,useRoute:()=>({key:'explore',params:undefined}),
  useIsFocused:()=>mockFocused,usePreventRemove:jest.fn(),useScrollToTop:jest.fn(),
  NavigationIndependentTree:({children}:{children:import('react').ReactNode})=>children,
  NavigationContainer:require('react').forwardRef(({children,onReady,initialState}:{children:import('react').ReactNode;onReady?:()=>void;initialState?:unknown},_ref:unknown)=>{
    const React=require('react');
    React.useEffect(()=>{
      if(initialState)return;
      let mounted=true;onReady?.();
      void Promise.resolve().then(()=>{if(!mounted)return;
        const rendered=require('@testing-library/react-native').screen;
        const layout={nativeEvent:{layout:{x:0,y:0,width:390,height:844}}};
        rendered.queryByTestId('lava-render-frame',{includeHiddenElements:true})?.props.onLayout(layout);
        rendered.queryByTestId('screen.scroll',{includeHiddenElements:true})?.props.onLayout(layout);
      });return()=>{mounted=false;};
    },[]);
    return children;
  }),
  createNavigationContainerRef:()=>({isReady:()=>true,getRootState:()=>undefined,dispatch:jest.fn()}),
}));

// Only UIKit's owning shell is unavailable in Jest. Select the actual registered
// Explore route so removing its retainBody admission makes these tests fail.
function mockNativeNavigator(){
  const React=require('react');
  return {
    Navigator:({children,initialRouteName}:{children:import('react').ReactNode;initialRouteName?:string})=>{
      const routes=React.Children.toArray(children) as import('react').ReactElement<{name:string}>[];
      return routes.find(route=>route.props.name==='Explore')
        ??routes.find(route=>route.props.name===initialRouteName)??routes[0]??null;
    },
    Screen:({component:Component,children}:{component?:import('react').ComponentType;children?:()=>import('react').ReactNode})=>
      Component?React.createElement(Component):children?.(),
  };
}
jest.mock('@react-navigation/native-stack',()=>({createNativeStackNavigator:()=>mockNativeNavigator()}));
jest.mock('@react-navigation/bottom-tabs/unstable',()=>({createNativeBottomTabNavigator:()=>mockNativeNavigator()}));
jest.mock('../review/navigation-scaffold',()=>({...jest.requireActual('../review/navigation-scaffold'),useOrdinaryPushPresentation:()=>({})}));
jest.mock('../review/screens',()=>new Proxy({ExploreScreen:jest.requireActual('../review/ExploreScreen').ExploreScreen},
  {get:(target:Record<string,unknown>,key:string)=>key in target?target[key]:()=>null}));

const originalState=AppState.currentState;
let restoreLifecycle:()=>void,emitState:(state:AppStateStatus)=>void,publish:(value:AppSnapshot)=>void;
let current:AppSnapshot;
const snapshot=(revision:number,owner='owner-1'):AppSnapshot=>({
  schema:1,fullApp:true,revision,backgroundPrivacyCoverRequired:true,
  presentation:{locale:'en',textScales:null},look:'original',qaTools:false,
  session:{...initialSession(),passcode:true,activeFilterID:'balanced',
    protectedActions:{...initialSession().protectedActions,'Update App Settings':true}},
  security:{ownerRevision:owner,readRevision:revision,unavailable:false},
  filters:[{id:'balanced',name:'Private filter',count:'12'}],
  connection:{vpn:{eligible:true,enabled:false,fallbackEnabled:false},
    dns:{primary:{name:'Private resolver',detail:'Private endpoint',transport:'DoH'},usesWireGuard:false}},
  dns:{providers:[]},discoveries:{},draft:{blocked:[],allowed:[]},savedDraft:{blocked:[],allowed:[]},
} as unknown as AppSnapshot);
const sent=()=>mockCommand.mock.calls.map(([value])=>JSON.parse(value) as AppCommand);
function expectDirectScrollRoot(scroll:ReturnType<typeof screen.UNSAFE_getByType>){
  const boundary=screen.UNSAFE_getByType(LiveRenderBoundary);
  let ancestor=scroll.parent;
  while(ancestor&&ancestor!==boundary){
    // A wrapping native View breaks UIKit's direct-scroll large-title owner,
    // even when its opacity/pointer/AX privacy behavior is otherwise correct.
    expect(ancestor.type).not.toBe(View);
    expect(ancestor.type).not.toBe('View');
    ancestor=ancestor.parent;
  }
  expect(ancestor).toBe(boundary);
  expect(boundary.props).toMatchObject({retainBody:true,directScrollRoot:true});
}

beforeEach(()=>{
  jest.spyOn(globalThis,'requestAnimationFrame').mockImplementation((callback:(timestamp:number)=>void)=>{callback(0);return 0;});
  Object.defineProperty(AppState,'currentState',{configurable:true,value:'active'});
  const originalListener=AppState.addEventListener;
  const listeners=new Set<(state:AppStateStatus)=>void>();
  AppState.addEventListener=(_event,listener)=>{
    const callback=listener as (state:AppStateStatus)=>void;listeners.add(callback);
    return {remove(){listeners.delete(callback);}};
  };
  emitState=state=>act(()=>{Object.defineProperty(AppState,'currentState',{configurable:true,value:state});for(const listener of listeners)listener(state);});
  restoreLifecycle=()=>{AppState.addEventListener=originalListener;Object.defineProperty(AppState,'currentState',{configurable:true,value:originalState});};
  current=snapshot(1);mockFocused=true;
  mockGetSnapshot.mockReset().mockImplementation(()=>new Promise(()=>{}));
  mockCommand.mockReset().mockImplementation(async()=>JSON.stringify({snapshot:current,result:null}));
  mockOnSnapshot.mockReset().mockImplementation(listener=>{publish=value=>{current=value;act(()=>listener(JSON.stringify(value)));};return{remove(){}};});
  mockNavigate.mockClear();mockGoBack.mockClear();mockDispatch.mockClear();mockStopDemo.mockClear();mockSpeakDemo.mockClear();
});
afterEach(()=>{cleanup();restoreLifecycle();jest.restoreAllMocks();});

test('registered Explore keeps DNS inspection and its direct native scroll owner through protected revocation while private fields and input revoke',async()=>{
  render(<LavaUIReview fullApp initialSnapshot={JSON.stringify(current)}/>);
  await act(async()=>{});
  fireEvent.press(screen.getByTestId('connection.dns'));
  await act(async()=>{});
  expect(screen.getByTestId('explore.configure')).toHaveProp('accessibilityLabel','Open DNS settings');
  expect(screen.getByTestId('explore.part.summary')).toHaveTextContent(/Private resolver/);
  const body=screen.UNSAFE_getByType(ExploreScreen),scroll=screen.UNSAFE_getByType(ScrollView);
  expectDirectScrollRoot(scroll);
  const configure=screen.UNSAFE_getAllByType(StoryLink).find(link=>link.props.testID==='explore.configure')!.props.onPress;
  mockCommand.mockClear();mockNavigate.mockClear();

  emitState('inactive');emitState('background');
  expect(screen.UNSAFE_getByType(ExploreScreen)).toBe(body);
  expect(screen.UNSAFE_getByType(ScrollView)).toBe(scroll);
  expectDirectScrollRoot(scroll);
  expect(screen.queryByTestId('explore.configure')).toBeNull();
  expect(screen.queryByText(/Private resolver/,{includeHiddenElements:true})).toBeNull();
  expect(screen.getByTestId('screen.scroll',{includeHiddenElements:true})).toHaveStyle({opacity:0});
  expect(screen.getByTestId('lava-route-privacy-cover',{includeHiddenElements:true})).toHaveStyle({backgroundColor:colors.groupedBackground});
  expect(scroll.props).toMatchObject({pointerEvents:'none',accessibilityElementsHidden:true,importantForAccessibility:'no-hide-descendants'});
  await act(async()=>configure());
  expect(mockCommand).not.toHaveBeenCalled();expect(mockNavigate).not.toHaveBeenCalled();

  emitState('active');
  await act(async()=>configure());
  expect(mockCommand).not.toHaveBeenCalled();expect(mockNavigate).not.toHaveBeenCalled();
  await act(async()=>publish(snapshot(2)));
  expect(screen.UNSAFE_getByType(ExploreScreen)).toBe(body);
  expect(screen.UNSAFE_getByType(ScrollView)).toBe(scroll);
  expectDirectScrollRoot(scroll);
  expect(screen.getByTestId('screen.scroll',{includeHiddenElements:true})).not.toHaveStyle({opacity:0});
  expect(scroll.props).toMatchObject({pointerEvents:'auto',accessibilityElementsHidden:false,importantForAccessibility:'auto'});
  expect(screen.queryByTestId('lava-route-privacy-cover')).toBeNull();
  expect(screen.getByTestId('connection.dns')).toHaveProp('accessibilityState',{selected:true});
  expect(screen.getByTestId('explore.part.summary')).toHaveTextContent(/Private resolver/);
  expect(screen.getByTestId('explore.configure')).toHaveProp('accessibilityLabel','Open DNS settings');

  mockCommand.mockRejectedValueOnce(new Error('Authentication cancelled.'));
  await act(async()=>fireEvent.press(screen.getByTestId('explore.configure')));
  expect(sent()).toEqual([{type:'navigation.authorize',surface:'appSettings'}]);
  expect(mockNavigate).not.toHaveBeenCalled();
  await act(async()=>fireEvent.press(screen.getByTestId('explore.configure')));
  expect(sent()).toEqual([{type:'navigation.authorize',surface:'appSettings'},{type:'navigation.authorize',surface:'appSettings'}]);
  expect(mockNavigate).toHaveBeenCalledWith('DNS');
});

test.each(['owner','policy'] as const)('Explore retires inspection and scroll state after actual %s replacement',async change=>{
  render(<LavaUIReview fullApp initialSnapshot={JSON.stringify(current)}/>);await act(async()=>{});
  fireEvent.press(screen.getByTestId('connection.dns'));await act(async()=>{});
  const body=screen.UNSAFE_getByType(ExploreScreen),scroll=screen.UNSAFE_getByType(ScrollView);
  expectDirectScrollRoot(scroll);
  const oldConfigure=screen.UNSAFE_getAllByType(StoryLink).find(link=>link.props.testID==='explore.configure')!.props.onPress;
  const replacement=change==='owner'?snapshot(2,'owner-2'):{...snapshot(2),session:{...current.session,protectedActions:{...current.session.protectedActions,'View Activities':true}}};
  await act(async()=>publish(replacement));
  expect(screen.UNSAFE_getByType(ExploreScreen)).not.toBe(body);
  expect(screen.UNSAFE_getByType(ScrollView)).not.toBe(scroll);
  expectDirectScrollRoot(screen.UNSAFE_getByType(ScrollView));
  expect(screen.queryByTestId('explore.configure')).toBeNull();
  expect(screen.getByText('Welcome')).toBeOnTheScreen();
  mockCommand.mockClear();mockNavigate.mockClear();
  await act(async()=>oldConfigure());
  expect(mockCommand).not.toHaveBeenCalled();expect(mockNavigate).not.toHaveBeenCalled();
});

test('an actual Explore removal retires inspection rather than reviving it on a new visit',async()=>{
  const view=render(<LavaUIReview fullApp initialSnapshot={JSON.stringify(current)}/>);await act(async()=>{});
  fireEvent.press(screen.getByTestId('connection.dns'));await act(async()=>{});
  expect(screen.getByTestId('explore.configure')).toBeOnTheScreen();
  const oldConfigure=screen.UNSAFE_getAllByType(StoryLink).find(link=>link.props.testID==='explore.configure')!.props.onPress;
  view.unmount();
  render(<LavaUIReview fullApp initialSnapshot={JSON.stringify(current)}/>);await act(async()=>{});
  expect(screen.queryByTestId('explore.configure')).toBeNull();expect(screen.getByText('Welcome')).toBeOnTheScreen();
  mockCommand.mockClear();mockNavigate.mockClear();
  await act(async()=>oldConfigure());
  expect(mockCommand).not.toHaveBeenCalled();expect(mockNavigate).not.toHaveBeenCalled();
});

test('an authorization begun before background cannot push DNS into a freshly restored retained Explore visit',async()=>{
  render(<LavaUIReview fullApp initialSnapshot={JSON.stringify(current)}/>);await act(async()=>{});
  fireEvent.press(screen.getByTestId('connection.dns'));await act(async()=>{});
  let complete!:(value:string)=>void;
  mockCommand.mockImplementationOnce(()=>new Promise(resolve=>{complete=resolve;}));
  await act(async()=>fireEvent.press(screen.getByTestId('explore.configure')));
  const old=current;
  emitState('inactive');emitState('background');emitState('active');
  await act(async()=>publish(snapshot(2)));
  await act(async()=>complete(JSON.stringify({snapshot:old,result:null})));
  expect(mockNavigate).not.toHaveBeenCalled();
  expect(screen.getByTestId('connection.dns')).toHaveProp('accessibilityState',{selected:true});
  await act(async()=>fireEvent.press(screen.getByTestId('explore.configure')));
  expect(mockNavigate).toHaveBeenCalledWith('DNS');
});

test('protected inactivity stops Explore playback and speech and cannot restart them while revoked',async()=>{
  render(<LavaUIReview fullApp initialSnapshot={JSON.stringify(current)}/>);await act(async()=>{});
  fireEvent.press(screen.getByTestId('explore.play'));await act(async()=>{});
  const body=screen.UNSAFE_getByType(ExploreScreen),play=screen.UNSAFE_getByType(DemoTransport).props.onPlay;
  expect(screen.UNSAFE_getByType(DemoTransport).props.playing).toBe(true);
  mockCommand.mockClear();mockSpeakDemo.mockClear();mockStopDemo.mockClear();
  emitState('inactive');emitState('background');
  expect(screen.UNSAFE_getByType(ExploreScreen)).toBe(body);
  expect(mockStopDemo).toHaveBeenCalled();
  await act(async()=>play());
  expect(mockSpeakDemo).not.toHaveBeenCalled();expect(mockCommand).not.toHaveBeenCalled();
  expect(screen.queryByTestId('explore.transport')).toBeNull();
  emitState('active');await act(async()=>publish(snapshot(2)));
  expect(screen.queryByTestId('explore.transport')).toBeNull();
  expect(screen.getByTestId('explore.play')).toBeOnTheScreen();
});
