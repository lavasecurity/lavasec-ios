import {OnboardingSurface} from './OnboardingSurface';
import type {PlusReason} from './plus-intents';
import {Alert, localized, configurePresentation, PresentationContext, type Presentation} from '../app/presentation';
import {useEffect, useLayoutEffect, useRef, useState, useSyncExternalStore, type ComponentType} from 'react';
import {AppState, View, useColorScheme} from 'react-native';
import {DarkTheme, DefaultTheme, NavigationContainer, createNavigationContainerRef, usePreventRemove} from '@react-navigation/native';
import {createNativeStackNavigator} from '@react-navigation/native-stack';
import {createNativeBottomTabNavigator} from '@react-navigation/bottom-tabs/unstable';
import {SafeAreaProvider} from 'react-native-safe-area-context';
import NativeAppearance from '../specs/NativeLavaAppearance';
import NativeReview from '../specs/NativeLavaReview';
import NativeApp from '../specs/NativeLavaApp';
import {AppStore} from '../app/store';
import {NavigationTurn, nativeRedirectAction,nativeRedirectMatches} from '../app/navigation-turn';
import type {AppCommand, AppSnapshot} from '../app/contract';
import {mayInteractWithPresentation} from '../app/read-cache';
import {AppearanceStore} from './appearance-store';
import {ReviewContext, useReview, LiveRenderBoundary, usePreviewFixtureState} from './ReviewContext';
import {protectedActionNames} from './session';
import {fullScreenModalPresentation, fullSheetPresentation, nativeInlineHeader,toolbarButton,nativeFlowHeader} from './scaffold';
import {floatingTabMinimizeBehavior,ordinaryPageHeader,useOrdinaryPushPresentation} from './navigation-scaffold';
import {PresentationContent,PresentationCover} from './PresentationCover';
import {lavaTokens} from '../src/generated/tokens';
import {LavaAppearanceContext, useLavaColorScheme} from '../src/appearance';
import * as Screens from './screens';
import {ForegroundFlowScreen} from './ForegroundFlowScreen';
import {CustomEntryRoute} from './CustomEntryScreen';
import {FilterRoute} from './FilterRoute';

// Keep the pinned experimental native tab API at this single iOS boundary. It
// creates UITabBarController; a future Android implementation owns its mapping.
const Tabs = createNativeBottomTabNavigator();
const Stack = createNativeStackNavigator<Screens.ReviewRoutes>();

const destinations = [
  ['Filters', Screens.FiltersScreen, 'Filters'], ['Activity', Screens.ActivityScreen, 'Activity'],
  ['Explore', Screens.ExploreScreen, 'Explore'],
  ['Library', Screens.LibraryScreen, 'Your filters'], ['Filter', Screens.FilterScreen, 'Example filter'],
  ['Review', Screens.ReviewScreen, 'Review'], ['Share', Screens.ShareScreen, 'Choose a filter to share'],
  ['Import', Screens.ImportScreen, 'Import a filter'], ['TopDomains', Screens.DomainListScreen, 'Top Domains'],
  ['History', History, 'Domain History'], ['Customization', Screens.CustomizationScreen, 'Customization'],
  ['Guardian', Screens.GuardianScreen, 'Lava Guard'], ['Account', Screens.AccountScreen, 'Account & Backup'],
  ['Upgrade', Screens.UpgradeScreen, 'Lava Plus'], ['DNS', Screens.DNSScreen, 'DNS settings'], ['DNSPicker', Screens.DNSPickerScreen, 'Choose DNS'], ['CustomEntry', Screens.CustomEntryScreen, 'Custom DNS'],
  ['DNSPatch', Screens.DNSPatchScreen, 'DNS patch for iOS 27'],
  ['Privacy', Screens.PrivacyScreen, 'Privacy & Data'], ['Security', Screens.SecurityScreen, 'Security'],
  ['Feedback', Screens.FeedbackSettingsScreen, 'Feedback'], ['Legal', Screens.LegalScreen, 'Legal Notices'],
  ['Stats', Screens.StatsScreen, 'Nerd Stats'], ['Network', Screens.NetworkScreen, 'Network Activity'],
  ['ShareDetail', Screens.ShareDetailScreen, 'Share my filter'], ['Passcode', Screens.PasscodeScreen, 'Passcode'],
  ['AddDomain', Screens.AddDomainScreen, 'Add Blocked Domain'], ['AddBlocklist', Screens.AddBlocklistScreen, 'Add a blocklist'],
  ['VPNChaining', Screens.VPNChainingScreen, 'VPN chaining'],
  ['DeviceQA', Screens.DeviceQAScreen, 'Device QA'],
  ['AutoSwitch', Screens.AutoSwitchScreen, 'Auto-switch filters'],
  ['Components', Screens.ComponentsScreen, 'Design system'],
  ['Sudoku', Screens.SudokuScreen, 'Sudoku'],
] as const;
function History() { return <Screens.DomainListScreen history />; }
// These component identities are stable for the life of the native navigator.
// Revocation replaces only the private body inside its owning native route.
const privateRoute=(component:ComponentType,retireOnPolicyChange=true,prepareScaffold=false)=>function PrivateRoute(){
  const {app}=useReview();
  const interactive=useSyncExternalStore(app?.subscribe??noSubscribe,()=>mayInteractWithPresentation(app));
  // The native stack owns Back and dismissal gestures outside our RN pointer
  // fence. Keep its route mounted while the view has display-only authority.
  usePreventRemove(!!app&&!interactive,()=>{});
  return <LiveRenderBoundary component={component} retainBody directScrollRoot retireOnPolicyChange={retireOnPolicyChange} prepareScaffold={prepareScaffold}/>;
};
// Guard has no private query/preparation effect. Its empty layout can mount under the native lock.
const GuardRoute=privateRoute(Screens.GuardScreen,true,true),SettingsRoute=privateRoute(Screens.SettingsScreen,false),PlusRoute=privateRoute(Screens.UpgradeScreen);
function ForegroundRoute(){
  const {app}=useReview();
  const interactive=useSyncExternalStore(app?.subscribe??noSubscribe,()=>mayInteractWithPresentation(app));
  usePreventRemove(!!app&&!interactive,()=>{});
  // Native modal/privacy owners conceal this body without discarding its
  // unfinished form. The root's cover remains above the retained React surface.
  return <ForegroundFlowScreen/>;
}
// Explore keeps its same-visit inspection/scroll identity beneath the opaque
// privacy cover. Fresh native fields still gate the visible body and every
// settings destination; owner or security-policy replacement retires that visit.
const routeDestinations=destinations.map(([name,component,title])=>[name,name==='CustomEntry'?CustomEntryRoute:name==='Filter'?FilterRoute:privateRoute(component,name!=='Security'&&name!=='Privacy'),title] as const);
function RootStack({root}: {root: 'Guard' | 'Settings'}) {
  const {app,live,reviewGallery} = useReview();
  const interactive=useSyncExternalStore(app?.subscribe??noSubscribe,()=>mayInteractWithPresentation(app));
  const qaTools=useRef(false);
  if(live)qaTools.current=live.qaTools;
  const pushPresentation=useOrdinaryPushPresentation();
  const sheets = new Set(['Guardian','Review','Import','ShareDetail','AddDomain','AddBlocklist','DNSPicker']);
  // Header colors and the native navigation theme share the resolved app
  // preference, including while UIKit is transitioning between controllers.
  const scheme = useLavaColorScheme();
  const rgb = (color: readonly number[]) => `rgb(${color.map(value => Math.round(value * 255)).join(',')})`;
  // Use headerLargeTitleEnabled, not the deprecated headerLargeTitle alias:
  // native-stack keys animated header-height handling on the supported option.
  // Inline pages need the same translucent layout as large-title pages. A clear
  // background color alone leaves their scroll content below the navigation bar.
  return <Stack.Navigator initialRouteName={root === 'Guard' && reviewGallery ? 'Components' : root}
    screenOptions={{statusBarHidden: false, statusBarStyle: scheme === 'dark' ? 'light' : 'dark', headerLargeTitleEnabled: true, headerShadowVisible: false,
    headerStyle: {backgroundColor: 'transparent'},
    ...ordinaryPageHeader(),
    headerBackButtonDisplayMode: 'minimal',
    ...(!interactive?{gestureEnabled:false}:{}),
    headerTintColor: rgb(lavaTokens.colors.navigationForeground[scheme]),
    headerTitleStyle: {color: rgb(lavaTokens.colors.ink[scheme])}, headerLargeTitleStyle: {color: rgb(lavaTokens.colors.ink[scheme])},
    contentStyle: {backgroundColor: rgb(lavaTokens.colors.groupedBackground[scheme])}}}>
    <Stack.Screen name={root} component={root === 'Guard' ? GuardRoute : SettingsRoute}
      options={{title: localized(root),headerShown:true}} />
    {routeDestinations.filter(([name])=>name==='VPNChaining'?!!app:name==='DeviceQA'?!!app&&qaTools.current:name==='Components'?!app||qaTools.current:!app||!['Import','Passcode','Feedback'].includes(name)).map(([name, component, title]) => <Stack.Screen key={name} name={name} component={component} options={({navigation,route}) => ({title:localized(title),headerBackVisible:true,
      ...(!sheets.has(name)&&name!=='Passcode'&&name!=='Sudoku'?pushPresentation:{}),
      ...(name === 'Components' && !app ? {unstable_headerRightItems:()=>[toolbarButton('Close','xmark',()=>NativeReview.close(),false,'review.close')]} : {}),
      headerLargeTitleEnabled: !['Filter', 'Guardian', 'Review', 'Import', 'ShareDetail', 'Passcode', 'AddDomain', 'AddBlocklist'].includes(name),
      ...(sheets.has(name) ? {...fullSheetPresentation,
        unstable_headerLeftItems: () => [toolbarButton('Close', 'xmark', () => {if(mayInteractWithPresentation(app))navigation.goBack();})], headerBackVisible: false} : {}),
      ...(name==='Passcode'?{...fullScreenModalPresentation,headerLargeTitleEnabled:false,
        unstable_headerLeftItems:()=>[toolbarButton('Close','xmark',()=>{if(mayInteractWithPresentation(app))navigation.goBack();})]}:{}),
      // Only embedded native pages need the inline override. VPN chaining uses
      // the same root ScrollView as DNS and inherits the ordinary large title.
      ...(['AutoSwitch','DNSPatch'].includes(name)?{headerLargeTitleEnabled:false}:{}),
      ...(name==='DeviceQA'?{headerShown:false}:{}),
      ...(name==='Feedback'?{gestureEnabled:false}:{}),
      // Sudoku keeps the native full-screen presentation while its shared rail
      // owns the controls in both orientations. Status-bar visibility is owned
      // by the screen's orientation: visible in portrait so the Dynamic Island
      // is not suppressed, hidden in landscape to keep the board height.
      ...(name==='Sudoku'?{...fullScreenModalPresentation,
        headerShown:false,title:''}:{}),
    })} />)}
  </Stack.Navigator>;
}
function GuardStack() { return <RootStack root="Guard" />; }
function SettingsStack() { return <RootStack root="Settings" />; }

export function LavaUIReview({activityExample = false, reviewGallery = false, fullApp = false, onboardingPreview = false, initialSnapshot, initialPresentation, plusContext,foregroundContext,presentationID}: {activityExample?: boolean; reviewGallery?: boolean; fullApp?: boolean; onboardingPreview?:boolean; initialSnapshot?: string;initialPresentation?:Presentation;presentationID?:string;plusContext?:PlusReason;foregroundContext?:string}) {
  const [app] = useState(() => fullApp && NativeApp ? new AppStore(NativeApp, initialSnapshot ? JSON.parse(initialSnapshot) as AppSnapshot : undefined,
    {initial:true}) : undefined);
  return <LavaPresentation presentationID={presentationID} initialPresentation={initialPresentation} app={app} onboardingPreview={onboardingPreview} fullApp={fullApp} activityExample={activityExample} reviewGallery={reviewGallery} plusContext={plusContext} foregroundContext={foregroundContext}/>;
}
const emptyLive = {snapshot: null, displaySnapshot:null, error: null,privacyCoverRequired:undefined};
const emptyHydration={epoch:0,required:false};
const noSubscribe = () => () => {};
function LavaPresentation({app, onboardingPreview, fullApp, activityExample, reviewGallery,plusContext,foregroundContext,presentationID,initialPresentation}: {initialPresentation?:Presentation;presentationID?:string;app?: AppStore; onboardingPreview:boolean; fullApp: boolean; activityExample: boolean; reviewGallery: boolean;plusContext?:PlusReason;foregroundContext?:string}) {
  const appState = useSyncExternalStore(app?.subscribe ?? noSubscribe, app?.getSnapshot ?? (() => emptyLive));
  const hydration=useSyncExternalStore(app?.subscribe??noSubscribe,app?.getPresentationHydration??(()=>emptyHydration));
  const live = appState.snapshot ?? appState.displaySnapshot ?? undefined;
  // Locale and type scales are public presentation metadata. Keep those alone
  // when native withholds private fields, so concealment cannot relayout the
  // retained scaffold with English/default text metrics.
  const presentation=useRef<Presentation>(initialPresentation??{locale:'en',textScales:null});
  if(live?.presentation)presentation.current=live.presentation;
  const displayOnly=!appState.snapshot&&!!live;
  const presentationPaused=displayOnly||hydration.required;
  const [nativeLayoutReady,setNativeLayoutReady]=useState(false);
  const [navigationReady,setNavigationReady]=useState(false);
  // Keep only this accepted all-off native editor's existing responder. Fabric
  // maps `none` to a disabled ancestor UIView; `box-only` instead consumes hits
  // at this inert frame without visiting any child. Native/JS action and AX
  // authority remain revoked until the current active projection returns.
  // The frame also keeps a native stacking context in every authority state.
  // Fabric otherwise reparents its descendants when AX/pointer fences change,
  // and UIKit resigns the confidential editor as its ancestor leaves the window.
  // pinned: runtime-presentation-lifecycle.test.tsx same-visit all-off WireGuard display
  const retainedWireGuardDisplay=displayOnly&&appState.privacyCoverRequired===false
    &&!!foregroundContext&&live?.foregroundFlow?.id===foregroundContext
    &&live.foregroundFlow.kind==='vpnConfiguration'&&live.foregroundFlow.vpnEditor?.concealed===false;
  const [navigation] = useState(() => createNavigationContainerRef());
  const lastNavigation = useRef(0);
  const pendingNavigation=useRef<{epoch:number;request:NonNullable<AppSnapshot['navigation']>;dispatched:boolean;ticket:ReturnType<AppStore['registerPresentationRead']>}|undefined>(undefined);
  const navigationTurn = useRef(new NavigationTurn());
  const settingsEntryPending = useRef(false);
  const acceptNativeNavigation=()=>{
    const pending=pendingNavigation.current,current=app?.getSnapshot().snapshot;
    const state=navigation.getRootState();
    if(!pending||!current||AppState.currentState!=='active'||app?.getPresentationHydration().epoch!==pending.epoch
      ||current.navigation?.serial!==pending.request.serial||!state||!nativeRedirectMatches(state,pending.request.tab,pending.request.screen))return;
    // Dispatch is not readiness. The new focused viewport/read hooks register
    // during its commit before this navigation handoff ticket can settle.
    lastNavigation.current=pending.request.serial;pendingNavigation.current=undefined;app?.settlePresentationRead(pending.ticket);
  };
  const navigateNativeRequest = () => {
    if(plusContext||foregroundContext||onboardingPreview||AppState.currentState!=='active'||!navigationReady)return;
    const request = app?.getSnapshot().snapshot?.navigation;
    if (!request || request.serial <= lastNavigation.current || !navigation.isReady()) return;
    const pending=pendingNavigation.current;
    if(!pending||pending.request.serial!==request.serial||pending.epoch!==app?.getPresentationHydration().epoch)return;
    const state=navigation.getRootState();
    if(!state)return;
    if(nativeRedirectMatches(state,request.tab,request.screen)){acceptNativeNavigation();return;}
    if(pending.dispatched)return;
    const action=nativeRedirectAction(state,request.tab,request.screen);
    if(!action){pendingNavigation.current=undefined;app?.settlePresentationRead(pending.ticket);return;}
    pending.dispatched=true;
    navigationTurn.current.markExternalRequest();
    navigation.dispatch(action);
  };
  useLayoutEffect(()=>{
    const request=appState.snapshot?.navigation;
    if(!app||!request||request.serial<=lastNavigation.current||plusContext||foregroundContext||onboardingPreview||AppState.currentState!=='active')return;
    const pending={epoch:hydration.epoch,request,dispatched:false,ticket:app.registerPresentationRead()};pendingNavigation.current=pending;
    return()=>{if(pendingNavigation.current===pending)pendingNavigation.current=undefined;app.settlePresentationRead(pending.ticket);};
  },[app,appState.snapshot?.navigation?.serial,!!appState.snapshot,hydration.epoch,plusContext,foregroundContext,onboardingPreview]);
  useLayoutEffect(navigateNativeRequest,[appState.snapshot?.navigation?.serial,!!appState.snapshot,navigationReady,hydration.epoch]);
  useLayoutEffect(()=>{
    if(appState.snapshot&&nativeLayoutReady&&navigationReady&&AppState.currentState==='active')app?.completePresentationLayout(hydration.epoch);
  },[app,!!appState.snapshot,hydration.epoch,nativeLayoutReady,navigationReady]);
  // This is the single frame handoff: focused layout/read readiness has already
  // committed, then React removes its cover before native reveals the surface.
  // A newer boundary cannot acknowledge this frame.
  useLayoutEffect(()=>{
    const token=app?.getPresentationToken();
    if(!app||!presentationID||!token||hydration.required&&!appState.error||!nativeLayoutReady||!navigationReady)return;
    const frame=requestAnimationFrame(()=>app.acknowledgePresentation(presentationID,token));
    return()=>cancelAnimationFrame(frame);
  },[app,presentationID,app?.getPresentationToken(),appState.error,hydration.required,nativeLayoutReady,navigationReady]);
  // Connect before descendant passive query effects run. Native fields may be
  // supplied synchronously on boot, but those fields alone do not own the port.
  useLayoutEffect(() => app?.connect(), [app]);
  const run = (command: AppCommand) => { if (app&&appState.snapshot&&!presentationPaused&&AppState.currentState==='active') void app.command(command).catch(error => Alert.alert('Lava', String(error.message ?? error))); };
  const recordNavigationTurn = () => {if(plusContext||foregroundContext||onboardingPreview||presentationPaused||app&&!appState.snapshot||AppState.currentState!=='active')return;const state=navigation.getRootState();if(state&&navigationTurn.current.advance(state))run({type:'navigation.endTurn'});};

  const [appearance] = useState(() => new AppearanceStore(NativeAppearance));
  const [fixtureLook, setFixtureLook] = useState('original');
  const {draft:fixtureDraft,savedDraft:fixtureSavedDraft,session:fixtureSession,setDraft:setFixtureDraft,setSavedDraft,setSession:setFixtureSession}=usePreviewFixtureState(!fullApp);
  const look = live?.look ?? fixtureLook;
  const draft = live?.draft ?? fixtureDraft;
  const savedDraft = live?.savedDraft ?? fixtureSavedDraft;
  const session = live ? {...fixtureSession, ...live.session, sudoku: live.sudoku} : fixtureSession;
  const setLook = (value: string) => app ? run({type: 'settings.set', key: 'look', value}) : setFixtureLook(value);
  const setDraft = setFixtureDraft;
  const setSession = (value: typeof session) => {
    if (!app) {setFixtureSession(value); return;}
    if (!live||!appState.snapshot||presentationPaused||AppState.currentState!=='active') return;
    const pending: Promise<unknown>[]=[];
    const run=(command:AppCommand)=>{pending.push(app.command(command));};
    // Native settings are individual commands. Sharing carries only its route ID;
    // never retain native filter names or a copied session in preview fixture state.
    if (value.filter !== session.filter) {
      const filter = live.filters.find(item => item.name === value.filter);
      if (filter) run({type: 'filter.open', id: filter.id});
    }
    if (value.editing !== session.editing) run({type: value.editing ? 'filter.edit' : 'filter.cancel', id: live.session.filterID});
    if (value.blocklists.join('|') !== session.blocklists.join('|')) run({type: 'filter.lists', id: live.session.filterID, ids: value.blocklists});
    for (const key of ['deviceDNS','fallback','provider','transport','matchTextSize','textSize','haptics','liveActivities','matchIcon','biometrics'] as const) {
      if (value[key] !== session[key]) run({type: 'settings.set', key, value: value[key]});
    }
    for (const group of ['logs','notifications'] as const) for (const [key, enabled] of Object.entries(value[group])) {
      if (enabled !== session[group][key]) run({type: 'settings.set', key: `${group}.${key}`, value: enabled});
    }
    for (const key of protectedActionNames) {
      if (value.protectedActions[key] !== session.protectedActions[key]) run({type:'settings.set',key:`protectedActions.${key}`,value:value.protectedActions[key]});
    }
    if (value.sudoku && value.sudoku !== session.sudoku) run({type: 'sudoku.save', game: value.sudoku});
    return Promise.all(pending).then(()=>{},error=>{if(error.message!=='Authentication cancelled.')Alert.alert('Lava',error.message);});
  };
  const {snapshot} = useSyncExternalStore(appearance.subscribe, appearance.getSnapshot);
  const systemScheme = useColorScheme();
  const dark = snapshot?.preference === 'dark' || (snapshot?.preference !== 'light' && systemScheme === 'dark');
  useEffect(() => {
    const disconnect = appearance.connect();
    // AppStore owns the app's foreground refresh. Appearance has its own port.
    const foreground = AppState.addEventListener('change', state => { if (state === 'active') void appearance.refresh(); });
    return () => { foreground.remove(); disconnect(); };
  }, [appearance, app]);
  const base = dark ? DarkTheme : DefaultTheme;
  const green = lavaTokens.colors.safeGreen[dark ? 'dark' : 'light'];
  const background = lavaTokens.colors.groupedBackground[dark ? 'dark' : 'light'];
  const rgb = (color: readonly number[]) => `rgb(${color.map(value => Math.round(value * 255)).join(',')})`;
  configurePresentation(presentation.current);
  // Missing policy conceals by default. Confirmed all-off keeps its already
  // painted frame through resume refresh; revoked authority still prevents input.
  // Loading/readiness alone never selects a cover. Native's explicit all-off
  // policy keeps the ordinary frame; protected or unknown policy conceals.
  const unavailable = <RuntimeUnavailable concealed={appState.privacyCoverRequired!==false} background={rgb(background)}
    error={appState.error ?? (!app ? 'The full Lava runtime is missing from this installation.' : null)} retry={() => void app?.refresh()} />;
  return <ReviewContext.Provider value={{app, live, onboardingPreview, appearance, look, setLook, draft, setDraft, savedDraft, setSavedDraft, session, setSession, activityExample, reviewGallery}}>
    <LavaAppearanceContext.Provider value={dark?'dark':'light'}><PresentationContext.Provider value={presentation.current}><SafeAreaProvider><View style={{flex:1}}><View testID="lava-render-frame" collapsable={false} onLayout={event=>{if(event.nativeEvent.layout.width>0&&event.nativeEvent.layout.height>0)setNativeLayoutReady(true);}} style={{flex:1}} pointerEvents={presentationPaused?(retainedWireGuardDisplay?'box-only':'none'):'auto'} accessibilityElementsHidden={fullApp&&(!live||presentationPaused)} importantForAccessibility={fullApp&&(!live||presentationPaused)?'no-hide-descendants':'auto'}><OnboardingSurface enabled={fullApp&&!foregroundContext&&!plusContext}><NavigationContainer ref={navigation} onReady={()=>{setNavigationReady(true);recordNavigationTurn();}} onStateChange={()=>{acceptNativeNavigation();recordNavigationTurn();navigateNativeRequest();}} theme={{...base, colors: {...base.colors, primary: rgb(green), background: rgb(background), card: rgb(background)}}}>
      {foregroundContext?<Stack.Navigator screenOptions={{...nativeFlowHeader(dark),headerBackVisible:false}}><Stack.Screen name="Foreground" component={ForegroundRoute} initialParams={{id:foregroundContext}}/></Stack.Navigator>:plusContext?<Stack.Navigator screenOptions={{headerShown:false}}><Stack.Screen name="Upgrade" component={PlusRoute} initialParams={{reason:plusContext,embedded:true} as Screens.ReviewRoutes['Upgrade']}/></Stack.Navigator>:<Tabs.Navigator screenOptions={({route}) => ({headerShown: false, tabBarActiveTintColor: rgb(green),
        tabBarMinimizeBehavior: floatingTabMinimizeBehavior(),
        // Setup retains its Guard destination, while that owner's navigation
        // stays hidden. A separate mock preview cannot hide the real app's bar.
        tabBarStyle: live?.onboardingSetup?.mock===onboardingPreview?{display:'none'}:undefined,
        // Native tabs have input authority only with an active projection. A
        // protected Settings entry additionally waits for native authentication.
        tabBarSelectionEnabled: !(app&&(!appState.snapshot||presentationPaused||AppState.currentState!=='active'))
          &&!(app && route.name === 'SettingsTab' && session.protectedActions['Update App Settings']),
      })}>
        <Tabs.Screen name="GuardTab" component={GuardStack} options={{title: localized('Guard'), tabBarIcon: ({focused}) => ({type: 'sfSymbol', name: 'shield.fill'})}} />
        <Tabs.Screen name="SettingsTab" component={SettingsStack} options={{title: localized('Settings'), tabBarIcon: () => ({type: 'sfSymbol', name: 'gearshape.fill'})}}
          listeners={({navigation:tabNavigation}) => ({tabPress: () => {
            if(AppState.currentState!=='active'||presentationPaused||app&&!appState.snapshot)return;
            const state=navigation.getRootState();
            if(!state)return;
            if(state.routes[state.index]?.name==='SettingsTab'){
              // A bounded native page owns an inner navigation controller.
              // Pop its RN route too, so reselection cannot strand the child.
              const child=state.routes[state.index]?.state;
              if((child?.index??0)>0&&child?.key)tabNavigation.dispatch({type:'POP_TO_TOP',target:child.key});
              return;
            }
            if(!app||!session.protectedActions['Update App Settings']||settingsEntryPending.current)return;
            settingsEntryPending.current=true;
            const origin=tabNavigation.getState().routes[tabNavigation.getState().index]?.key;
            void app.command({type:'navigation.authorize',surface:'appSettings',newTurn:true})
              .then(() => {if(AppState.currentState==='active'&&app.getSnapshot().snapshot&&!app.getPresentationHydration().required&&tabNavigation.getState().routes[tabNavigation.getState().index]?.key===origin){navigationTurn.current.markExternalRequest();tabNavigation.navigate('SettingsTab');}})
              .catch(error => {if(error.message!=='Authentication cancelled.')Alert.alert('Lava', error.message);})
              .finally(()=>{settingsEntryPending.current=false;});
          }})} />
      </Tabs.Navigator>}
    </NavigationContainer></OnboardingSurface></View>{fullApp&&(!live||hydration.required&&appState.privacyCoverRequired!==false)&&<View style={{position:'absolute',top:0,bottom:0,left:0,right:0}}>{unavailable}</View>}</View></SafeAreaProvider></PresentationContext.Provider></LavaAppearanceContext.Provider>
  </ReviewContext.Provider>;
}

function RuntimeUnavailable({concealed,background,error,retry}: {concealed:boolean;background:string;error:string|null;retry:()=>void}) {
  const failure=error&&AppState.currentState==='active'?<Screens.RuntimeError message={error} retry={retry}/>:null;
  return concealed?<PresentationCover background={background}>{failure}</PresentationCover>
    :<View style={{flex:1,backgroundColor:background}}><PresentationContent testID="lava-runtime-content">{failure??<Screens.RuntimeError message="Lava Security" retry={retry}/>}</PresentationContent></View>;
}
