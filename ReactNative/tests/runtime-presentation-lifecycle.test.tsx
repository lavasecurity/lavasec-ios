import {ActivityIndicator, AppState, type AppStateStatus} from 'react-native';
import {act, cleanup, fireEvent, render, screen} from '@testing-library/react-native';
import {LavaUIReview} from '../review/LavaUIReview';
import {initialSession} from '../review/session';

const mockGetSnapshot=jest.fn<Promise<string>,[]>();
const mockCommand=jest.fn<Promise<string>,[string]>();
const mockOnSnapshot=jest.fn();
const mockNavigationMount=jest.fn();
const mockNavigationUnmount=jest.fn();
const mockBodyMount=jest.fn();
const mockBodyUnmount=jest.fn();
const mockPreventRemove=jest.fn();
let mockHydrationQueryCount=0;
let mockHydrationQueryScope=0;
let mockFocused=true;

jest.mock('../specs/NativeLavaApp',()=>({__esModule:true,default:{
  getSnapshot:()=>mockGetSnapshot(),
  command:(request:string)=>mockCommand(request),
  onSnapshot:(callback:(value:string)=>void)=>mockOnSnapshot(callback),
}}));
jest.mock('../specs/NativeLavaAppearance',()=>({__esModule:true,default:{
  getSnapshot:async()=>({preference:'light',revision:1}),
  onSnapshot:()=>({remove:jest.fn()}),
}}));
jest.mock('../specs/LavaDecorationNativeComponent',()=>({__esModule:true,default:require('react-native').View}));
jest.mock('../specs/NativeLavaReview',()=>({__esModule:true,default:{close:jest.fn()}}));
jest.mock('react-native-safe-area-context',()=>({SafeAreaProvider:require('react-native').View}));
jest.mock('@react-navigation/native',()=>{
  const React=require('react');const {View}=require('react-native');
  return {
    DarkTheme:{colors:{}},DefaultTheme:{colors:{}},
    useIsFocused:()=>mockFocused,
    usePreventRemove:(prevent:boolean)=>mockPreventRemove(prevent),
    createNavigationContainerRef:()=>({current:null,isReady:()=>true,getRootState:()=>undefined,dispatch:jest.fn()}),
    NavigationContainer:React.forwardRef(({children}:{children:import('react').ReactNode},_ref:unknown)=>{
      React.useEffect(()=>{mockNavigationMount();return ()=>mockNavigationUnmount();},[]);
      return React.createElement(View,{testID:'native-navigation-container'},children);
    }),
  };
});

// UIKit is unavailable in Jest. These adapters keep the owning navigator and
// native route mounted while the real LiveRenderBoundary controls its body.
function mockNativeNavigator() {
  const React=require('react');const {View}=require('react-native');
  return {
    Navigator:({children,initialRouteName,screenOptions}:{children:import('react').ReactNode;initialRouteName?:string;screenOptions?:unknown})=>{
      const routes=React.Children.toArray(children) as import('react').ReactElement<{name:string}>[];
      const child=routes.find(route=>route.props.name===initialRouteName)??routes[0]??null;
      return typeof screenOptions==='function'?React.createElement(View,{testID:'native-tab-shell',
        nativeSelectionEnabled:screenOptions({route:{name:'GuardTab'}}).tabBarSelectionEnabled},child):child;
    },
    Screen:({component:Component,name,options}:{component:import('react').ComponentType;name:string;options?:{title?:string}})=>
      React.createElement(View,{testID:`native-route.${name}`,nativeTitle:options?.title},React.createElement(Component)),
  };
}
jest.mock('@react-navigation/native-stack',()=>({createNativeStackNavigator:()=>mockNativeNavigator()}));
jest.mock('@react-navigation/bottom-tabs/unstable',()=>({createNativeBottomTabNavigator:()=>mockNativeNavigator()}));
jest.mock('../review/navigation-scaffold',()=>({useOrdinaryPushPresentation:()=>({})}));
jest.mock('../review/scaffold',()=>({fullScreenModalPresentation:{},fullSheetPresentation:{},toolbarButton:jest.fn()}));
jest.mock('../review/primitives',()=>{
  const React=require('react');const {Text,View}=require('react-native');
  return {
    Copy:({children}:{children:import('react').ReactNode})=>React.createElement(Text,null,children),
    Symbol:({name}:{name:string})=>React.createElement(View,{testID:'runtime-cover-symbol',accessibilityLabel:name}),
  };
});
jest.mock('../review/screens',()=>{
  const React=require('react');const {Pressable,Text,View}=require('react-native');
  function PrivateBody() {
    const {app,live}=require('../review/ReviewContext').useReview();
    const {useAppQuery}=require('../app/queries');
    const first=useAppQuery(mockHydrationQueryCount?mockHydrationQueryScope
      ?{type:'activity.query',start:mockHydrationQueryScope,end:mockHydrationQueryScope+1}:{type:'stats.query'}:null);
    const second=useAppQuery(mockHydrationQueryCount>1?{type:'network.query'}:null);
    const [draft,setDraft]=React.useState('New private draft');
    React.useEffect(()=>{mockBodyMount();return ()=>mockBodyUnmount();},[]);
    return React.createElement(View,{testID:'private-route-body'},
      React.createElement(Text,null,`Native private value ${live.revision}`),
      React.createElement(Text,null,draft),
      mockHydrationQueryCount>0&&React.createElement(Text,null,first.error??`Painted first query ${first.value?.join(',')??'Pending'}`),
      mockHydrationQueryCount>1&&React.createElement(Text,null,second.error??`Painted second query ${second.value?.join(',')??'Pending'}`),
      React.createElement(Pressable,{accessibilityRole:'button',accessibilityLabel:'Keep a private draft',onPress:()=>setDraft('Previous private draft')}),
      React.createElement(Pressable,{accessibilityRole:'button',accessibilityLabel:'Refresh private runtime',onPress:()=>void app.refresh()}));
  }
  function RuntimeError({message,retry}:{message:string;retry:()=>void}) {
    return React.createElement(View,null,React.createElement(Text,null,message),
      React.createElement(Pressable,{accessibilityRole:'button',accessibilityLabel:'Retry runtime',onPress:retry}));
  }
  return new Proxy({GuardScreen:PrivateBody,SettingsScreen:PrivateBody,RuntimeError}, {
    get:(target:Record<string,unknown>,key:string)=>key in target?target[key]:()=>null,
  });
});

const deferred=<T,>()=>{
  let resolve!:(value:T)=>void, reject!:(error:Error)=>void;
  const promise=new Promise<T>((yes,no)=>{resolve=yes;reject=no;});
  return {promise,resolve,reject};
};
const snapshot=(revision:number,backgroundPrivacyCoverRequired?:boolean)=>JSON.stringify({schema:1,fullApp:true,revision,backgroundPrivacyCoverRequired,presentation:{locale:'en',textScales:null},
  session:{...initialSession(),filterID:'balanced',activeFilterID:'balanced'},look:'original',draft:{blocked:[],allowed:[]},savedDraft:{blocked:[],allowed:[]},qaTools:false});
const originalState=AppState.currentState;
let restoreLifecycle:()=>void;
let emitState:(state:AppStateStatus)=>void;
let emitSnapshot:(value:string)=>void;
let reads:ReturnType<typeof deferred<string>>[];

beforeEach(()=>{
  Object.defineProperty(AppState,'currentState',{configurable:true,value:'active'});
  const listeners=new Set<(state:AppStateStatus)=>void>();
  const previousListener=AppState.addEventListener;
  AppState.addEventListener=(_event,listener)=>{
    const callback=listener as (state:AppStateStatus)=>void;
    listeners.add(callback);return {remove:()=>{listeners.delete(callback);}};
  };
  emitState=state=>act(()=>{Object.defineProperty(AppState,'currentState',{configurable:true,value:state});for(const listener of listeners)listener(state);});
  restoreLifecycle=()=>{AppState.addEventListener=previousListener;Object.defineProperty(AppState,'currentState',{configurable:true,value:originalState});};
  reads=[];
  mockHydrationQueryCount=0;mockHydrationQueryScope=0;mockFocused=true;
  mockGetSnapshot.mockReset().mockImplementation(()=>{const read=deferred<string>();reads.push(read);return read.promise;});
  mockCommand.mockReset().mockResolvedValue(JSON.stringify({snapshot:JSON.parse(snapshot(1)),result:null}));
  mockOnSnapshot.mockReset().mockImplementation(callback=>{emitSnapshot=value=>act(()=>callback(value));return {remove:jest.fn()};});
  mockNavigationMount.mockClear();mockNavigationUnmount.mockClear();mockBodyMount.mockClear();mockBodyUnmount.mockClear();
  mockPreventRemove.mockClear();
});
afterEach(()=>{cleanup();restoreLifecycle();});

test.each([
  ['en','Guard'],['ja','ガード'],['zh-Hant','防護'],['zh-Hans','防护'],
  ['de','Schutz'],['fr','Protection'],['es','Protección'],['ko','보호'],
  ['pt-BR','Proteção'],['it','Protezione'],
])('Guard header and native tab share the translated title in %s', (locale,title)=>{
  const initial=JSON.parse(snapshot(1));initial.presentation.locale=locale;
  render(<LavaUIReview fullApp initialSnapshot={JSON.stringify(initial)}/>);
  expect(screen.getByTestId('native-route.Guard').props.nativeTitle).toBe(title);
  expect(screen.getByTestId('native-route.GuardTab').props.nativeTitle).toBe(title);
});

function expectConcealed() {
  expect(screen.getByTestId('lava-privacy-cover')).toBeTruthy();
  expect(screen.getByTestId('lava-privacy-cover.symbol',{includeHiddenElements:true}).props.symbol).toBe('lock.shield.fill');
  expect(screen.getByText('Lava Security')).toBeTruthy();
  expect(screen.queryByLabelText('Loading Lava')).toBeNull();
  expect(screen.queryByTestId('private-route-body',{includeHiddenElements:true})).toBeNull();
  expect(screen.queryByText('Previous private draft',{includeHiddenElements:true})).toBeNull();
}

test('repeated warm resumes conceal without loading, discard private bodies and ignore pre-background reads',async()=>{
  render(<LavaUIReview fullApp initialSnapshot={snapshot(1)}/>);
  const navigator=screen.getByTestId('native-navigation-container');
  expect(mockGetSnapshot).toHaveBeenCalledTimes(1);
  expect(screen.getByText('Native private value 1')).toBeTruthy();
  for(let cycle=1;cycle<=2;cycle++) {
    fireEvent.press(screen.getByLabelText('Keep a private draft'));
    expect(screen.getByText('Previous private draft')).toBeTruthy();
    // The first cold synchronization is still pending; the second interruption
    // overtakes an explicit foreground refresh from the authorized body.
    if(cycle===2)fireEvent.press(screen.getByLabelText('Refresh private runtime'));
    const interrupted=reads.at(-1)!;
    const count=mockGetSnapshot.mock.calls.length;
    emitState('inactive');expectConcealed();
    emitState('background');expectConcealed();
    emitSnapshot(snapshot(cycle*20-2));expectConcealed();
    expect(mockGetSnapshot).toHaveBeenCalledTimes(count);
    emitState('active');expectConcealed();
    expect(mockGetSnapshot).toHaveBeenCalledTimes(count+1);
    const authorized=reads.at(-1)!;
    await act(async()=>interrupted.resolve(snapshot(cycle*20-1)));
    expectConcealed();
    expect(screen.getByTestId('native-navigation-container',{includeHiddenElements:true})).toBe(navigator);
    expect(mockNavigationMount).toHaveBeenCalledTimes(1);
    expect(mockNavigationUnmount).not.toHaveBeenCalled();
    expect(mockBodyUnmount).toHaveBeenCalledTimes(cycle);
    await act(async()=>authorized.resolve(snapshot(cycle*20)));
    expect(screen.queryByTestId('lava-privacy-cover')).toBeNull();
    expect(screen.queryByLabelText('Loading Lava')).toBeNull();
    expect(screen.getByText(`Native private value ${cycle*20}`)).toBeTruthy();
    expect(screen.getByText('New private draft')).toBeTruthy();
    expect(screen.getByTestId('native-navigation-container')).toBe(navigator);
    expect(mockBodyMount).toHaveBeenCalledTimes(cycle+1);
  }
});

test('a native locked projection uses the same privacy cover and retains a retryable runtime error',async()=>{
  render(<LavaUIReview fullApp initialSnapshot={snapshot(1)}/>);
  const navigator=screen.getByTestId('native-navigation-container');
  fireEvent.press(screen.getByLabelText('Keep a private draft'));
  emitSnapshot(JSON.stringify({schema:1,fullApp:true,revision:2,presentationBlocked:true}));
  expectConcealed();
  await act(async()=>reads[0]!.resolve(snapshot(1)));
  expectConcealed();
  emitSnapshot(snapshot(3));
  await act(async()=>{});
  expect(screen.getByText('Native private value 3')).toBeTruthy();
  expect(screen.getByText('New private draft')).toBeTruthy();
  emitState('inactive');emitState('background');emitState('active');
  await act(async()=>reads.at(-1)!.reject(new Error('Temporary runtime read failure.')));
  expectConcealed();
  expect(screen.getByText('Temporary runtime read failure.')).toBeTruthy();
  fireEvent.press(screen.getByLabelText('Retry runtime'));
  await act(async()=>reads.at(-1)!.resolve(snapshot(4)));
  expect(screen.getByText('Native private value 4')).toBeTruthy();
  expect(screen.queryByText('Temporary runtime read failure.')).toBeNull();
  expect(screen.getByTestId('native-navigation-container')).toBe(navigator);
  expect(mockNavigationMount).toHaveBeenCalledTimes(1);
});

test('an unknown-policy cold launch conceals without a spinner and can retry a failed first read',async()=>{
  render(<LavaUIReview fullApp/>);
  expectStarting();
  expect(screen.queryByTestId('native-navigation-container')).toBeNull();
  await act(async()=>reads[0]!.reject(new Error('Runtime is temporarily unavailable.')));
  expectStarting();
  expect(screen.getByText('Runtime is temporarily unavailable.')).toBeTruthy();
  fireEvent.press(screen.getByLabelText('Retry runtime'));
  await act(async()=>reads.at(-1)!.resolve(snapshot(1)));
  expect(screen.queryByLabelText('Loading Lava')).toBeNull();
  expect(screen.getByText('Native private value 1')).toBeTruthy();
  expect(mockNavigationMount).toHaveBeenCalledTimes(1);
});

test('confirmed all-off preserves the displayed body through inactivity and a delayed active refresh without a lock flash',async()=>{
  render(<LavaUIReview fullApp initialSnapshot={snapshot(1,false)}/>);
  await act(async()=>{});
  const navigator=screen.getByTestId('native-navigation-container');
  fireEvent.press(screen.getByLabelText('Keep a private draft'));
  const originalRead=reads[0]!;
  emitState('inactive');
  expect(screen.queryByTestId('lava-privacy-cover')).toBeNull();
  const frame=screen.getByTestId('lava-render-frame',{includeHiddenElements:true});
  expect(frame.props.pointerEvents).toBe('none');expect(frame.props.accessibilityElementsHidden).toBe(true);
  expect(screen.getByText('Native private value 1',{includeHiddenElements:true})).toBeTruthy();
  expect(screen.getByText('Previous private draft',{includeHiddenElements:true})).toBeTruthy();
  emitState('background');emitSnapshot(snapshot(8,false));
  expect(screen.queryByText('Native private value 8',{includeHiddenElements:true})).toBeNull();
  expect(mockBodyUnmount).not.toHaveBeenCalled();
  expect(mockGetSnapshot).toHaveBeenCalledTimes(1);
  emitState('active');
  expect(screen.queryByTestId('lava-privacy-cover')).toBeNull();
  expect(screen.getByText('Native private value 1',{includeHiddenElements:true})).toBeTruthy();
  expect(screen.getByTestId('lava-render-frame',{includeHiddenElements:true}).props.pointerEvents).toBe('none');
  expect(screen.getByTestId('lava-render-frame',{includeHiddenElements:true}).props.accessibilityElementsHidden).toBe(true);
  expect(screen.getByTestId('native-tab-shell',{includeHiddenElements:true}).props.nativeSelectionEnabled).toBe(false);
  expect(mockPreventRemove).toHaveBeenLastCalledWith(true);
  emitSnapshot(JSON.stringify({schema:1,fullApp:true,revision:9,presentationBlocked:true,backgroundPrivacyCoverRequired:false}));
  expect(screen.queryByTestId('lava-privacy-cover')).toBeNull();
  await act(async()=>originalRead.resolve(snapshot(9,false)));
  expect(screen.queryByText('Native private value 9',{includeHiddenElements:true})).toBeNull();
  expect(screen.getByText('Previous private draft',{includeHiddenElements:true})).toBeTruthy();
  await act(async()=>reads.at(-1)!.resolve(snapshot(10,false)));
  expect(screen.getByText('Native private value 10')).toBeTruthy();
  expect(screen.getByText('Previous private draft')).toBeTruthy();
  expect(screen.getByTestId('lava-render-frame').props.pointerEvents).toBe('auto');
  expect(screen.getByTestId('lava-render-frame').props.accessibilityElementsHidden).toBe(false);
  expect(screen.getByTestId('native-tab-shell').props.nativeSelectionEnabled).toBe(true);
  expect(mockPreventRemove).toHaveBeenLastCalledWith(false);
  expect(screen.getByTestId('native-navigation-container')).toBe(navigator);
  expect(mockNavigationMount).toHaveBeenCalledTimes(1);expect(mockNavigationUnmount).not.toHaveBeenCalled();
  expect(mockBodyUnmount).not.toHaveBeenCalled();
});

test.each([true,undefined])('an active privacy boundary conceals the retained all-off frame and a late inactive marker cannot revive it: %p',async policy=>{
  render(<LavaUIReview fullApp initialSnapshot={snapshot(1,false)}/>);
  await act(async()=>{});
  emitState('inactive');emitState('active');
  expect(screen.queryByTestId('lava-privacy-cover')).toBeNull();
  emitSnapshot(JSON.stringify({schema:1,fullApp:true,revision:2,presentationBlocked:true,backgroundPrivacyCoverRequired:policy}));
  expectConcealed();
  emitSnapshot(JSON.stringify({schema:1,fullApp:true,revision:3,presentationBlocked:true,backgroundPrivacyCoverRequired:false}));
  expect(screen.queryByTestId('lava-privacy-cover')).toBeNull();
  expect(screen.queryByTestId('private-route-body',{includeHiddenElements:true})).toBeNull();
  await act(async()=>reads.at(-1)!.resolve(snapshot(4,false)));
  expect(screen.queryByTestId('lava-privacy-cover')).toBeNull();
  expect(screen.queryByTestId('private-route-body',{includeHiddenElements:true})).toBeNull();
  emitSnapshot(snapshot(5,false));
  await act(async()=>{});
  expect(screen.getByText('Native private value 5')).toBeTruthy();
  expect(screen.queryByTestId('lava-privacy-cover')).toBeNull();
});

test('a native blocked off-policy retains the inactive frame until updated concealment metadata arrives',async()=>{
  render(<LavaUIReview fullApp initialSnapshot={snapshot(1,false)}/>);
  await act(async()=>{});
  emitState('inactive');
  emitSnapshot(JSON.stringify({schema:1,fullApp:true,revision:2,presentationBlocked:true,backgroundPrivacyCoverRequired:false}));
  expect(screen.queryByTestId('lava-privacy-cover')).toBeNull();
  expect(screen.getByText('Native private value 1',{includeHiddenElements:true})).toBeTruthy();
  emitSnapshot(JSON.stringify({schema:1,fullApp:true,revision:3,presentationBlocked:true,backgroundPrivacyCoverRequired:true}));
  expectConcealed();
  emitSnapshot(snapshot(4,false));
  expect(screen.queryByTestId('lava-privacy-cover')).toBeNull();
  expect(screen.queryByTestId('private-route-body',{includeHiddenElements:true})).toBeNull();
});

test('disabling then enabling the last protected surface controls the next rendered inactive state',async()=>{
  render(<LavaUIReview fullApp initialSnapshot={snapshot(1,true)}/>);
  await act(async()=>{});
  emitSnapshot(snapshot(2,false));emitState('inactive');
  expect(screen.queryByTestId('lava-privacy-cover')).toBeNull();
  expect(screen.getByText('Native private value 2',{includeHiddenElements:true})).toBeTruthy();
  emitState('active');emitSnapshot(snapshot(3,false));emitSnapshot(snapshot(4,true));emitState('inactive');
  expectConcealed();
});

function expectStarting() {
  expect(screen.queryByLabelText('Loading Lava')).toBeNull();
  expect(screen.queryByTestId('lava-startup')).toBeNull();
  expect(screen.queryByTestId('lava-startup.symbol',{includeHiddenElements:true})).toBeNull();
  expect(screen.getByText('Lava Security')).toBeTruthy();
  expect(screen.UNSAFE_queryAllByType(ActivityIndicator)).toHaveLength(0);
  expect(screen.getByTestId('lava-privacy-cover')).toBeTruthy();
  expect(screen.queryByTestId('private-route-body',{includeHiddenElements:true})).toBeNull();
}

test.each<{name:string;state:AppStateStatus|null;initialSnapshot?:string}>([
  {name:'active',state:'active'},
  {name:'inactive',state:'inactive'},
  {name:'unknown',state:'unknown'},
  {name:'uninitialized',state:null},
  {name:'inactive with a protected marker',state:'inactive',initialSnapshot:JSON.stringify({schema:1,fullApp:true,revision:1,presentationBlocked:true,backgroundPrivacyCoverRequired:true})},
  {name:'inactive with unknown policy',state:'inactive',initialSnapshot:JSON.stringify({schema:1,fullApp:true,revision:1,presentationBlocked:true})},
])('a $name cold launch conceals protected or unknown policy until an active snapshot arrives',async({state,initialSnapshot})=>{
  Object.defineProperty(AppState,'currentState',{configurable:true,value:state});
  render(<LavaUIReview fullApp initialSnapshot={initialSnapshot}/>);
  expectStarting();
  expect(mockNavigationMount).not.toHaveBeenCalled();
  expect(mockBodyMount).not.toHaveBeenCalled();
  expect(mockCommand).not.toHaveBeenCalled();
  emitState('active');
  expectStarting();
  expect(mockCommand).not.toHaveBeenCalled();
  await act(async()=>reads.at(-1)!.resolve(snapshot(2,false)));
  expect(screen.queryByLabelText('Loading Lava')).toBeNull();
  expect(screen.queryByTestId('lava-privacy-cover')).toBeNull();
  expect(screen.getByText('Native private value 2')).toBeTruthy();
  expect(mockNavigationMount).toHaveBeenCalledTimes(1);
});

test.each<AppStateStatus|null>(['active','inactive','background','unknown',null])('an all-off bootstrap paints normal RN immediately before JS AppState catches up: %p',async state=>{
  Object.defineProperty(AppState,'currentState',{configurable:true,value:state});
  render(<LavaUIReview fullApp initialSnapshot={snapshot(1,false)}/>);
  const navigator=screen.getByTestId('native-navigation-container',{includeHiddenElements:true});
  expect(screen.getByText('Native private value 1',{includeHiddenElements:true})).toBeTruthy();
  expect(screen.queryByTestId('lava-privacy-cover')).toBeNull();
  expect(screen.queryByTestId('lava-startup')).toBeNull();
  expect(screen.queryByText('Lava Security')).toBeNull();
  expect(screen.UNSAFE_queryAllByType(ActivityIndicator)).toHaveLength(0);
  if(state!=='active') {
    expect(screen.getByTestId('lava-render-frame',{includeHiddenElements:true}).props.pointerEvents).toBe('none');
    expect(mockCommand).not.toHaveBeenCalled();
    emitSnapshot(JSON.stringify({schema:1,fullApp:true,revision:2,presentationBlocked:true,backgroundPrivacyCoverRequired:false}));
    expect(screen.getByText('Native private value 1',{includeHiddenElements:true})).toBeTruthy();
  }
  emitState('active');
  await act(async()=>reads.at(-1)!.resolve(snapshot(3,false)));
  expect(screen.getByText('Native private value 3')).toBeTruthy();
  expect(screen.getByTestId('native-navigation-container')).toBe(navigator);
  expect(mockNavigationMount).toHaveBeenCalledTimes(1);
  expect(screen.queryByTestId('lava-privacy-cover')).toBeNull();
});

test('an all-off blocked marker never creates a loading or privacy cover and cannot invent a private frame',async()=>{
  render(<LavaUIReview fullApp initialSnapshot={JSON.stringify({schema:1,fullApp:true,revision:1,presentationBlocked:true,backgroundPrivacyCoverRequired:false})}/>);
  expect(screen.queryByTestId('lava-privacy-cover')).toBeNull();
  expect(screen.queryByText('Lava Security')).toBeNull();
  expect(screen.UNSAFE_queryAllByType(ActivityIndicator)).toHaveLength(0);
  expect(screen.queryByTestId('private-route-body',{includeHiddenElements:true})).toBeNull();
  await act(async()=>reads.at(-1)!.resolve(snapshot(2,false)));
  expect(screen.getByText('Native private value 2')).toBeTruthy();
});

test('turning off the last security choice retires a pending protected hydration cover immediately',async()=>{
  mockHydrationQueryCount=1;queryReads();
  render(<LavaUIReview fullApp initialSnapshot={snapshot(1,true)}/>);
  emitState('inactive');emitState('active');
  await act(async()=>reads.at(-1)!.resolve(snapshot(2,true)));
  expect(screen.getByTestId('lava-privacy-cover')).toBeTruthy();
  emitSnapshot(snapshot(3,false));
  expect(screen.queryByTestId('lava-privacy-cover')).toBeNull();
  expect(screen.getByText('Native private value 3')).toBeTruthy();
  expect(screen.getByTestId('lava-render-frame').props.pointerEvents).toBe('auto');
});

test('inactivity before the first accepted snapshot remains startup and withholds private content',async()=>{
  render(<LavaUIReview fullApp/>);
  expectStarting();
  emitState('inactive');expectStarting();
  emitState('background');expectStarting();
  await act(async()=>reads[0]!.resolve(snapshot(1)));
  expectStarting();
  expect(mockNavigationMount).not.toHaveBeenCalled();
  emitState('active');
  await act(async()=>reads.at(-1)!.resolve(snapshot(2)));
  expect(screen.queryByLabelText('Loading Lava')).toBeNull();
  expect(screen.getByText('Native private value 2')).toBeTruthy();
  expect(mockNavigationMount).toHaveBeenCalledTimes(1);
});

function queryReads() {
  const requests:ReturnType<typeof deferred<string>>[]=[];
  mockCommand.mockImplementation(()=>{const pending=deferred<string>();requests.push(pending);return pending.promise;});
  return requests;
}
test('an all-off phone-lock boundary retains painted values through active-before-unlock ordering and fresh reads',async()=>{
  jest.useFakeTimers();
  try {
    mockHydrationQueryCount=1;
    const requests=queryReads();
    render(<LavaUIReview fullApp initialSnapshot={snapshot(1,false)}/>);
    await act(async()=>{});
    await act(async()=>requests[0]!.resolve(JSON.stringify({snapshot:JSON.parse(snapshot(2,false)),result:['42 cached']})));
    fireEvent.press(screen.getByLabelText('Keep a private draft'));
    const navigator=screen.getByTestId('native-navigation-container');
    await act(async()=>jest.advanceTimersByTime(5000));
    expect(requests).toHaveLength(2);
    emitSnapshot(JSON.stringify({schema:1,fullApp:true,revision:3,presentationBlocked:true,backgroundPrivacyCoverRequired:false}));
    expect(AppState.currentState).toBe('active');
    expect(screen.queryByTestId('lava-privacy-cover')).toBeNull();
    expect(screen.getByText('Painted first query 42 cached',{includeHiddenElements:true})).toBeTruthy();
    expect(screen.getByTestId('lava-render-frame',{includeHiddenElements:true}).props.pointerEvents).toBe('none');
    expect(screen.getByTestId('lava-render-frame',{includeHiddenElements:true}).props.accessibilityElementsHidden).toBe(true);
    emitState('inactive');emitState('background');emitState('active');
    emitSnapshot(JSON.stringify({schema:1,fullApp:true,revision:4,presentationBlocked:true,backgroundPrivacyCoverRequired:false}));
    await act(async()=>requests[1]!.resolve(JSON.stringify({snapshot:JSON.parse(snapshot(1000,false)),result:['STALE']})));
    await act(async()=>jest.advanceTimersByTime(15000));
    expect(requests).toHaveLength(2);
    expect(screen.queryByText('Painted first query STALE',{includeHiddenElements:true})).toBeNull();
    expect(screen.getByText('Painted first query 42 cached',{includeHiddenElements:true})).toBeTruthy();
    expect(screen.queryByTestId('lava-privacy-cover')).toBeNull();
    await act(async()=>reads.at(-1)!.resolve(snapshot(5,false)));
    expect(requests).toHaveLength(3);
    expect(screen.getByText('Painted first query 42 cached')).toBeTruthy();
    expect(screen.queryByText('Painted first query Pending',{includeHiddenElements:true})).toBeNull();
    await act(async()=>requests[2]!.resolve(JSON.stringify({snapshot:JSON.parse(snapshot(6,false)),result:['43 refreshed']})));
    expect(screen.getByText('Painted first query 43 refreshed')).toBeTruthy();
    expect(screen.getByText('Previous private draft')).toBeTruthy();
    expect(screen.queryByTestId('lava-privacy-cover')).toBeNull();
    expect(screen.getByTestId('native-navigation-container')).toBe(navigator);
    expect(mockNavigationMount).toHaveBeenCalledTimes(1);
    expect(mockBodyMount).toHaveBeenCalledTimes(1);
  } finally {cleanup();jest.useRealTimers();}
});
async function settleQuery(request:ReturnType<typeof deferred<string>>,revision:number,value:string[]) {
  await act(async()=>request.resolve(JSON.stringify({snapshot:JSON.parse(snapshot(revision,true)),result:value})));
}
function expectHydrating() {
  expect(screen.getByTestId('lava-privacy-cover')).toBeTruthy();
  expect(screen.getByTestId('lava-render-frame',{includeHiddenElements:true}).props.pointerEvents).toBe('none');
  expect(screen.getByTestId('native-tab-shell',{includeHiddenElements:true}).props.nativeSelectionEnabled).toBe(false);
  // Preparation mounts pending bodies behind the opaque cover. Prove that
  // they exist before checking that accessibility cannot expose them.
  expect(screen.getAllByText(/Painted (first|second) query Pending/,{includeHiddenElements:true}).length).toBeGreaterThan(0);
  expect(screen.queryByText(/Painted (first|second) query Pending/)).toBeNull();
}

test('a query-free protected warm resume lifts its cover after the restored layout without another loading state',async()=>{
  render(<LavaUIReview fullApp initialSnapshot={snapshot(1,true)}/>);await act(async()=>{});
  emitState('inactive');emitState('active');expectConcealed();
  await act(async()=>reads.at(-1)!.resolve(snapshot(2,true)));
  expect(screen.queryByTestId('lava-privacy-cover')).toBeNull();
  expect(screen.getByText('Native private value 2')).toBeTruthy();
  expect(screen.queryByLabelText('Loading Lava')).toBeNull();
});

test.each([1,2])('a protected warm resume keeps erased content covered until all %i focused query values are painted',async count=>{
  mockHydrationQueryCount=count;const requests=queryReads();
  render(<LavaUIReview fullApp initialSnapshot={snapshot(1,true)}/>);
  await settleQuery(requests[0]!,1,['3704']);if(count>1)await settleQuery(requests[1]!,1,['24']);
  expect(screen.getByText('Painted first query 3704')).toBeTruthy();
  emitState('inactive');emitState('active');expectConcealed();
  await act(async()=>reads.at(-1)!.resolve(snapshot(2,true)));
  expectHydrating();expect(screen.queryByText('Painted first query 3704',{includeHiddenElements:true})).toBeNull();
  await settleQuery(requests[count]!,3,['3709']);
  if(count>1) {
    expectHydrating();expect(screen.getByText('Painted first query 3709',{includeHiddenElements:true})).toBeTruthy();
    expect(screen.queryByText('Painted first query 3709')).toBeNull();
    await settleQuery(requests[count+1]!,4,['25']);
  }
  expect(screen.queryByTestId('lava-privacy-cover')).toBeNull();
  expect(screen.getByText('Painted first query 3709')).toBeTruthy();
  expect(screen.queryByText(/Painted (first|second) query Pending/,{includeHiddenElements:true})).toBeNull();
  if(count>1)expect(screen.getByText('Painted second query 25')).toBeTruthy();
});

test('a failed authorized warm-resume query reveals its error instead of holding the privacy cover indefinitely',async()=>{
  mockHydrationQueryCount=1;const requests=queryReads();
  render(<LavaUIReview fullApp initialSnapshot={snapshot(1,true)}/>);await settleQuery(requests[0]!,1,['3704']);
  emitState('inactive');emitState('active');await act(async()=>reads.at(-1)!.resolve(snapshot(2,true)));
  expectHydrating();await act(async()=>requests[1]!.reject(new Error('Stats temporarily unavailable.')));
  expect(screen.queryByTestId('lava-privacy-cover')).toBeNull();
  expect(screen.getByText('Stats temporarily unavailable.')).toBeTruthy();
  expect(screen.queryByText('Painted first query 3704',{includeHiddenElements:true})).toBeNull();
});

test('authentication-prompt inactivity starts a new covered epoch and an old query cannot reveal its body',async()=>{
  mockHydrationQueryCount=1;const requests=queryReads();
  render(<LavaUIReview fullApp initialSnapshot={snapshot(1,true)}/>);await settleQuery(requests[0]!,1,['3704']);
  emitState('inactive');emitState('active');await act(async()=>reads.at(-1)!.resolve(snapshot(2,true)));
  expectHydrating();emitState('inactive');expectConcealed();
  await settleQuery(requests[1]!,3,['stale-before-authentication']);expectConcealed();
  emitState('active');await act(async()=>reads.at(-1)!.resolve(snapshot(4,true)));
  expectHydrating();await settleQuery(requests[2]!,5,['3710']);
  expect(screen.queryByTestId('lava-privacy-cover')).toBeNull();
  expect(screen.getByText('Painted first query 3710')).toBeTruthy();
  expect(screen.queryByText('Painted first query stale-before-authentication',{includeHiddenElements:true})).toBeNull();
});

test('a query scope replacement under the cover waits for the new focused read and ignores the previous scope',async()=>{
  mockHydrationQueryCount=1;const requests=queryReads();
  render(<LavaUIReview fullApp initialSnapshot={snapshot(1,true)}/>);await settleQuery(requests[0]!,1,['3704']);
  emitState('inactive');emitState('active');await act(async()=>reads.at(-1)!.resolve(snapshot(2,true)));
  expectHydrating();mockHydrationQueryScope=100;emitSnapshot(snapshot(3,true));await act(async()=>{});
  expectHydrating();await settleQuery(requests[1]!,4,['wrong-period']);expectHydrating();
  await settleQuery(requests[2]!,5,['current-period']);
  expect(screen.queryByTestId('lava-privacy-cover')).toBeNull();
  expect(screen.getByText('Painted first query current-period')).toBeTruthy();
  expect(screen.queryByText('Painted first query wrong-period',{includeHiddenElements:true})).toBeNull();
});

test('a read from a blurred route cannot hold the resumed visible interface covered',async()=>{
  mockHydrationQueryCount=1;const requests=queryReads();
  render(<LavaUIReview fullApp initialSnapshot={snapshot(1,true)}/>);await settleQuery(requests[0]!,1,['3704']);
  emitState('inactive');emitState('active');await act(async()=>reads.at(-1)!.resolve(snapshot(2,true)));
  expectHydrating();mockFocused=false;emitSnapshot(snapshot(3,true));await act(async()=>{});
  expect(screen.queryByTestId('lava-privacy-cover')).toBeNull();
  await settleQuery(requests[1]!,4,['offscreen-reply']);
  expect(screen.queryByText('Painted first query offscreen-reply',{includeHiddenElements:true})).toBeNull();
});
