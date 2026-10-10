import {ActivityIndicator, AppState, Pressable, StyleSheet, type AppStateStatus} from 'react-native';
import {act, cleanup, fireEvent, render, screen} from '@testing-library/react-native';
import {SafeAreaInsetsContext} from 'react-native-safe-area-context';
import {LavaUIReview} from '../review/LavaUIReview';
import {PresentationCover} from '../review/PresentationCover';
import {initialSession} from '../review/session';
import type {NavigationState} from '@react-navigation/native';


const mockGetSnapshot=jest.fn<Promise<string>,[]>();
const mockCommand=jest.fn<Promise<string>,[string]>();
const mockOnSnapshot=jest.fn();
const mockNavigationMount=jest.fn();
const mockNavigationUnmount=jest.fn();
const mockBodyMount=jest.fn();
const mockBodyUnmount=jest.fn();
let mockAutomaticNativeFrame=true;
const mockPreventRemove=jest.fn();
let mockHydrationQueryCount=0;
let mockHydrationQueryScope=0;
let mockFocused=true;
let mockRootState:NavigationState|undefined;
const mockNavigationDispatch=jest.fn();
const mockNavigationListeners=new Set<()=>void>();
const mockSubscribeNavigation=(listener:()=>void)=>{mockNavigationListeners.add(listener);return()=>{mockNavigationListeners.delete(listener);};};

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
jest.mock('../specs/NativeLavaReview',()=>({__esModule:true,default:{close:jest.fn(),getGuardAccents:()=>JSON.stringify({})}}));
jest.mock('react-native-safe-area-context',()=>{
  const React=require('react');const {View}=require('react-native');
  return {SafeAreaProvider:({children}:{children:import('react').ReactNode})=>React.createElement(View,{testID:'runtime-safe-area-provider'},children),SafeAreaInsetsContext:React.createContext(null)};
});
jest.mock('@react-navigation/native',()=>{
  const React=require('react');const {View}=require('react-native');
  return {
    DarkTheme:{colors:{}},DefaultTheme:{colors:{}},
    useIsFocused:()=>mockFocused,
    usePreventRemove:(prevent:boolean)=>mockPreventRemove(prevent),
    NavigationIndependentTree:({children}:{children:import('react').ReactNode})=>children,
    createNavigationContainerRef:()=>({current:null,isReady:()=>true,getRootState:()=>mockRootState,dispatch:mockNavigationDispatch}),
    NavigationContainer:React.forwardRef(({children,initialState,onReady,onStateChange}:{children:import('react').ReactNode;initialState?:unknown;onReady?:()=>void;onStateChange?:(state:NavigationState)=>void},_ref:unknown)=>{
      // Count the retained app navigator. Setup has an independent native modal
      // navigator around it, whose shell is exercised by the full-app journey.
      React.useEffect(()=>{if(initialState)return;mockNavigationMount();return ()=>mockNavigationUnmount();},[]);
      React.useEffect(()=>{if(initialState||!mockAutomaticNativeFrame)return;
        let current=true;onReady?.();void Promise.resolve().then(()=>{if(!current)return;const rendered=require('@testing-library/react-native').screen;
          const root=rendered.queryByTestId('lava-render-frame',{includeHiddenElements:true});
          if(root)root.props.onLayout({nativeEvent:{layout:{x:0,y:0,width:390,height:844}}});
          const destination=rendered.queryByTestId('private-route-body',{includeHiddenElements:true});
          destination?.props.onLayout?.({nativeEvent:{layout:{x:0,y:0,width:390,height:844}}});
        });return()=>{current=false;};
      },[]);
      return React.createElement(View,{testID:initialState?'onboarding-navigation-container':'native-navigation-container',onReady,onStateChange},children);
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
      const state=React.useSyncExternalStore(mockSubscribeNavigation,()=>mockRootState);
      const activeTab=state?.routes[state.index];
      const stack=initialRouteName==='Guard'||initialRouteName==='Settings'?activeTab?.state:undefined;
      const destination=typeof screenOptions==='function'?activeTab?.name:stack?.routes[stack.index??0]?.name;
      const child=routes.find(route=>route.props.name===(destination??initialRouteName))??routes[0]??null;
      return typeof screenOptions==='function'?React.createElement(View,{testID:'native-tab-shell',
        nativeSelectionEnabled:screenOptions({route:{name:'GuardTab'}}).tabBarSelectionEnabled,
        nativeTabBarHidden:screenOptions({route:{name:'GuardTab'}}).tabBarStyle?.display==='none'},child):child;
    },
    Screen:({component:Component,children,name,options}:{component?:import('react').ComponentType;children?:()=>import('react').ReactNode;name:string;options?:{title?:string}})=>
      React.createElement(View,{testID:`native-route.${name}`,nativeTitle:options?.title},Component?React.createElement(Component):children?.()),
  };
}
jest.mock('@react-navigation/native-stack',()=>({createNativeStackNavigator:()=>mockNativeNavigator()}));
jest.mock('@react-navigation/bottom-tabs/unstable',()=>({createNativeBottomTabNavigator:()=>mockNativeNavigator()}));
jest.mock('../review/navigation-scaffold',()=>({...jest.requireActual('../review/navigation-scaffold'),useOrdinaryPushPresentation:()=>({})}));
jest.mock('../review/scaffold',()=>({fullScreenModalPresentation:{},fullSheetPresentation:{},nativeFlowHeader:()=>({}),onboardingHeaderOptions:{},toolbarButton:jest.fn()}));
jest.mock('../review/primitives',()=>{
  const React=require('react');const {Text,View}=require('react-native');
  return {
    Copy:({children}:{children:import('react').ReactNode})=>React.createElement(Text,null,children),
    Symbol:({name}:{name:string})=>React.createElement(View,{testID:'runtime-cover-symbol',accessibilityLabel:name}),
  };
});
jest.mock('../review/ForegroundFlowScreen',()=>({ForegroundFlowScreen:()=>{
  const React=require('react');const {Text,View}=require('react-native');
  const {app,live}=require('../review/ReviewContext').useReview();
  const {useAppQuery}=require('../app/queries');
  useAppQuery(mockHydrationQueryCount?{type:'stats.query'}:null);
  // The confidential UIKit input cannot run in Jest. Keep its opaque body
  // identity while exercising the real root, AppStore and stale action gate.
  return React.createElement(View,{testID:'foreground-retained-body',ownerID:live?.foregroundFlow?.id,
    onRequestNativeEdit:()=>app.command({type:'vpnEditor.file',id:live?.foregroundFlow?.id})},
    React.createElement(Text,null,'Accepted native editor frame'));
}}));
jest.mock('../review/screens',()=>{
  const React=require('react');const {Pressable,ScrollView,Text,View}=require('react-native');
  function PrivateBody({queryCount=mockHydrationQueryCount,scrollRoot=false}:{queryCount?:number;scrollRoot?:boolean}={}) {
    const {app,live}=require('../review/ReviewContext').useReview();
    const {useAppQuery}=require('../app/queries');
    const first=useAppQuery(queryCount?mockHydrationQueryScope
      ?{type:'activity.query',start:mockHydrationQueryScope,end:mockHydrationQueryScope+1}:{type:'stats.query'}:null);
    const second=useAppQuery(queryCount>1?{type:'network.query'}:null);
    const onLayout=require('../app/use-presentation-readiness').usePresentationNativeLayout();
    const presentation=React.useContext(require('../app/presentation').PresentationContext);
    const [draft,setDraft]=require('../app/use-route-view-state').useRouteViewState('New private draft');
    React.useEffect(()=>{
      mockBodyMount();
      // A body mounted after authorization receives its own native layout,
      // independently of the navigator that was prepared under the cover.
      if(mockAutomaticNativeFrame)onLayout({nativeEvent:{layout:{x:0,y:0,width:390,height:844}}});
      return ()=>mockBodyUnmount();
    },[]);
    return React.createElement(scrollRoot?ScrollView:View,{testID:'private-route-body',onLayout,presentationLocale:presentation.locale,presentationScales:presentation.textScales},
      live&&React.createElement(Text,null,`Native private value ${live.revision}`),
      React.createElement(Text,null,draft),
      queryCount>0&&React.createElement(Text,null,first.error??`Painted first query ${first.value?.join(',')??'Pending'}`),
      queryCount>1&&React.createElement(Text,null,second.error??`Painted second query ${second.value?.join(',')??'Pending'}`),
      React.createElement(Pressable,{accessibilityRole:'button',accessibilityLabel:'Keep a private draft',onPress:()=>setDraft('Previous private draft')}),
      React.createElement(Pressable,{accessibilityRole:'button',accessibilityLabel:'Refresh private runtime',onPress:()=>void app.refresh()}));
  }
  function RuntimeError({message,retry}:{message:string;retry:()=>void}) {
    return React.createElement(View,null,React.createElement(Text,null,message),
      React.createElement(Pressable,{accessibilityRole:'button',accessibilityLabel:'Retry runtime',onPress:retry}));
  }
  const RedirectBody=()=>React.createElement(PrivateBody,{queryCount:1});
  const SettingsBody=()=>React.createElement(PrivateBody,{scrollRoot:true});
  return new Proxy({GuardScreen:PrivateBody,SettingsScreen:SettingsBody,SecurityScreen:SettingsBody,PrivacyScreen:SettingsBody,DNSScreen:RedirectBody,ExploreScreen:RedirectBody,RuntimeError}, {
    get:(target:Record<string,unknown>,key:string)=>key in target?target[key]:()=>null,
  });
});

const deferred=<T,>()=>{
  let resolve!:(value:T)=>void, reject!:(error:Error)=>void;
  const promise=new Promise<T>((yes,no)=>{resolve=yes;reject=no;});
  return {promise,resolve,reject};
};
const snapshot=(revision:number,backgroundPrivacyCoverRequired?:boolean)=>JSON.stringify({schema:1,fullApp:true,revision,presentationToken:'frame-current',backgroundPrivacyCoverRequired,presentation:{locale:'en',textScales:null},
  session:{...initialSession(),filterID:'balanced',activeFilterID:'balanced'},look:'original',draft:{blocked:[],allowed:[]},savedDraft:{blocked:[],allowed:[]},qaTools:false});
const foregroundSnapshot=(revision:number,options:{policy?:boolean;ownerID?:string;kind?:string;concealed?:boolean;omitEditor?:boolean}={})=>{
  const value=JSON.parse(snapshot(revision,'policy' in options?options.policy:false));
  value.foregroundFlow={id:options.ownerID??'wireguard-visit',kind:options.kind??'vpnConfiguration',dismissAttempt:0,
    vpnEditor:{name:'',nameResetRevision:0,dirty:true,hasContent:true,concealed:options.concealed??false,reading:false,canEdit:true,canSave:true,error:''}};
  if(options.omitEditor)delete value.foregroundFlow.vpnEditor;
  return JSON.stringify(value);
};
const originalState=AppState.currentState;
let restoreLifecycle:()=>void;
let emitState:(state:AppStateStatus)=>void;
let emitSnapshot:(value:string)=>void;
let reads:ReturnType<typeof deferred<string>>[];

beforeEach(()=>{
  mockAutomaticNativeFrame=true;
  jest.spyOn(globalThis,'requestAnimationFrame').mockImplementation((callback:(timestamp:number)=>void)=>{callback(0);return 0;});
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
  mockRootState=undefined;mockNavigationDispatch.mockClear();mockNavigationListeners.clear();
  mockGetSnapshot.mockReset().mockImplementation(()=>{const read=deferred<string>();reads.push(read);return read.promise;});
  mockCommand.mockReset().mockResolvedValue(JSON.stringify({snapshot:JSON.parse(snapshot(1)),result:null}));
  mockOnSnapshot.mockReset().mockImplementation(callback=>{emitSnapshot=value=>act(()=>callback(value));return {remove:jest.fn()};});
  mockNavigationMount.mockClear();mockNavigationUnmount.mockClear();mockBodyMount.mockClear();mockBodyUnmount.mockClear();
  mockPreventRemove.mockClear();
});
afterEach(()=>{cleanup();restoreLifecycle();jest.restoreAllMocks();});

test('opaque privacy extent retains its action while only the content band follows horizontal safe edges',()=>{
  const unlock=jest.fn();
  const content=(insets:{top:number;bottom:number;left:number;right:number})=><SafeAreaInsetsContext.Provider value={insets}>
    <PresentationCover background="#123456"><Pressable accessibilityRole="button" accessibilityLabel="Unlock retained fixture" onPress={unlock} style={{alignSelf:'stretch'}}/></PresentationCover>
  </SafeAreaInsetsContext.Provider>;
  render(content({top:20,bottom:21,left:59,right:44}));
  const cover=screen.getByTestId('lava-privacy-cover');
  const action=screen.getByLabelText('Unlock retained fixture');
  const band=screen.getByTestId('lava-privacy-cover.content');
  const opaque=StyleSheet.flatten(cover.props.style);
  expect(cover.props.accessibilityViewIsModal).toBe(true);
  expect(opaque).toMatchObject({flex:1,backgroundColor:'#123456'});
  for(const key of ['marginLeft','marginRight','paddingLeft','paddingRight','width','maxWidth','opacity'] as const)expect(opaque[key]).toBeUndefined();
  expect(StyleSheet.flatten(band.props.style)).toMatchObject({alignSelf:'stretch',paddingLeft:59,paddingRight:44});
  expect(StyleSheet.flatten(band.props.style).paddingTop).toBeUndefined();
  expect(StyleSheet.flatten(band.props.style).paddingBottom).toBeUndefined();
  fireEvent.press(action);
  screen.rerender(content({top:59,bottom:34,left:0,right:0}));
  expect(screen.getByTestId('lava-privacy-cover')).toBe(cover);
  expect(screen.getByTestId('lava-privacy-cover.content')).toBe(band);
  expect(screen.getByLabelText('Unlock retained fixture')).toBe(action);
  expect(StyleSheet.flatten(band.props.style)).toMatchObject({paddingLeft:0,paddingRight:0});
  fireEvent.press(action);
  expect(unlock).toHaveBeenCalledTimes(2);
});

test('privacy content has a zero horizontal fallback without a safe-area provider',()=>{
  render(<PresentationCover/>);
  expect(StyleSheet.flatten(screen.getByTestId('lava-privacy-cover.content').props.style)).toMatchObject({paddingLeft:0,paddingRight:0});
  expect(screen.getByText('Lava Security')).toBeTruthy();
});

test.each([false,true])('runtime failure uses one horizontal content band without changing its privacy choice (%s)',async concealed=>{
  const initial=JSON.stringify({schema:1,fullApp:true,revision:1,presentationBlocked:true,backgroundPrivacyCoverRequired:concealed});
  const content=(left:number,right:number)=><SafeAreaInsetsContext.Provider value={{top:20,bottom:21,left,right}}><LavaUIReview fullApp initialSnapshot={initial}/></SafeAreaInsetsContext.Provider>;
  render(content(59,44));
  expect(screen.getByTestId('runtime-safe-area-provider')).toBeTruthy();
  await act(async()=>reads[0]!.reject(new Error('Retryable runtime failure.')));
  const action=screen.getByLabelText('Retry runtime');
  const bandID=concealed?'lava-privacy-cover.content':'lava-runtime-content';
  const band=screen.getByTestId(bandID);
  expect(StyleSheet.flatten(band.props.style)).toMatchObject({paddingLeft:59,paddingRight:44});
  expect(screen.queryByTestId('lava-privacy-cover')!==null).toBe(concealed);
  expect(screen.queryByTestId(concealed?'lava-runtime-content':'lava-privacy-cover.content')).toBeNull();
  expect(screen.queryByTestId('private-route-body')).toBeNull();
  expect(screen.getByTestId('private-route-body',{includeHiddenElements:true})).toBeTruthy();
  expect(screen.UNSAFE_queryAllByType(ActivityIndicator)).toHaveLength(0);
  screen.rerender(content(0,0));
  expect(screen.getByTestId(bandID)).toBe(band);
  expect(screen.getByLabelText('Retry runtime')).toBe(action);
  expect(StyleSheet.flatten(band.props.style)).toMatchObject({paddingLeft:0,paddingRight:0});
  fireEvent.press(action);
  expect(reads).toHaveLength(2);
  await act(async()=>reads[1]!.resolve(snapshot(2,false)));
  expect(screen.queryByText('Retryable runtime failure.')).toBeNull();
  expect(screen.getByText('Native private value 2')).toBeTruthy();
});

test.each([
  ['en','Guard'],['ja','ガード'],['zh-Hant','防護'],['zh-Hans','防护'],
  ['de','Schutz'],['fr','Protection'],['es','Protección'],['ko','보호'],
  ['pt-BR','Proteção'],['it','Protezione'],
])('Guard header and native tab share the translated title in %s', async (locale,title)=>{
  const initial=JSON.parse(snapshot(1));initial.presentation.locale=locale;
  render(<LavaUIReview fullApp initialSnapshot={JSON.stringify(initial)}/>);
  await act(async()=>{});
  expect(screen.getByTestId('native-route.Guard').props.nativeTitle).toBe(title);
  expect(screen.getByTestId('native-route.GuardTab').props.nativeTitle).toBe(title);
});

test.each([false,true])('only its current onboarding owner hides the retained native tabs (preview=%s)',async onboardingPreview=>{
  render(<LavaUIReview fullApp onboardingPreview={onboardingPreview} initialSnapshot={snapshot(1,false)}/>);
  await act(async()=>{});
  const tabs=screen.getByTestId('native-tab-shell');
  const guard=screen.getByTestId('private-route-body');
  const navigation=screen.getByTestId('native-navigation-container');
  expect(tabs.props.nativeTabBarHidden).toBe(false);
  const update=(revision:number,mock:boolean)=>{
    const value=JSON.parse(snapshot(revision,false));
    value.onboardingSetup={id:`setup-${revision}`,mock,page:5,phase:'ready',history:[0,1,2,3,4],visited:[0,1,2,3,4,5]};
    emitSnapshot(JSON.stringify(value));
  };
  update(2,!onboardingPreview);
  expect(screen.getByTestId('native-tab-shell').props.nativeTabBarHidden).toBe(false);
  update(3,onboardingPreview);
  expect(screen.getByTestId('native-tab-shell',{includeHiddenElements:true}).props.nativeTabBarHidden).toBe(true);
  expect(screen.getByTestId('native-tab-shell',{includeHiddenElements:true})).toBe(tabs);
  expect(screen.getByTestId('private-route-body',{includeHiddenElements:true})).toBe(guard);
  emitSnapshot(snapshot(4,false));
  expect(screen.getByTestId('native-tab-shell').props.nativeTabBarHidden).toBe(false);
  expect(screen.getByTestId('private-route-body')).toBe(guard);
  expect(screen.getByTestId('native-navigation-container')).toBe(navigation);
  expect(mockNavigationMount).toHaveBeenCalledTimes(1);
  expect(mockNavigationUnmount).not.toHaveBeenCalled();
  expect(mockBodyUnmount).not.toHaveBeenCalled();
});

function expectConcealed() {
  expect(screen.getByTestId('lava-privacy-cover')).toBeTruthy();
  expect(screen.getByTestId('lava-privacy-cover.symbol',{includeHiddenElements:true}).props.symbol).toBe('lock.shield.fill');
  expect(screen.getByText('Lava Security')).toBeTruthy();
  expect(screen.queryByLabelText('Loading Lava')).toBeNull();
  expect(screen.queryByTestId('private-route-body')).toBeNull();
  expect(screen.queryByText('Previous private draft')).toBeNull();
}

test('repeated warm resumes conceal without loading, retain the same route scaffold and ignore pre-background reads',async()=>{
  render(<LavaUIReview fullApp initialSnapshot={snapshot(1)}/>);
  await act(async()=>{});
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
    expect(mockBodyUnmount).not.toHaveBeenCalled();
    await act(async()=>authorized.resolve(snapshot(cycle*20)));
    expect(screen.queryByTestId('lava-privacy-cover')).toBeNull();
    expect(screen.queryByLabelText('Loading Lava')).toBeNull();
    expect(screen.getByText(`Native private value ${cycle*20}`)).toBeTruthy();
    expect(screen.getByText('Previous private draft')).toBeTruthy();
    expect(screen.getByTestId('native-navigation-container')).toBe(navigator);
    expect(mockBodyMount).toHaveBeenCalledTimes(1);
  }
});

test('a native locked projection uses the same privacy cover and retains a retryable runtime error',async()=>{
  render(<LavaUIReview fullApp initialSnapshot={snapshot(1)}/>);
  await act(async()=>{});
  const navigator=screen.getByTestId('native-navigation-container');
  fireEvent.press(screen.getByLabelText('Keep a private draft'));
  emitSnapshot(JSON.stringify({schema:1,fullApp:true,revision:2,presentationBlocked:true}));
  expectConcealed();
  await act(async()=>reads[0]!.resolve(snapshot(1)));
  expectConcealed();
  emitSnapshot(snapshot(3));
  await act(async()=>{});
  expect(screen.getByText('Native private value 3')).toBeTruthy();
  expect(screen.getByText('Previous private draft')).toBeTruthy();
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

test('first unlock waits for the focused destination native viewport and a presented frame after navigation is ready',async()=>{
  mockAutomaticNativeFrame=false;
  const frames:Array<()=>void>=[];
  jest.spyOn(globalThis,'requestAnimationFrame').mockImplementation((callback:(timestamp:number)=>void)=>{frames.push(()=>callback(0));return frames.length;});
  render(<LavaUIReview fullApp presentationID="root"/>);expectStarting();
  await act(async()=>reads[0]!.resolve(snapshot(1,true)));
  const destination=screen.getByTestId('private-route-body',{includeHiddenElements:true});
  const root=screen.getByTestId('lava-render-frame',{includeHiddenElements:true});
  const layout=(width:number,height:number)=>({nativeEvent:{layout:{x:0,y:0,width,height}}});
  fireEvent(screen.getByTestId('native-navigation-container',{includeHiddenElements:true}),'ready');
  fireEvent(root,'layout',layout(390,844));
  await act(async()=>{});
  expectHydrationCoverOnly();expect(frames).toHaveLength(0);
  fireEvent(destination,'layout',layout(0,844));await act(async()=>{});
  expectHydrationCoverOnly();expect(frames).toHaveLength(0);
  fireEvent(destination,'layout',layout(390,844));await act(async()=>{});
  expectPreparedUnderNativeCover();expect(frames).toHaveLength(1);
  await act(async()=>frames.shift()!());
  expect(mockCommand.mock.calls.filter(([request])=>JSON.parse(request).type==='presentation.ready')).toHaveLength(1);
  expect(screen.queryByTestId('lava-privacy-cover')).toBeNull();
  expect(screen.getByTestId('private-route-body')).toBe(destination);
  expect(screen.getByText('Native private value 1')).toBeTruthy();
});

const redirectState=(tab:string,screen:string)=>({stale:false,type:'tab',key:'tabs',index:tab==='SettingsTab'?1:0,
  routeNames:['GuardTab','SettingsTab'],routes:[
    {name:'GuardTab',key:'guard-tab',state:{stale:false,type:'stack',key:'guard-stack',index:tab==='GuardTab'&&screen!=='Guard'?1:0,routeNames:['Guard','Explore'],routes:[{name:'Guard',key:'guard'},...(tab==='GuardTab'&&screen!=='Guard'?[{name:screen,key:'guard-child'}]:[])]}},
    {name:'SettingsTab',key:'settings-tab',state:{stale:false,type:'stack',key:'settings-stack',index:tab==='SettingsTab'&&screen!=='Settings'?1:0,routeNames:['Settings','DNS'],routes:[{name:'Settings',key:'settings'},...(tab==='SettingsTab'&&screen!=='Settings'?[{name:screen,key:'settings-child'}]:[])]}},
  ]} as NavigationState);

test.each(['Security','Privacy','Settings'])('ordinary %s keeps the native scroll viewport through policy changes and retires it on account owner replacement',async target=>{
  mockRootState=redirectState('SettingsTab',target);
  const initial=JSON.parse(snapshot(1,true));initial.security={ownerRevision:'account-1',unavailable:false};
  render(<LavaUIReview fullApp initialSnapshot={JSON.stringify(initial)}/>);
  await act(async()=>{});
  const body=screen.getByTestId('private-route-body');
  const policy={...initial,revision:2,session:{...initial.session,protectedActions:{...initial.session.protectedActions,'App Unlock':true,'Update App Settings':true}}};
  emitSnapshot(JSON.stringify(policy));await act(async()=>{});
  expect(screen.getByTestId('private-route-body')).toBe(body);
  expect(mockBodyMount).toHaveBeenCalledTimes(1);expect(mockBodyUnmount).not.toHaveBeenCalled();
  emitSnapshot(JSON.stringify({...policy,revision:3,security:{...policy.security,ownerRevision:'account-2'}}));
  await act(async()=>{});
  expect(screen.getByTestId('private-route-body')).not.toBe(body);
  expect(mockBodyMount).toHaveBeenCalledTimes(2);expect(mockBodyUnmount).toHaveBeenCalledTimes(1);
  expect(mockNavigationMount).toHaveBeenCalledTimes(1);expect(mockNavigationUnmount).not.toHaveBeenCalled();
});

test.each([false,true])('Security keeps its inert native scaffold through owned authentication and restores current policy without a retry screen (remaining protection=%s)',async remainingProtection=>{
  mockRootState=redirectState('SettingsTab','Security');
  const initial=JSON.parse(snapshot(1,true));
  initial.security={ownerRevision:'security-owner',unavailable:false};
  initial.authenticationInProgress=true;
  initial.presentation={locale:'zh-Hant',textScales:{body:1.2}};
  render(<LavaUIReview fullApp initialSnapshot={JSON.stringify(initial)}/>);await act(async()=>{});
  const body=screen.getByTestId('private-route-body');
  const paused=()=>{
    expect(screen.getByTestId('private-route-body',{includeHiddenElements:true})).toBe(body);
    expect(screen.getByTestId('lava-render-frame',{includeHiddenElements:true}).props).toMatchObject({pointerEvents:'none',accessibilityElementsHidden:true});
    expect(screen.queryByTestId('lava-privacy-cover')).toBeNull();
    expect(screen.queryByLabelText('Retry runtime',{includeHiddenElements:true})).toBeNull();
    expect(screen.getByTestId('private-route-body',{includeHiddenElements:true}).props.presentationLocale).toBe('zh-Hant');
  };
  emitState('inactive');paused();
  emitSnapshot(JSON.stringify({schema:1,fullApp:true,revision:2,presentationBlocked:true,
    authenticationInProgress:false,presentationRevoked:false,backgroundPrivacyCoverRequired:remainingProtection,
    security:{ownerRevision:'security-owner'}}));paused();
  emitState('active');paused();
  const fresh={...initial,revision:3,authenticationInProgress:false,backgroundPrivacyCoverRequired:remainingProtection};
  await act(async()=>reads.at(-1)!.resolve(JSON.stringify(fresh)));
  expect(screen.getByTestId('private-route-body')).toBe(body);
  expect(screen.getByTestId('lava-render-frame').props.pointerEvents).toBe('auto');
  expect(screen.getByText('Native private value 3')).toBeTruthy();
  expect(screen.queryByTestId('lava-privacy-cover')).toBeNull();
  expect(screen.queryByLabelText('Retry runtime')).toBeNull();
  expect(mockBodyMount).toHaveBeenCalledTimes(1);
});

test('a hard native boundary during owned authentication conceals Security immediately and cannot revive its prior display',async()=>{
  mockRootState=redirectState('SettingsTab','Security');
  const initial=JSON.parse(snapshot(1,true));initial.security={ownerRevision:'security-owner',unavailable:false};initial.authenticationInProgress=true;
  render(<LavaUIReview fullApp initialSnapshot={JSON.stringify(initial)}/>);await act(async()=>{});
  emitState('inactive');expect(screen.queryByTestId('lava-privacy-cover')).toBeNull();
  emitSnapshot(JSON.stringify({schema:1,fullApp:true,revision:2,presentationBlocked:true,presentationRevoked:true,
    authenticationInProgress:true,backgroundPrivacyCoverRequired:true,security:{ownerRevision:'security-owner'}}));
  expect(screen.getByTestId('lava-privacy-cover')).toBeTruthy();
  expect(screen.queryByText('Native private value 1',{includeHiddenElements:true})).toBeNull();
  emitSnapshot(JSON.stringify({schema:1,fullApp:true,revision:3,presentationBlocked:true,authenticationInProgress:true,
    backgroundPrivacyCoverRequired:true,security:{ownerRevision:'security-owner'}}));
  expect(screen.getByTestId('lava-privacy-cover')).toBeTruthy();
  expect(screen.queryByText('Native private value 1',{includeHiddenElements:true})).toBeNull();
});

test('a failed owned-authentication refresh replaces the inert frame with a visible retry and restores Security on retry',async()=>{
  mockRootState=redirectState('SettingsTab','Security');
  const initial=JSON.parse(snapshot(1,true));initial.security={ownerRevision:'security-owner',unavailable:false};initial.authenticationInProgress=true;
  render(<LavaUIReview fullApp initialSnapshot={JSON.stringify(initial)}/>);await act(async()=>{});
  emitState('inactive');emitState('active');
  await act(async()=>reads.at(-1)!.reject(new Error('Refresh failed.')));
  expect(screen.getByText('Refresh failed.')).toBeTruthy();expect(screen.getByLabelText('Retry runtime')).toBeTruthy();
  expect(screen.queryByText('Native private value 1',{includeHiddenElements:true})).toBeNull();
  fireEvent.press(screen.getByLabelText('Retry runtime'));
  await act(async()=>reads.at(-1)!.resolve(JSON.stringify({...initial,revision:2,authenticationInProgress:false})));
  expect(screen.getByText('Native private value 2')).toBeTruthy();
  expect(screen.queryByTestId('lava-privacy-cover')).toBeNull();expect(screen.queryByText('Refresh failed.')).toBeNull();
});

test('withheld private fields preserve only accepted locale and text-scale metadata until fresh presentation returns',async()=>{
  mockRootState=redirectState('SettingsTab','Security');
  const initial=JSON.parse(snapshot(1,true));
  initial.security={ownerRevision:'account-1',unavailable:false};
  initial.presentation={locale:'zh-Hant',textScales:{body:1.3,title1:1.2}};
  render(<LavaUIReview fullApp initialSnapshot={JSON.stringify(initial)}/>);
  await act(async()=>{});
  const body=screen.getByTestId('private-route-body');
  expect(body.props.presentationLocale).toBe('zh-Hant');expect(body.props.presentationScales).toEqual(initial.presentation.textScales);
  expect(screen.getByTestId('native-route.SettingsTab').props.nativeTitle).toBe('設定');
  emitState('inactive');
  expect(screen.getByTestId('private-route-body',{includeHiddenElements:true})).toBe(body);
  expect(body.props.presentationLocale).toBe('zh-Hant');expect(body.props.presentationScales).toEqual(initial.presentation.textScales);
  expect(screen.getByTestId('native-route.SettingsTab',{includeHiddenElements:true}).props.nativeTitle).toBe('設定');
  expect(screen.queryByText('Native private value 1',{includeHiddenElements:true})).toBeNull();
  emitState('active');
  const fresh={...initial,revision:2,presentation:{locale:'ja',textScales:{body:1.1,title1:1.05}}};
  await act(async()=>reads.at(-1)!.resolve(JSON.stringify(fresh)));
  expect(screen.getByTestId('private-route-body')).toBe(body);
  expect(body.props.presentationLocale).toBe('ja');expect(body.props.presentationScales).toEqual(fresh.presentation.textScales);
  expect(screen.getByTestId('native-route.SettingsTab').props.nativeTitle).toBe('設定');
  expect(screen.getByText('Native private value 2')).toBeTruthy();
});

test.each([['GuardTab','Explore'],['SettingsTab','DNS']])('cold native redirect to %s/%s stays covered until its committed destination viewport and read are ready',async(tab,target)=>{
  mockAutomaticNativeFrame=false;mockRootState=redirectState('GuardTab','Guard');
  const frames:Array<()=>void>=[],query=deferred<string>();
  jest.spyOn(globalThis,'requestAnimationFrame').mockImplementation((callback:(timestamp:number)=>void)=>{frames.push(()=>callback(0));return frames.length;});
  const initial={...JSON.parse(snapshot(1,true)),navigation:{serial:1,tab,screen:target}};
  mockCommand.mockImplementation(request=>JSON.parse(request).type==='stats.query'?query.promise:Promise.resolve(JSON.stringify({snapshot:initial,result:null})));
  render(<LavaUIReview fullApp presentationID="root" initialSnapshot={JSON.stringify(initial)}/>);
  const layout={nativeEvent:{layout:{x:0,y:0,width:390,height:844}}};
  fireEvent(screen.getByTestId('private-route-body',{includeHiddenElements:true}),'layout',layout);
  fireEvent(screen.getByTestId('lava-render-frame',{includeHiddenElements:true}),'layout',layout);
  fireEvent(screen.getByTestId('native-navigation-container',{includeHiddenElements:true}),'ready');
  await act(async()=>{});
  expectHydrationCoverOnly();expect(frames).toHaveLength(0);
  expect(mockNavigationDispatch).toHaveBeenCalledTimes(1);
  expect(mockNavigationDispatch.mock.lastCall![0]).toMatchObject({type:'NAVIGATE',payload:{name:tab,params:{state:{routes:[{name:tab==='SettingsTab'?'Settings':'Guard'},{name:target}]}}}});
  act(()=>{mockRootState=redirectState(tab,target);mockNavigationListeners.forEach(listener=>listener());});
  fireEvent(screen.getByTestId('native-navigation-container',{includeHiddenElements:true}),'stateChange',mockRootState);
  await act(async()=>{});
  expectHydrationCoverOnly();expect(frames).toHaveLength(0);
  const destination=screen.getByTestId('private-route-body',{includeHiddenElements:true});
  fireEvent(destination,'layout',layout);await act(async()=>{});
  expectHydrationCoverOnly();expect(frames).toHaveLength(0);
  await act(async()=>query.resolve(JSON.stringify({snapshot:initial,result:['Destination ready']})));
  expectPreparedUnderNativeCover();expect(frames).toHaveLength(1);
  await act(async()=>frames.shift()!());
  expect(mockCommand.mock.calls.filter(([request])=>JSON.parse(request).type==='presentation.ready')).toHaveLength(1);
  expect(screen.queryByTestId('lava-privacy-cover')).toBeNull();
  expect(screen.getByTestId(`native-route.${target}`)).toBeTruthy();
  expect(screen.getByText('Painted first query Destination ready')).toBeTruthy();
  expect(mockNavigationDispatch).toHaveBeenCalledTimes(1);
});

test('a cold native redirect already at its committed root settles without dispatch or a stuck cover',async()=>{
  mockAutomaticNativeFrame=false;mockRootState=redirectState('GuardTab','Guard');
  const frames:Array<()=>void>=[];
  jest.spyOn(globalThis,'requestAnimationFrame').mockImplementation((callback:(timestamp:number)=>void)=>{frames.push(()=>callback(0));return frames.length;});
  const initial={...JSON.parse(snapshot(1,true)),navigation:{serial:1,tab:'GuardTab',screen:'Guard'}};
  render(<LavaUIReview fullApp presentationID="root" initialSnapshot={JSON.stringify(initial)}/>);
  const layout={nativeEvent:{layout:{x:0,y:0,width:390,height:844}}};
  fireEvent(screen.getByTestId('private-route-body',{includeHiddenElements:true}),'layout',layout);
  fireEvent(screen.getByTestId('lava-render-frame',{includeHiddenElements:true}),'layout',layout);
  fireEvent(screen.getByTestId('native-navigation-container',{includeHiddenElements:true}),'ready');
  await act(async()=>{});
  expect(mockNavigationDispatch).not.toHaveBeenCalled();expectPreparedUnderNativeCover();expect(frames).toHaveLength(1);
  await act(async()=>frames.shift()!());
  expect(mockCommand.mock.calls.filter(([request])=>JSON.parse(request).type==='presentation.ready')).toHaveLength(1);
  expect(screen.queryByTestId('lava-privacy-cover')).toBeNull();
  expect(screen.getByTestId('native-route.Guard')).toBeTruthy();
});

test('uncommitted native redirect retries its serial after authority revocation and a newer request retires the old handoff',async()=>{
  mockAutomaticNativeFrame=false;mockRootState=redirectState('GuardTab','Guard');
  const frames:Array<()=>void>=[],query=deferred<string>();
  jest.spyOn(globalThis,'requestAnimationFrame').mockImplementation((callback:(timestamp:number)=>void)=>{frames.push(()=>callback(0));return frames.length;});
  let current={...JSON.parse(snapshot(1,true)),navigation:{serial:7,tab:'SettingsTab',screen:'DNS'}};
  mockCommand.mockImplementation(request=>JSON.parse(request).type==='stats.query'?query.promise:Promise.resolve(JSON.stringify({snapshot:current,result:null})));
  render(<LavaUIReview fullApp presentationID="root" initialSnapshot={JSON.stringify(current)}/>);
  const layout={nativeEvent:{layout:{x:0,y:0,width:390,height:844}}};
  fireEvent(screen.getByTestId('private-route-body',{includeHiddenElements:true}),'layout',layout);
  fireEvent(screen.getByTestId('lava-render-frame',{includeHiddenElements:true}),'layout',layout);
  fireEvent(screen.getByTestId('native-navigation-container',{includeHiddenElements:true}),'ready');
  await act(async()=>{});expect(mockNavigationDispatch).toHaveBeenCalledTimes(1);
  emitState('background');
  emitSnapshot(JSON.stringify({...current,revision:2,presentationBlocked:true}));
  fireEvent(screen.getByTestId('native-navigation-container',{includeHiddenElements:true}),'stateChange',redirectState('SettingsTab','DNS'));
  await act(async()=>{});expect(mockNavigationDispatch).toHaveBeenCalledTimes(1);expect(frames).toHaveLength(0);
  emitState('active');current={...current,revision:3};emitSnapshot(JSON.stringify(current));
  await act(async()=>{});expect(mockNavigationDispatch).toHaveBeenCalledTimes(2);expectHydrationCoverOnly();expect(frames).toHaveLength(0);
  current={...current,revision:4,navigation:{serial:8,tab:'GuardTab',screen:'Explore'}};emitSnapshot(JSON.stringify(current));
  await act(async()=>{});expect(mockNavigationDispatch).toHaveBeenCalledTimes(3);
  expect(mockNavigationDispatch.mock.lastCall![0]).toMatchObject({payload:{name:'GuardTab',params:{state:{routes:[{name:'Guard'},{name:'Explore'}]}}}});
  // A delayed callback from the retired request cannot admit the current Guard
  // frame or settle the newer Explore handoff.
  fireEvent(screen.getByTestId('native-navigation-container',{includeHiddenElements:true}),'stateChange',redirectState('SettingsTab','DNS'));
  await act(async()=>{});expectHydrationCoverOnly();expect(frames).toHaveLength(0);
  act(()=>{mockRootState=redirectState('GuardTab','Explore');mockNavigationListeners.forEach(listener=>listener());});
  fireEvent(screen.getByTestId('native-navigation-container',{includeHiddenElements:true}),'stateChange',mockRootState);
  fireEvent(screen.getByTestId('private-route-body',{includeHiddenElements:true}),'layout',layout);
  await act(async()=>{});expectHydrationCoverOnly();expect(frames).toHaveLength(0);
  await act(async()=>query.resolve(JSON.stringify({snapshot:current,result:['Current redirect ready']})));
  expectPreparedUnderNativeCover();expect(frames).toHaveLength(1);
  await act(async()=>frames.shift()!());
  expect(mockCommand.mock.calls.filter(([request])=>JSON.parse(request).type==='presentation.ready')).toHaveLength(1);
  expect(screen.getByTestId('native-route.Explore')).toBeTruthy();
  expect(screen.getByText('Painted first query Current redirect ready')).toBeTruthy();
  expect(mockNavigationDispatch).toHaveBeenCalledTimes(3);
});
function expectPreparedUnderNativeCover(){
  // The native scene window remains covered until the next frame acknowledges
  // the completed React commit. There is no second frame inside hydration.
  expect(screen.queryByTestId('lava-privacy-cover')).toBeNull();
  expect(mockCommand.mock.calls.filter(([request])=>JSON.parse(request).type==='presentation.ready')).toHaveLength(0);
}
function expectHydrationCoverOnly(){
  expect(screen.getByTestId('lava-privacy-cover')).toBeTruthy();
  expect(screen.queryByTestId('private-route-body')).toBeNull();
  expect(screen.getByTestId('lava-render-frame',{includeHiddenElements:true}).props.pointerEvents).toBe('none');
}

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
  expect(screen.getByTestId('lava-render-frame').props).toMatchObject({pointerEvents:'auto',collapsable:false});
  expect(screen.getByTestId('lava-render-frame').props.accessibilityElementsHidden).toBe(false);
  expect(screen.getByTestId('native-tab-shell').props.nativeSelectionEnabled).toBe(true);
  expect(mockPreventRemove).toHaveBeenLastCalledWith(false);
  expect(screen.getByTestId('native-navigation-container')).toBe(navigator);
  expect(mockNavigationMount).toHaveBeenCalledTimes(1);expect(mockNavigationUnmount).not.toHaveBeenCalled();
  expect(mockBodyUnmount).not.toHaveBeenCalled();
});

test('only a same-visit all-off WireGuard display keeps its ancestor enabled while native edits and AX remain revoked through resume',async()=>{
  render(<LavaUIReview fullApp foregroundContext="wireguard-visit" initialSnapshot={foregroundSnapshot(1)}/>);
  await act(async()=>{});
  const originalFrame=screen.getByTestId('lava-render-frame');
  const body=screen.getByTestId('foreground-retained-body');
  const edit=body.props.onRequestNativeEdit as ()=>Promise<unknown>;
  const originalRead=reads[0]!;
  expect(originalFrame.props).toMatchObject({pointerEvents:'auto',collapsable:false});
  mockCommand.mockClear();
  for(const state of ['inactive','background','active'] as const){
    emitState(state);
    const frame=screen.getByTestId('lava-render-frame',{includeHiddenElements:true});
    expect(frame).toBe(originalFrame);
    expect(frame.props).toMatchObject({collapsable:false,pointerEvents:'box-only',accessibilityElementsHidden:true,importantForAccessibility:'no-hide-descendants'});
    expect(screen.getByTestId('foreground-retained-body',{includeHiddenElements:true})).toBe(body);
    expect(body.props.ownerID).toBe('wireguard-visit');
    expect(screen.queryByTestId('foreground-retained-body')).toBeNull();
    expect(screen.queryByTestId('lava-privacy-cover')).toBeNull();
    await act(async()=>{await expect(edit()).rejects.toThrow('Read access changed.');});
    expect(mockCommand).not.toHaveBeenCalled();
  }
  emitSnapshot(JSON.stringify({schema:1,fullApp:true,revision:8,presentationBlocked:true,backgroundPrivacyCoverRequired:false}));
  await act(async()=>originalRead.resolve(foregroundSnapshot(9)));
  expect(screen.getByTestId('lava-render-frame',{includeHiddenElements:true}).props.pointerEvents).toBe('box-only');
  expect(body.props.ownerID).toBe('wireguard-visit');
  await act(async()=>reads.at(-1)!.resolve(foregroundSnapshot(10)));
  expect(screen.getByTestId('lava-render-frame')).toBe(originalFrame);
  expect(originalFrame.props).toMatchObject({collapsable:false,pointerEvents:'auto',accessibilityElementsHidden:false,importantForAccessibility:'auto'});
  expect(screen.getByTestId('foreground-retained-body')).toBe(body);
  await act(async()=>edit());
  expect(mockCommand).toHaveBeenCalledTimes(1);
  expect(JSON.parse(mockCommand.mock.calls[0]![0])).toEqual({type:'vpnEditor.file',id:'wireguard-visit'});
});

test.each([
  {name:'another native visit',options:{ownerID:'replacement-visit'},context:'wireguard-visit'},
  {name:'another flow kind',options:{kind:'feedback'},context:'wireguard-visit'},
  {name:'missing editor projection',options:{omitEditor:true},context:'wireguard-visit'},
  {name:'a concealed configuration',options:{concealed:true},context:'wireguard-visit'},
  {name:'the ordinary app root',options:{},context:undefined},
])('the WireGuard responder fence excludes $name',async({options,context})=>{
  render(<LavaUIReview fullApp foregroundContext={context} initialSnapshot={foregroundSnapshot(1,options)}/>);
  await act(async()=>{});
  emitState('inactive');emitState('background');emitState('active');
  expect(screen.getByTestId('lava-render-frame',{includeHiddenElements:true}).props).toMatchObject({pointerEvents:'none',accessibilityElementsHidden:true,importantForAccessibility:'no-hide-descendants'});
  expect(mockCommand).not.toHaveBeenCalled();
});

test.each([true,undefined])('current %p privacy policy immediately revokes the all-off WireGuard responder fence and a late off marker cannot revive it',async policy=>{
  render(<LavaUIReview fullApp foregroundContext="wireguard-visit" initialSnapshot={foregroundSnapshot(1)}/>);
  await act(async()=>{});
  const edit=screen.getByTestId('foreground-retained-body').props.onRequestNativeEdit as ()=>Promise<unknown>;
  emitState('inactive');
  expect(screen.getByTestId('lava-render-frame',{includeHiddenElements:true}).props.pointerEvents).toBe('box-only');
  emitSnapshot(JSON.stringify({schema:1,fullApp:true,revision:2,presentationBlocked:true,backgroundPrivacyCoverRequired:policy}));
  expect(screen.getByTestId('lava-render-frame',{includeHiddenElements:true}).props.pointerEvents).toBe('none');
  expect(screen.getByTestId('lava-privacy-cover')).toBeTruthy();
  expect(screen.getByTestId('foreground-retained-body',{includeHiddenElements:true}).props.ownerID).toBeUndefined();
  emitSnapshot(JSON.stringify({schema:1,fullApp:true,revision:3,presentationBlocked:true,backgroundPrivacyCoverRequired:false}));
  expect(screen.getByTestId('lava-render-frame',{includeHiddenElements:true}).props.pointerEvents).toBe('none');
  await act(async()=>{await expect(edit()).rejects.toThrow('Read access changed.');});
  expect(mockCommand).not.toHaveBeenCalled();
});

test('an active protected WireGuard hydration pause cannot use the display-only responder fence',async()=>{
  mockHydrationQueryCount=1;const requests=queryReads();
  render(<LavaUIReview fullApp foregroundContext="wireguard-visit" initialSnapshot={foregroundSnapshot(1,{policy:true})}/>);
  await act(async()=>{});
  emitState('inactive');emitState('active');
  await act(async()=>reads.at(-1)!.resolve(foregroundSnapshot(2,{policy:true})));
  expect(requests.length).toBeGreaterThan(0);
  expect(screen.getByTestId('lava-privacy-cover')).toBeTruthy();
  expect(screen.getByTestId('lava-render-frame',{includeHiddenElements:true}).props).toMatchObject({pointerEvents:'none',accessibilityElementsHidden:true,importantForAccessibility:'no-hide-descendants'});
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
  expect(screen.queryByTestId('private-route-body')).toBeNull();
  await act(async()=>reads.at(-1)!.resolve(snapshot(4,false)));
  expect(screen.queryByTestId('lava-privacy-cover')).toBeNull();
  expect(screen.queryByTestId('private-route-body')).toBeNull();
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
  expect(screen.queryByTestId('private-route-body')).toBeNull();
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
  expect(screen.queryByTestId('private-route-body')).toBeNull();
  expect(screen.getByTestId('private-route-body',{includeHiddenElements:true})).toBeTruthy();
}

test('cold covered scaffold uses native locale before private fields are authorized',async()=>{
  const presentation={locale:'zh-Hant',textScales:null};
  render(<LavaUIReview fullApp initialPresentation={presentation}/>);
  expectStarting();
  expect(screen.getByTestId('native-route.Guard',{includeHiddenElements:true}).props.nativeTitle).toBe('防護');
  expect(mockCommand).not.toHaveBeenCalled();
  const current={...JSON.parse(snapshot(2,true)),presentation};
  await act(async()=>reads.at(-1)!.resolve(JSON.stringify(current)));
  expect(screen.getByTestId('native-route.Guard').props.nativeTitle).toBe('防護');
  expect(mockBodyMount).toHaveBeenCalledTimes(1);
  expect(mockBodyUnmount).not.toHaveBeenCalled();
});

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
  expect(mockNavigationMount).toHaveBeenCalledTimes(1);
  expect(mockBodyMount).toHaveBeenCalledTimes(1);
  expect(mockCommand).not.toHaveBeenCalled();
  emitState('active');
  expectStarting();
  expect(mockCommand).not.toHaveBeenCalled();
  await act(async()=>reads.at(-1)!.resolve(snapshot(2,false)));
  expect(screen.queryByLabelText('Loading Lava')).toBeNull();
  expect(screen.queryByTestId('lava-privacy-cover')).toBeNull();
  expect(screen.getByText('Native private value 2')).toBeTruthy();
  expect(mockBodyMount).toHaveBeenCalledTimes(1);
  expect(mockBodyUnmount).not.toHaveBeenCalled();
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
  expect(screen.getByText('Lava Security')).toBeTruthy();
  expect(screen.getByLabelText('Retry runtime')).toBeTruthy();
  expect(screen.UNSAFE_queryAllByType(ActivityIndicator)).toHaveLength(0);
  expect(screen.queryByTestId('private-route-body')).toBeNull();
  expect(screen.getByTestId('private-route-body',{includeHiddenElements:true})).toBeTruthy();
  await act(async()=>reads.at(-1)!.resolve(snapshot(2,false)));
  expect(screen.getByText('Native private value 2')).toBeTruthy();
});

test('turning off the last security choice retires a pending protected hydration cover immediately',async()=>{
  mockHydrationQueryCount=1;queryReads();
  render(<LavaUIReview fullApp initialSnapshot={snapshot(1,true)}/>);
  await act(async()=>{});
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
  expect(mockNavigationMount).toHaveBeenCalledTimes(1);
  emitState('active');
  await act(async()=>reads.at(-1)!.resolve(snapshot(2)));
  expect(screen.queryByLabelText('Loading Lava')).toBeNull();
  expect(screen.getByText('Native private value 2')).toBeTruthy();
  expect(mockBodyMount).toHaveBeenCalledTimes(1);
  expect(mockBodyUnmount).not.toHaveBeenCalled();
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
