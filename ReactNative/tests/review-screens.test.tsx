import {VPNChainingScreen} from '../review/NativePageScreen';
import {usePreventRemove} from '@react-navigation/native';
import {LegalScreen} from '../review/DiagnosticScreens';
import {clearAppReadCache} from '../app/read-cache';
import NativeSwitch from '../specs/LavaSwitchNativeComponent';
import {useEffect, useState, type PropsWithChildren} from 'react';
import {AccessibilityInfo, Alert, AppState, Linking, ScrollView, Switch} from 'react-native';
import {act, fireEvent, render, screen, waitFor} from '@testing-library/react-native';
import {AddDomainScreen, AddBlocklistScreen, FilterScreen, ReviewScreen, ActivityScreen, NetworkScreen, AccountScreen, SecurityScreen, DNSScreen, DNSPickerScreen, StatsScreen, DomainListScreen, FeedbackScreen, GuardScreen, FiltersScreen, UpgradeScreen, PrivacyScreen, LibraryScreen, ShareScreen, ShareDetailScreen, SettingsScreen, CustomizationScreen, ExploreScreen} from '../review/screens';
import {configurePresentation, localized, localizedFormat} from '../app/presentation';
import {ListRow, Toggle} from '../review/scaffold';
import {Choice} from '../review/primitives';
import {LavaActionButton,LavaSelectionAccessory} from '../src';
import {colors,colorForScheme} from '../src/colors.ios';
import {ReviewContext} from '../review/ReviewContext';
import {initialSession} from '../review/session';
import {AppearanceStore} from '../review/appearance-store';
import {addPreviewDomain, initialPreviewDraft, previewDiff} from '../review/preview-model';
import type {AppCommand, AppSnapshot} from '../app/contract';
import {useDNSEditor} from '../review/dns-editor';
import type {AppStore} from '../app/store';

const expectedNumber = new Intl.NumberFormat();
const backupEnablement=(value:boolean|null,signedIn=true,overrides:Partial<NonNullable<AppSnapshot['backup']['enablement']>>={})=>({
  state:value===null?'unavailable' as const:value?'on' as const:'off' as const,value,
  canEnable:signedIn&&value===false,canDisable:signedIn&&value===true,
  canBackUp:signedIn&&value===true,canRestore:signedIn&&value!==null,
  canChangeAutomatic:signedIn&&value===true,canRetryDeletion:false,...overrides,
});

test('the shared switch holds one pending tap and rolls back to the authoritative value after rejection',async()=>{
  let reject!:(error:Error)=>void;
  const onChange=jest.fn(()=>new Promise<void>((_resolve,no)=>{reject=no;}));
  render(<Toggle title="App Haptics" value={false} onChange={onChange}/>);
  const control=()=>screen.UNSAFE_getByType(Switch);
  const change=control().props.onValueChange;
  act(()=>{change(true);change(false);});
  expect(onChange).toHaveBeenCalledTimes(1);
  expect(control().props.value).toBe(true);
  expect(control().props.pointerEvents).toBe('none');
  await act(async()=>reject(new Error('Authentication cancelled.')));
  expect(control().props.value).toBe(false);
  expect(control().props.pointerEvents).toBe('auto');
  fireEvent(control(),'valueChange',true);
  expect(onChange).toHaveBeenCalledTimes(2);
  await act(async()=>reject(new Error('Authentication cancelled.')));
});
const mockNavigate = jest.fn();
const mockGoBack = jest.fn();
const mockDispatch = jest.fn();
const mockNormalizeDomain = jest.fn();
const mockChooseFilterAction=jest.fn().mockResolvedValue(null);
const mockLegalNotices = jest.fn();
const mockSetOptions = jest.fn();
// The domain search belongs to the navigation item, so these tests drive the
// recorded headerSearchBarOptions handler instead of an in-content input.
const nativeDomainSearch=()=>[...mockSetOptions.mock.calls].reverse().find(([options])=>options.headerSearchBarOptions)![0].headerSearchBarOptions;
let mockShareFilterID: string|undefined;
let mockStandaloneReview: string|undefined;
let mockDomainDecision: 'blocked'|'allowed' = 'blocked';
const mockGetState=jest.fn();
let mockFocused=true;
let mockParentFocused=true;
let mockExploreParams:Record<string,unknown>={};
const mockNavigationListeners=new Map<string,Set<()=>void>>();
const mockListen=(name:string,listener:()=>void)=>{const set=mockNavigationListeners.get(name)??new Set();set.add(listener);mockNavigationListeners.set(name,set);return()=>set.delete(listener);};
const mockParentNavigation={isFocused:()=>mockParentFocused,getParent:()=>undefined,addListener:(event:string,listener:()=>void)=>mockListen(`parent.${event}`,listener)};
const mockNavigation = {dispatch:mockDispatch,navigate:mockNavigate,goBack:mockGoBack,setOptions:mockSetOptions,getState:mockGetState,getParent:()=>mockParentNavigation,addListener:(event:string,listener:()=>void)=>mockListen(event,listener)};
beforeEach(()=>{mockChooseFilterAction.mockReset().mockResolvedValue(null);mockDispatch.mockClear();jest.mocked(usePreventRemove).mockClear();mockNavigate.mockClear();mockGoBack.mockClear();mockSetOptions.mockClear();mockGetState.mockReset();mockNavigationListeners.clear();mockFocused=true;mockParentFocused=true;mockExploreParams={};});
const todayRange = {start: 1000, end: 1000, label: 'Today', includesToday: true};
const mockGetActivityDates = jest.fn().mockResolvedValue(todayRange);
const mockPickActivityDates = jest.fn();
const mockGetActivityDatePreset=jest.fn(async(preset:string)=>preset==='today'?todayRange:{start:preset==='week'?10:preset==='fortnight'?-13:1,end:1000,label:preset==='week'?'Sep 7–13':'Sep 1–13',includesToday:true});
// The native-stack footer is outside the screen's React subtree. The component
// tests mount the same footer node here; simulator tests cover native placement.
jest.mock('../review/scaffold', () => ({...jest.requireActual('../review/scaffold'), Sheet: ({children,header,footer}: PropsWithChildren<{header?: React.ReactNode;footer?: React.ReactNode}>) => <>{header}{children}{footer}</>}));
jest.mock('../specs/LavaSliderNativeComponent', () => ({__esModule:true,default:require('react-native').View}));
jest.mock('../specs/LavaChoiceNativeComponent', () => require('./native-choice-mock'));
jest.mock('../specs/NativeLavaReview', () => ({__esModule: true, default: {chooseFilterAction:(...args:unknown[])=>mockChooseFilterAction(...args),stopDemo:jest.fn(),speakDemo:jest.fn().mockResolvedValue(false),getLegalNotices:()=>mockLegalNotices(), normalizeDomain: (input: string) => mockNormalizeDomain(input), close: jest.fn(), getGuardAccents:()=>JSON.stringify({original:{light:'#BF4000',dark:'#FF8855'},aquamarine:{light:'#227B89',dark:'#6FD2DF'}}), getActivityDates: () => mockGetActivityDates(), getActivityDatePreset:(preset:string)=>mockGetActivityDatePreset(preset), pickActivityDates: (start: number, end: number) => mockPickActivityDates(start, end)}}));
jest.mock('react-native-safe-area-context',()=>({SafeAreaProvider:require('react-native').View,SafeAreaView:require('react-native').View,useSafeAreaInsets:()=>({top:59,bottom:34,left:0,right:0})}));
jest.mock('@react-navigation/native', () => ({usePreventRemove:jest.fn(),useNavigation: () => mockNavigation, useRoute: () => ({key:'source-route',params:{decision:mockDomainDecision,id:mockShareFilterID,standaloneReview:mockStandaloneReview,...mockExploreParams}}), useScrollToTop: jest.fn(), useIsFocused:()=>mockFocused}));
jest.mock('../specs/LavaDecorationNativeComponent', () => ({__esModule: true, default: require('react-native').View}));
jest.mock('../specs/LavaTextFieldNativeComponent', () => {
  const {TextInput} = require('react-native');
  return {__esModule: true, default: (props: {inputLabel: string; onChange: (event: {nativeEvent: {text: string}}) => void; onSubmit: (event: {nativeEvent: {text: string}}) => void}) =>
    <TextInput accessibilityLabel={props.inputLabel} onChangeText={(text: string) => props.onChange({nativeEvent: {text}})} onSubmitEditing={props.onSubmit} />};
});

function Provider({children, example = false, live, app}: PropsWithChildren<{example?: boolean;live?:AppSnapshot;app?:AppStore}>) {
  useEffect(()=>()=>{if(app)clearAppReadCache(app);},[app]);
  const [draft, setDraft] = useState(initialPreviewDraft);
  const [savedDraft,setSavedDraft] = useState(initialPreviewDraft);
  const [session,setSession] = useState(initialSession);
  const [appearance] = useState(() => new AppearanceStore({getSnapshot: async () => ({preference: 'system', revision: 0}),
    setPreference: async preference => ({preference, revision: 1}), onSnapshot: () => ({remove() {}})}));
  return <ReviewContext.Provider value={{app, live, draft:live?.draft??draft, setDraft, savedDraft:live?.savedDraft??savedDraft, setSavedDraft, session:{...session,...live?.session}, setSession, appearance, activityExample: example, look: 'original', setLook() {}}}>{children}</ReviewContext.Provider>;
}

test.each(['sleeping','waking','awake','paused','retrying','concerned','grateful'])('Guard acknowledges a tap in the %s expression without replacing its protection state',async mood=>{
  jest.useFakeTimers();
  const previousState=AppState.currentState;AppState.currentState='active';
  const command=jest.fn().mockResolvedValue(null);
  const app={command} as unknown as AppStore;
  const live={protection:{rules:12,title:'Protection',subtitle:'Current protection state',action:'Turn on',mood}} as unknown as AppSnapshot;
  try {
    render(<Provider live={live} app={app}><GuardScreen/></Provider>);
    await act(async()=>{});
    const mascot=screen.getByTestId('guard.mascot.gesture',{includeHiddenElements:true});
    fireEvent(mascot,'guardianGesture',{nativeEvent:{gesture:'tap'}});
    expect(command.mock.calls.filter(([value])=>value.type==='haptic')).toEqual([
      [{type:'haptic',kind:'acknowledged',controlID:'mascot.tap',value:undefined}],
    ]);
    expect(mascot).toHaveProp('mood',mood==='awake'?'grateful':mood);
    act(()=>jest.advanceTimersByTime(1300));
    expect(mascot).toHaveProp('mood',mood);
  } finally {AppState.currentState=previousState;jest.useRealTimers();}
});

test('Guard mascot gratitude and holds retain the page without issuing scroll commands',async()=>{
  jest.useFakeTimers();
  const previousState=AppState.currentState;AppState.currentState='active';
  const scrollTo=jest.spyOn(ScrollView.prototype,'scrollTo');
  const scrollToEnd=jest.spyOn(ScrollView.prototype,'scrollToEnd');
  const setNativeProps=jest.spyOn(ScrollView.prototype,'setNativeProps');
  const live={protection:{rules:12,title:'Protected',subtitle:'Your protection is on.',
    action:'Turn off',mood:'awake',materialIntent:'affirmed'}} as unknown as AppSnapshot;
  try {
    render(<Provider live={live}><GuardScreen/></Provider>);
    await act(async()=>{});
    const page=screen.getByTestId('screen.scroll');
    const mascot=screen.getByTestId('guard.mascot.gesture',{includeHiddenElements:true});
    scrollTo.mockClear();scrollToEnd.mockClear();setNativeProps.mockClear();
    fireEvent(mascot,'guardianGesture',{nativeEvent:{gesture:'start'}});
    fireEvent(mascot,'guardianGesture',{nativeEvent:{gesture:'tap'}});
    fireEvent(mascot,'guardianGesture',{nativeEvent:{gesture:'end'}});
    expect(mascot).toHaveProp('mood','grateful');
    act(()=>jest.advanceTimersByTime(1300));
    expect(mascot).toHaveProp('mood','awake');
    fireEvent(mascot,'guardianGesture',{nativeEvent:{gesture:'start'}});
    fireEvent(mascot,'guardianGesture',{nativeEvent:{gesture:'end'}});
    expect(screen.getByTestId('screen.scroll')).toBe(page);
    expect(scrollTo).not.toHaveBeenCalled();
    expect(scrollToEnd).not.toHaveBeenCalled();
    expect(setNativeProps).not.toHaveBeenCalled();
  } finally {scrollTo.mockRestore();scrollToEnd.mockRestore();setNativeProps.mockRestore();AppState.currentState=previousState;jest.useRealTimers();}
});

test.each([
  'Protected. Reconnect to retry VPN chaining.',
  'Allow Lava to add a VPN configuration.',
  'Establishing secure connection…',
  'Add a WireGuard configuration in VPN chaining, or turn VPN chaining off.',
])('Guard presents %s once above the action', detail => {
  const live={protection:{rules:12,title:'Protection Off',subtitle:detail,
    action:'Turn on',mood:'sleeping',message:'Retired below-button message'}} as unknown as AppSnapshot;
  const result=render(<Provider live={live}><GuardScreen /></Provider>);
  expect(screen.getAllByText(detail)).toHaveLength(1);
  expect(screen.queryByText('Retired below-button message')).toBeNull();
  expect(screen.getByLabelText('Protection status').props.accessibilityValue.text).toContain(detail);
  const tree=JSON.stringify(result.toJSON());
  expect(tree.indexOf(detail)).toBeLessThan(tree.indexOf('"accessibilityLabel":"Turn on"'));
});

test.each(['en','zh-Hant'])('Guard verification stays neutral with a localized quiet action in %s',locale=>{
  configurePresentation({locale,textScales:null});
  try {
    const live={protection:{rules:12,title:'Checking VPN',
      subtitle:'Waiting for traffic to confirm VPN forwarding.',materialIntent:'unknown',
      actionTone:'quiet',action:'Turn off',mood:'waking'}} as unknown as AppSnapshot;
    render(<Provider live={live}><GuardScreen /></Provider>);
    expect(screen.getByText(localized('Checking VPN'))).toBeOnTheScreen();
    expect(screen.getByTestId('guard.material')).toHaveStyle({borderColor:'transparent'});
    expect(screen.getByRole('button',{name:localized('Turn off')})).toHaveStyle({backgroundColor:colors.quietControl});
    expect(screen.queryByText(localized('VPN setup ready'))).toBeNull();
    if(locale==='zh-Hant')expect(localized('Turn off')).not.toBe('Turn off');
  } finally {configurePresentation();}
});

test('chained forwarding failure uses the neutral Guard material and orange retry action',()=>{
  const detail='Protected. Reconnect to retry VPN chaining.';
  const live={protection:{rules:12,title:'VPN forwarding stopped',subtitle:detail,
    materialIntent:'recovery',actionTone:'recovery',action:'Reconnect',mood:'concerned'}} as unknown as AppSnapshot;
  const result=render(<Provider live={live}><GuardScreen /></Provider>);
  expect(screen.getByTestId('guard.material')).toBeOnTheScreen();
  expect(screen.getByRole('button',{name:'Reconnect'})).toHaveStyle({backgroundColor:colors.lavaOrangeSelectedFill});
  expect(screen.getByText(detail)).toHaveStyle({color:colors.secondaryText});
  expect(JSON.stringify(result.toJSON())).not.toContain('exclamationmark.triangle.fill');
});

test('Slow DNS offers the authenticated provider settings route',()=>{
  const live={protection:{rules:12,title:'DNS is slow',subtitle:'Reconnect or change your DNS provider.',
    action:'Reconnect',mood:'concerned',needsDNSProviderChange:true}} as unknown as AppSnapshot;
  render(<Provider live={live}><GuardScreen /></Provider>);
  fireEvent.press(screen.getByRole('link',{name:'Change DNS provider'}));
  expect(mockNavigate).toHaveBeenCalledWith('DNS');
});

test('Guard configuration recovery navigates to the native VPN page',()=>{
  const live={protection:{rules:12,title:'Protection Off',subtitle:'Configuration needed',
    action:'Turn on',mood:'sleeping',needsVPNSetup:true}} as AppSnapshot;
  render(<Provider live={live}><GuardScreen /></Provider>);
  fireEvent.press(screen.getByRole('link',{name:'Review VPN chaining'}));
  expect(mockNavigate).toHaveBeenCalledWith('VPNChaining');
});

test.each([['de','1.234 Regeln'],['ja','1,234 件のルール']])('Guard rules summary uses the native %s format in text and accessibility', (locale,expected) => {
  configurePresentation({locale,textScales:null});
  try {
    const live={session:{activeFilterID:'personal'},filters:[{id:'personal',name:'Personal',count:locale==='de'?'1.234':'1,234'}],protection:{rules:99999,title:'Protection Off',subtitle:'Tap once to add local protection',action:'Turn on',mood:'sleeping'}} as unknown as AppSnapshot;
    render(<Provider live={live}><GuardScreen /></Provider>);
    expect(screen.getByText(expected)).toBeOnTheScreen();
    expect(screen.getByTestId('guard.filter')).toHaveProp('accessibilityLabel',`${localized('Now filtering')}, 🌿 Personal, ${expected}`);
    const status=screen.getByLabelText(localized('Protection status'));
    expect(status).toHaveAccessibilityValue({text:`${localized('Protection Off')}. ${localized('Tap once to add local protection')}`});
    expect(status.props.accessibilityActions).toEqual([{name:'playSudoku',label:localized('Play Sudoku')},{name:'changeGuardian',label:localized('Change Lava Guard')}]);
  } finally {configurePresentation();}
});
test('catalog object formats support positional arguments and literal percent signs',()=>{
  expect(localizedFormat('%2$@ / %1$@ / %%','first','second')).toBe('second / first / %');
  expect(localizedFormat('%2$d / %1$d / %%',3,25)).toBe('25 / 3 / %');
  expect(localizedFormat('%2$lld / %1$lld / %%',3,25)).toBe('25 / 3 / %');
});

test.each([
  ['de','blocked','3 von 25 blockierten Domains verwendet'],['de','allowed','3 von 25 Ausnahmen verwendet'],
  ['ja','blocked','ブロックするドメイン3/25件を使用中'],['ja','allowed','例外3/25件を使用中'],
] as const)('domain quota uses the native %s %s format', (locale,decision,expected) => {
  configurePresentation({locale,textScales:null});mockDomainDecision=decision;
  try {
    const live={draft:{blocked:['a.example','b.example','c.example'],allowed:['a.example','b.example','c.example']},limits:{maxBlockedDomains:25,maxAllowedDomains:25}} as AppSnapshot;
    render(<Provider live={live}><AddDomainScreen /></Provider>);
    expect(screen.getByText(expected)).toBeOnTheScreen();
  } finally {configurePresentation();mockDomainDecision='blocked';}
});

test('domain entry uses native normalization, updates the draft and returns to its editor', () => {
  mockNormalizeDomain.mockReturnValue('tracker.example.net');
  render(<Provider><AddDomainScreen /><ReviewScreen /></Provider>);
  expect(screen.getByRole('button', {name:'Add domain'})).toBeDisabled();
  fireEvent.changeText(screen.getByLabelText('Domain to block'),' Tracker.Example.NET ');
  fireEvent.press(screen.getByRole('button', {name:'Add domain'}));
  expect(mockNormalizeDomain).toHaveBeenLastCalledWith(' Tracker.Example.NET ');
  expect(mockGoBack).toHaveBeenCalled();
  expect(screen.getByText('tracker.example.net')).toBeOnTheScreen();
  expect(screen.getByRole('button', {name:'Confirm changes'})).toBeDisabled();
});

test('native rejection leaves the domain draft unchanged and keyboard submit uses final text', () => {
  mockNormalizeDomain.mockReturnValue(null);
  render(<Provider><AddDomainScreen /><ReviewScreen /></Provider>);
  fireEvent(screen.getByLabelText('Domain to block'),'submitEditing',{nativeEvent:{text:'invalid'}});
  expect(screen.getByText('Enter a valid domain, such as ads.example.com.')).toBeOnTheScreen();
  expect(screen.getByText('No changes yet')).toBeOnTheScreen();
  mockNormalizeDomain.mockReturnValue('xn--bcher-kva.example');
  fireEvent(screen.getByLabelText('Domain to block'),'submitEditing',{nativeEvent:{text:'Bücher.Example'}});
  expect(mockNormalizeDomain).toHaveBeenLastCalledWith('Bücher.Example');
  expect(screen.getByText('xn--bcher-kva.example')).toBeOnTheScreen();
});

test('domain decisions keep blocked and allowed drafts independent and deduplicate canonical names', () => {
  const normalize=jest.fn().mockReturnValue('ads.example.com');
  const baseline=addPreviewDomain(initialPreviewDraft(),'ADS.EXAMPLE.COM',normalize);
  expect(addPreviewDomain(baseline,'ads.example.com.',normalize)).toBe(baseline);
  const allowed=addPreviewDomain(baseline,'ADS.EXAMPLE.COM',normalize,'allowed');
  expect(allowed.allowed).toEqual(['ads.example.com']);
  expect(baseline.allowed).toEqual([]);
  expect(previewDiff(baseline,allowed).allowedAdded).toEqual(['ads.example.com']);
});

test('Account preserves both sign-in providers and native signed-out backup gating', () => {
  render(<Provider><AccountScreen /></Provider>);
  expect(screen.getByRole('button',{name:'Sign in with Google'})).toBeEnabled();
  expect(screen.getByRole('button',{name:'Sign in with Apple'})).toBeEnabled();
  expect(screen.getByRole('switch',{name:'Enable backup'})).toBeDisabled();
  expect(screen.queryByRole('button',{name:'Set up encrypted backup'})).toBeNull();
  expect(screen.queryByRole('button',{name:'Restore backup'})).toBeNull();
  expect(screen.queryByRole('switch',{name:'Automatic backup'})).toBeNull();
});

test('signing out displays backup Off while retaining its saved state for sign-in', () => {
  const command=jest.fn();const app={command} as unknown as AppStore;
  const live={account:{signedIn:true},backup:{enablement:backupEnablement(true),configured:true,automatic:true,busy:false}} as AppSnapshot;
  const view=render(<Provider live={live} app={app}><AccountScreen /></Provider>);
  expect(screen.getByRole('switch',{name:'Enable backup'})).toHaveProp('value',true);
  // Keep the same native backup snapshot to reproduce retained configuration
  // during account sign-out, including capabilities that have not refreshed yet.
  view.rerender(<Provider live={{...live,account:{...live.account,signedIn:false}}} app={app}><AccountScreen /></Provider>);
  expect(screen.getByRole('switch',{name:'Enable backup'})).toBeDisabled();
  expect(screen.getByRole('switch',{name:'Enable backup'})).toHaveProp('value',false);
  expect(screen.getByText('Ready after sign-in')).toBeOnTheScreen();
  for(const name of ['Back Up Now','Restore Backup','Backup maintenance'])expect(screen.queryByRole('button',{name:localized(name)})).toBeNull();
  expect(screen.queryByRole('switch',{name:'Automatic backup'})).toBeNull();
  expect(command).not.toHaveBeenCalled();
  view.rerender(<Provider live={live} app={app}><AccountScreen /></Provider>);
  expect(screen.getByRole('switch',{name:'Enable backup'})).toHaveProp('value',true);
  expect(screen.getByRole('button',{name:'Backup maintenance'})).toBeOnTheScreen();
});

test('backup opt-in opens setup without claiming enablement on command completion or cancellation',async()=>{
  const command=jest.fn(async()=>undefined);const app={command} as unknown as AppStore;
  const live={account:{signedIn:true},backup:{enablement:backupEnablement(false),configured:false,busy:false}} as AppSnapshot;
  const view=render(<Provider live={live} app={app}><AccountScreen/></Provider>);
  const toggle=()=>screen.getByRole('switch',{name:'Enable backup'});
  expect(toggle()).toBeEnabled();expect(toggle()).toHaveProp('value',false);
  expect(screen.getByRole('button',{name:'Restore backup'})).toBeEnabled();
  expect(screen.queryByRole('button',{name:'Back up now'})).toBeNull();
  await act(async()=>fireEvent(toggle(),'valueChange',true));
  expect(command).toHaveBeenCalledWith({type:'native.flow',flow:'backupSetup'});
  expect(toggle()).toHaveProp('value',false);
  view.rerender(<Provider app={app} live={{...live,backup:{...live.backup,enablement:backupEnablement(false,true,{state:'setup',canEnable:false,canRestore:false})}}}><AccountScreen/></Provider>);
  expect(toggle()).toBeDisabled();expect(toggle()).toHaveProp('value',false);
  view.rerender(<Provider app={app} live={live}><AccountScreen/></Provider>);
  expect(toggle()).toBeEnabled();expect(toggle()).toHaveProp('value',false);
});

test('turning backup off preserves On until confirmed deletion, including cancelled and failed attempts',async()=>{
  const command=jest.fn(async()=>undefined);const app={command} as unknown as AppStore;
  const alert=jest.spyOn(Alert,'alert').mockImplementation(()=>{});
  const live={account:{signedIn:true},backup:{enablement:backupEnablement(true),configured:true,busy:false,automatic:false}} as AppSnapshot;
  try{
    const view=render(<Provider live={live} app={app}><AccountScreen/></Provider>);
    const toggle=()=>screen.getByRole('switch',{name:'Enable backup'});
    fireEvent(toggle(),'valueChange',false);
    expect(toggle()).toHaveProp('value',true);expect(command).not.toHaveBeenCalled();
    alert.mock.calls.at(-1)![2]!.find(button=>button.style==='cancel')!.onPress?.();
    expect(toggle()).toHaveProp('value',true);
    fireEvent(toggle(),'valueChange',false);
    await act(async()=>alert.mock.calls.at(-1)![2]!.find(button=>button.style==='destructive')!.onPress!());
    expect(command.mock.calls).toEqual([[{type:'backup.disable'}]]);
    expect(toggle()).toHaveProp('value',true);
    view.rerender(<Provider app={app} live={{...live,backup:{...live.backup,enablement:backupEnablement(null,true,{state:'deletionPending',canRetryDeletion:true}),deletionPending:true,needsAttention:true,detail:'Deletion was not confirmed. Try again.'}}}><AccountScreen/></Provider>);
    expect(screen.queryByRole('switch',{name:'Enable backup'})).toBeNull();
    expect(screen.getByText('Deletion was not confirmed. Try again.')).toBeOnTheScreen();
    expect(screen.getByRole('button',{name:'Turn off & delete backup'})).toBeEnabled();
    expect(screen.queryByRole('button',{name:'Restore backup'})).toBeNull();
    view.rerender(<Provider app={app} live={{...live,backup:{...live.backup,enablement:backupEnablement(false),configured:false}}}><AccountScreen/></Provider>);
    expect(toggle()).toHaveProp('value',false);expect(screen.getByText('No backup')).toBeOnTheScreen();
  }finally{alert.mockRestore();}
});

test('a missing native enablement contract cannot turn a failed configured state into an actionable switch',()=>{
  const live={account:{signedIn:true},backup:{configured:true,busy:false,needsAttention:true,detail:'Backup is unavailable.'}} as AppSnapshot;
  render(<Provider live={live}><AccountScreen/></Provider>);
  expect(screen.queryByRole('switch',{name:'Enable backup'})).toBeNull();
  expect(screen.queryByRole('button',{name:'Restore backup'})).toBeNull();
  expect(screen.queryByRole('button',{name:'Back up now'})).toBeNull();
  expect(screen.getByText('Backup is unavailable.')).toBeOnTheScreen();
});

test('automatic upload scheduling remains independent from backup enablement',async()=>{
  const command=jest.fn(async()=>undefined);const app={command} as unknown as AppStore;
  const live={account:{signedIn:true},backup:{enablement:backupEnablement(true),configured:true,busy:false,automatic:true}} as AppSnapshot;
  const view=render(<Provider live={live} app={app}><AccountScreen/></Provider>);
  fireEvent.press(screen.getByRole('button',{name:'Backup maintenance'}));
  await act(async()=>fireEvent(screen.getByRole('switch',{name:'Automatic backup'}),'valueChange',false));
  expect(command.mock.calls).toEqual([[{type:'settings.set',key:'backup.automatic',value:false}]]);
  view.rerender(<Provider live={{...live,backup:{...live.backup,automatic:false}}} app={app}><AccountScreen/></Provider>);
  expect(screen.getByRole('switch',{name:'Enable backup'})).toHaveProp('value',true);
  expect(screen.getByRole('button',{name:'Back up now'})).toBeEnabled();
});

test('account action feedback appears once inside the shared status text lane',()=>{
  const message='Sign-in unavailable';
  const live={account:{signedIn:false,status:'Not signed in',detail:message,message},backup:{enablement:backupEnablement(false,false),configured:false,busy:false}} as AppSnapshot;
  render(<Provider live={live}><AccountScreen/></Provider>);
  expect(screen.getAllByText(message)).toHaveLength(1);
  expect(screen.getByText('Not signed in')).toBeOnTheScreen();
});

test('a paid subscriber retains management and restore while fresh entitlements load',async()=>{
  const command=jest.fn().mockResolvedValue(null);const app={command} as unknown as AppStore;
  const live={plus:{enabled:true,checking:true,busy:false,expiration:'Expiration: Sep 9, 2027',message:'',offers:[]}} as unknown as AppSnapshot;
  const view=render(<Provider app={app} live={live}><UpgradeScreen/></Provider>);
  expect(screen.getByText('Lava Plus is active')).toBeOnTheScreen();
  expect(screen.getByText(live.plus.expiration)).toBeOnTheScreen();
  expect(screen.queryByText('Choose a plan')).toBeNull();
  expect(screen.queryByText('Checking Lava Plus…')).toBeNull();
  await act(async()=>fireEvent.press(screen.getByRole('button',{name:'Manage subscription'})));
  expect(command).toHaveBeenCalledWith({type:'purchase.manage'});
  await act(async()=>fireEvent.press(screen.getByRole('button',{name:localized('Restore purchase')})));
  expect(command).toHaveBeenCalledWith({type:'purchase.restore'});
  view.rerender(<Provider app={app} live={{...live,plus:{...live.plus,busy:true}}}><UpgradeScreen/></Provider>);
  expect(screen.getByRole('button',{name:'Manage subscription'})).toBeDisabled();
  expect(screen.getByRole('button',{name:localized('Restore purchase')})).toBeDisabled();
});
test('the Upgrade loading state does not offer purchases before the initial entitlement check',()=>{
  const live={plus:{enabled:false,checking:true,busy:false,message:'',offers:[]}} as unknown as AppSnapshot;
  render(<Provider live={live}><UpgradeScreen/></Provider>);
  expect(screen.getByText('Checking Lava Plus…')).toBeOnTheScreen();
  expect(screen.queryByText('Choose a plan')).toBeNull();
});

test.each(['Filtering Counts','Domain logs','Network activity','Lava Guard Progress'])('disabling %s requires explicit destructive confirmation before its native mutation',async title=>{
  const alert=jest.spyOn(Alert,'alert').mockImplementation(()=>{});
  const command=jest.fn().mockResolvedValue(null);const app={command} as unknown as AppStore;
  try {
    render(<Provider app={app}><PrivacyScreen/></Provider>);
    fireEvent(screen.getByRole('switch',{name:localized(title)}),'valueChange',false);
    expect(command).not.toHaveBeenCalled();
    expect(screen.getByRole('switch',{name:localized(title)})).toHaveProp('value',true);
    const buttons=alert.mock.calls.at(-1)![2]!;
    expect(buttons.find(button=>button.style==='cancel')).toBeDefined();
    await act(async()=>buttons.find(button=>button.style==='cancel')?.onPress?.());
    expect(command).not.toHaveBeenCalled();
    fireEvent(screen.getByRole('switch',{name:localized(title)}),'valueChange',false);
    await act(async()=>alert.mock.calls.at(-1)![2]!.find(button=>button.style==='destructive')!.onPress!());
    expect(command).toHaveBeenCalledTimes(1);
    expect(command).toHaveBeenCalledWith({type:'settings.set',key:`logs.${title}`,value:false});
  } finally {alert.mockRestore();}
});
test.each([['de','1.234 Regeln'],['ja','1,234 件のルール']])('filter library and sharing use the native %s rule format', (locale,expected)=>{
  configurePresentation({locale,textScales:null});
  try {
    const live={filters:[{id:'filter',name:'My filter',shareable:true,shareSummary:expected,count:locale==='de'?'1.234':'1,234',lists:[],frozen:false}],session:{activeFilterID:'filter'},limits:{maxFilters:3}} as unknown as AppSnapshot;
    render(<Provider live={live}><LibraryScreen/><ShareScreen/></Provider>);
    expect(screen.getAllByText(expected)).toHaveLength(2);
  } finally {configurePresentation();}
});
test('a user filter named Cancel stays verbatim in German rows, accessibility, menus and navigation titles',()=>{
  configurePresentation({locale:'de',textScales:null});
  const alert=jest.spyOn(Alert,'alert').mockImplementation(()=>{});
  try {
    const app={command:jest.fn().mockResolvedValue(null)} as unknown as AppStore;
    const live={filters:[{id:'filter',name:'Cancel',count:'0',lists:[],frozen:false}],session:{activeFilterID:'other',filterID:'filter',filter:'Cancel',blocklists:[],savedBlocklists:[]},limits:{maxFilters:3},filterStatus:{label:'rules in effect',title:'Filter up to date',icon:'checkmark.circle.fill',warning:false}} as unknown as AppSnapshot;
    render(<Provider app={app} live={live}><LibraryScreen/><ShareScreen/><FilterScreen/></Provider>);
    expect(screen.getAllByText('Cancel')).toHaveLength(3);
    const rows=screen.getAllByRole('button',{name:'Cancel'});
    expect(rows).toHaveLength(2);
    fireEvent.press(rows[0]!);
    expect(mockChooseFilterAction).toHaveBeenCalledWith('Cancel',true,false);
    expect(screen.getAllByText('Cancel').length).toBeGreaterThan(0);
  } finally {alert.mockRestore();configurePresentation();}
});
test.each(['de','ja'])('blocklist budget and review summaries use native %s formats',locale=>{
  configurePresentation({locale,textScales:null});
  try {
    render(<Provider><AddBlocklistScreen/><ReviewScreen/></Provider>);
    expect(screen.getByText(localizedFormat('About %1$@ of %2$@ rules','156K','500K'))).toBeOnTheScreen();
    expect(screen.getByText(localizedFormat('%@ will be saved locally.',localizedFormat('%d changes',0)))).toBeOnTheScreen();
  } finally {configurePresentation();}
});
test.each([
  ['de','Sicherheit & Bedrohungsdaten','9 Std. 30 Min. lokal geschützt','Verbindungs- und Schutzereignisse','Noch keine blockierten Domains gespeichert'],
  ['ja','セキュリティと脅威情報','9時間30分をローカルで保護','接続と保護のイベント','ブロックしたドメインはまだ保存されていません'],
])('native dynamic catalog labels and Activity/status/empty copy remain localized in %s',async(locale,category,uptime,network,empty)=>{
  configurePresentation({locale,textScales:null});
  try {
    // This key arrives from Swift and is absent from React source literals.
    expect(localized('Security & Threat Intel')).toBe(category);
    const activity=render(<Provider example><ActivityScreen/></Provider>);
    await waitFor(()=>expect(screen.getByText(uptime)).toBeOnTheScreen());
    expect(screen.getByRole('link',{name:localized('Review Privacy & Data')})).toBeOnTheScreen();
    expect(screen.getByRole('button',{name:localized('Custom')})).toBeOnTheScreen();
    activity.unmount();
    render(<Provider><SettingsScreen/><DomainListScreen/></Provider>);
    expect(localized('Connection and protection events')).toBe(network);
    expect(screen.getByText(localized('Network Activity'))).toBeOnTheScreen();
    expect(screen.getByText(localized('No domains saved yet'))).toBeOnTheScreen();
  } finally {configurePresentation();}
});
test.each([[true,true],[true,false],[false,true],[false,false]])('renewal terms remain available with Plus=%s and commitment offer=%s',(enabled,showsYearlyPaidMonthly)=>{
  const live={plus:{enabled,checking:false,busy:false,showsYearlyPaidMonthly,message:'',offers:[]}} as unknown as AppSnapshot;
  render(<Provider live={live}><UpgradeScreen/></Provider>);
  expect(!!screen.queryByText(/The yearly plan paid monthly has a 12-month commitment/)).toBe(showsYearlyPaidMonthly);
  expect(screen.getByText(/Payment is charged to your Apple Account/)).toBeOnTheScreen();
  expect(screen.getByRole('link',{name:'Terms of Use'})).toBeOnTheScreen();
  expect(screen.getByRole('link',{name:'Privacy Policy'})).toBeOnTheScreen();
});

test('discarding filter edits restores both domain and blocklist drafts and leaves edit mode', () => {
  const alert = jest.spyOn(Alert, 'alert').mockImplementation(() => {});
  render(<Provider><FilterScreen /><AddDomainScreen /></Provider>);
  const toolbar = () => [...mockSetOptions.mock.calls].reverse().find(([options]) => options.unstable_headerRightItems)![0];
  act(() => toolbar().unstable_headerRightItems().find((item: {label: string}) => item.label === 'Edit').onPress());
  mockNormalizeDomain.mockReturnValue('tracker.example.net');
  fireEvent(screen.getByLabelText('Domain to block'), 'submitEditing', {nativeEvent:{text:'Tracker.Example.NET.'}});
  fireEvent.press(screen.getByTestId('filter.edit.Block List Basic'));
  expect(screen.getByText('tracker.example.net')).toBeOnTheScreen();
  act(() => toolbar().unstable_headerLeftItems()[0].onPress());
  expect(alert).toHaveBeenLastCalledWith('Discard changes?', expect.any(String), expect.any(Array), undefined);
  act(() => alert.mock.calls.at(-1)![2]!.find(button => button.text === 'Discard')!.onPress!());
  expect(screen.queryByText('tracker.example.net')).toBeNull();
  expect(screen.getByText('Block List Basic')).toBeOnTheScreen();
  expect(screen.queryByRole('button', {name:'Block a domain'})).toBeNull();
  expect(toolbar().unstable_headerRightItems().map((item: {label:string}) => item.label)).toContain('Edit');
  alert.mockRestore();
});

test('Security gates all six protected actions and opens passcode setup', () => {
  render(<Provider><SecurityScreen /></Provider>);
  expect(screen.getByText('Choose which actions need a passcode or Face ID. All choices start off.')).toBeOnTheScreen();
  expect(screen.getByRole('switch',{name:'Face ID'})).toBeDisabled();
  for (const title of ['Open Lava','Turn protection on or off','Pause protection','Edit filters','View Activity','Change settings']) expect(screen.getByRole('switch',{name:title})).toBeDisabled();
  fireEvent(screen.getByRole('switch',{name:'Passcode'}),'valueChange',true);
  expect(mockNavigate).toHaveBeenLastCalledWith('Passcode');
});









test('empty domain logs stay empty and expose the native Allowed/Blocked choices', () => {
  render(<Provider><DomainListScreen /></Provider>);
  expect(screen.queryByText('ads.example.com')).toBeNull();
  expect(screen.getByText('No domains saved yet')).toBeOnTheScreen();
  fireEvent.press(screen.getByRole('button',{name:'Allowed'}));
  expect(screen.getByText('No allowed requests saved yet')).toBeOnTheScreen();
});

test('Feedback requires topic and details before review and preserves the draft when going back', () => {
  render(<Provider><FeedbackScreen /></Provider>);
  expect(screen.getByRole('button',{name:'Continue'})).toBeDisabled();
  expect(screen.UNSAFE_getAllByType(LavaSelectionAccessory).every(mark=>mark.props.state==='unselected')).toBe(true);
  fireEvent.press(screen.getByRole('button',{name:'Something else'}));
  fireEvent.press(screen.getByRole('button',{name:'I have a suggestion'}));
  expect(screen.getByRole('button',{name:'Something else'})).toHaveProp('accessibilityState',expect.objectContaining({selected:false}));
  expect(screen.getByRole('button',{name:'I have a suggestion'})).toHaveProp('accessibilityState',expect.objectContaining({selected:true}));
  expect(screen.UNSAFE_getAllByType(LavaSelectionAccessory).filter(mark=>mark.props.state==='selected')).toHaveLength(1);
  fireEvent.press(screen.getByRole('button',{name:'Continue'}));
  expect(screen.getByRole('button',{name:'Review'})).toBeDisabled();
  fireEvent.changeText(screen.getByLabelText('Details'),'Keep the native layout');
  fireEvent.press(screen.getByRole('button',{name:'Review'}));
  expect(screen.getByText('Keep the native layout')).toBeOnTheScreen();
  expect(screen.getByText('Not sent')).toBeOnTheScreen();
  fireEvent.press(screen.getByRole('button',{name:'Back'}));
  expect(screen.getByLabelText('Details')).toHaveDisplayValue('Keep the native layout');
});

test('Activity has the native summary and privacy route, with a native rolling seven-day choice', async () => {
  render(<Provider example><ActivityScreen /></Provider>);
  await waitFor(() => expect(screen.getByText(expectedNumber.format(3246))).toBeOnTheScreen());
  expect(screen.getByLabelText('Allowed, 2,648 (82%)')).toBeOnTheScreen();
  expect(screen.getByLabelText('Blocked, 598 (18%)')).toBeOnTheScreen();
  expect(screen.getByText('9h 30m protected locally')).toBeOnTheScreen();
  expect(screen.getByRole('button', {name: localized('7 days')})).toBeOnTheScreen();
  expect(screen.queryByText('Preview data')).toBeNull();
  expect(screen.queryByText('UI preview · sample data · no VPN')).toBeNull();
  fireEvent.press(screen.getByRole('link', {name: 'Review Privacy & data'}));
  expect(mockNavigate).toHaveBeenLastCalledWith('Privacy');
});

test('live Activity never borrows the isolated review fixture even when its preview flag is set',async()=>{
  Object.defineProperty(AppState,'currentState',{configurable:true,value:'active'});
  const command=jest.fn(async()=>({allowed:12,blocked:3,uptime:'1m'}));
  const app={command,subscribe:()=>()=>{},getInvalidation:()=>0} as unknown as AppStore;
  render(<Provider app={app} example><ActivityScreen/></Provider>);
  await waitFor(()=>expect(screen.getByText('15')).toBeOnTheScreen());
  expect(screen.queryByText(expectedNumber.format(3246))).toBeNull();
  fireEvent.press(screen.getByTestId('activity.chart.next'));
  expect(screen.getByTestId('activity.plot.counts')).toBeOnTheScreen();
  expect(screen.queryByTestId('activity.bucket.0')).toBeNull();
});

test('Activity date sheet cancellation retains the range; confirmation changes the summary', async () => {
  const activity = render(<Provider example><ActivityScreen /></Provider>);
  await waitFor(() => expect(activity.getByText(expectedNumber.format(3246))).toBeOnTheScreen());
  mockPickActivityDates.mockResolvedValueOnce(null);
  expect(activity.queryByTestId('activity.custom-range')).toBeNull();
  await act(async()=>fireEvent.press(screen.getByRole('button',{name:localized('Custom')})));
  expect(mockPickActivityDates).toHaveBeenLastCalledWith(-13, 1000);
  expect(activity.getByText(expectedNumber.format(3246))).toBeTruthy();
  expect(activity.getByTestId('activity.period').props.value).toBe('today');
  expect(activity.queryByTestId('activity.custom-range')).toBeNull();
  mockPickActivityDates.mockResolvedValueOnce({start: 0, end: 0, label: 'Sep 7', includesToday: false});
  await act(async()=>fireEvent.press(screen.getByRole('button',{name:localized('Custom')})));
  expect(activity.getAllByText(expectedNumber.format(0))).toHaveLength(1);
  expect(activity.getByLabelText('Allowed, 0 (0%)')).toBeOnTheScreen();
  expect(activity.getByLabelText('Blocked, 0 (0%)')).toBeOnTheScreen();
  expect(activity.getByText('Allowed')).toBeTruthy();
  expect(activity.getByTestId('activity.period').props.value).toBe('custom');
  expect(activity.getAllByTestId('activity.custom-range')).toHaveLength(1);
  expect(activity.getByTestId('activity.custom-range')).toHaveTextContent('Sep 7');
  await waitFor(()=>expect(activity.getByTestId('activity.period').props.disabled).toBe(false));
  await act(async()=>fireEvent.press(activity.getByRole('button',{name:localized('Month')})));
  expect(mockGetActivityDatePreset).toHaveBeenLastCalledWith('month');
  expect(activity.getByTestId('activity.period').props.value).toBe('month');
  expect(activity.queryByTestId('activity.custom-range')).toBeNull();
});


test('Custom holds while preparing and presenting its fortnight draft, then cancels without accepting it',async()=>{
  render(<Provider example><ActivityScreen/></Provider>);
  await waitFor(()=>expect(screen.getByText(expectedNumber.format(3246))).toBeOnTheScreen());
  let initial!:(value:typeof todayRange)=>void;
  let finish!:(value:typeof todayRange|null)=>void;
  mockGetActivityDatePreset.mockImplementationOnce(()=>new Promise(resolve=>{initial=resolve;}));
  mockPickActivityDates.mockImplementationOnce(()=>new Promise(resolve=>{finish=resolve;}));
  const calls=mockPickActivityDates.mock.calls.length;
  fireEvent.press(screen.getByRole('button',{name:localized('Custom')}));
  expect(screen.getByTestId('activity.period').props.value).toBe('custom');
  expect(screen.getByTestId('activity.period').props.disabled).toBe(true);
  expect(mockGetActivityDatePreset).toHaveBeenLastCalledWith('fortnight');
  expect(mockPickActivityDates).toHaveBeenCalledTimes(calls);
  expect(screen.getByText(expectedNumber.format(3246))).toBeOnTheScreen();
  await act(async()=>initial({...todayRange,start:-13}));
  expect(mockPickActivityDates).toHaveBeenLastCalledWith(-13,1000);
  expect(screen.getByTestId('activity.period').props.value).toBe('custom');
  expect(screen.queryByTestId('activity.custom-range')).toBeNull();
  await act(async()=>finish(null));
  expect(screen.getByTestId('activity.period').props.value).toBe('today');
  expect(screen.getByTestId('activity.period').props.disabled).toBe(false);
  expect(screen.getByText(expectedNumber.format(3246))).toBeOnTheScreen();
});

test('a Custom default reply after leaving Activity cannot open its date sheet',async()=>{
  Object.defineProperty(AppState,'currentState',{configurable:true,value:'active'});
  const view=render(<Provider example><ActivityScreen/></Provider>);
  await waitFor(()=>expect(screen.getByText(expectedNumber.format(3246))).toBeOnTheScreen());
  let initial!:(value:typeof todayRange)=>void;
  mockGetActivityDatePreset.mockImplementationOnce(()=>new Promise(resolve=>{initial=resolve;}));
  const calls=mockPickActivityDates.mock.calls.length;
  fireEvent.press(screen.getByRole('button',{name:localized('Custom')}));
  mockFocused=false;view.rerender(<Provider example><ActivityScreen/></Provider>);
  mockFocused=true;view.rerender(<Provider example><ActivityScreen/></Provider>);
  await act(async()=>initial({...todayRange,start:-13}));
  expect(mockPickActivityDates).toHaveBeenCalledTimes(calls);
  expect(screen.getByTestId('activity.period').props.value).toBe('today');
  expect(screen.getByTestId('activity.period').props.disabled).toBe(false);
});

test('reopening Custom preserves its accepted dates and cancellation keeps Custom selected',async()=>{
  render(<Provider example><ActivityScreen/></Provider>);
  await waitFor(()=>expect(screen.getByText(expectedNumber.format(3246))).toBeOnTheScreen());
  mockPickActivityDates.mockResolvedValueOnce({start:20,end:30,label:'Chosen range',includesToday:false});
  await act(async()=>fireEvent.press(screen.getByRole('button',{name:localized('Custom')})));
  const presets=mockGetActivityDatePreset.mock.calls.length;
  let finish!:(value:null)=>void;
  mockPickActivityDates.mockImplementationOnce(()=>new Promise(resolve=>{finish=resolve;}));
  await act(async()=>fireEvent.press(screen.getByRole('button',{name:localized('Custom')})));
  expect(mockPickActivityDates).toHaveBeenLastCalledWith(20,30);
  expect(mockGetActivityDatePreset).toHaveBeenCalledTimes(presets);
  expect(screen.getByTestId('activity.period').props.value).toBe('custom');
  await act(async()=>finish(null));
  expect(screen.getByTestId('activity.period').props.value).toBe('custom');
  expect(screen.getByTestId('activity.custom-range')).toHaveTextContent('Chosen range');
});

test('a failed Custom default restores the accepted preset without presenting a picker',async()=>{
  const alert=jest.spyOn(Alert,'alert').mockImplementation(()=>{});
  render(<Provider example><ActivityScreen/></Provider>);
  await waitFor(()=>expect(screen.getByText(expectedNumber.format(3246))).toBeOnTheScreen());
  await act(async()=>fireEvent.press(screen.getByRole('button',{name:localized('7 days')})));
  const calls=mockPickActivityDates.mock.calls.length;
  mockGetActivityDatePreset.mockRejectedValueOnce(new Error('Unavailable'));
  await act(async()=>fireEvent.press(screen.getByRole('button',{name:localized('Custom')})));
  expect(screen.getByTestId('activity.period').props.value).toBe('week');
  expect(screen.getByTestId('activity.period').props.disabled).toBe(false);
  expect(mockPickActivityDates).toHaveBeenCalledTimes(calls);
  expect(alert.mock.calls[0]?.slice(0,2)).toEqual(['Activity dates unavailable','Try again.']);
  alert.mockRestore();
});

function editingSnapshot(): AppSnapshot {
  return {session:{...initialSession(),filterID:'active',activeFilterID:'active',editing:true,blocklists:['first-list','second-list']},
    draft:{blocked:['one.example','two.example'],allowed:[]},savedDraft:{blocked:['one.example','two.example'],allowed:[]},
    filters:[{id:'active',name:'Core',count:'2',frozen:false,lists:[]}],blocklistNames:{},blocklistMetadata:{},
    filterStatus:{title:'Filter up to date',icon:'checkmark.circle.fill',label:'rules in effect',warning:false},
    limits:{maxBlockedDomains:25,maxAllowedDomains:25}} as unknown as AppSnapshot;
}

const toolbarItems=(side:'Left'|'Right'='Right')=>[...mockSetOptions.mock.calls].reverse().find(([options])=>options[`unstable_header${side}Items`])![0][`unstable_header${side}Items`]();

test.each([true,false])('inactive save returns exactly to its detail when snapshot arrives first: %s',async(snapshotFirst)=>{
  const stack=['Your filters','Core','Review'];
  mockGoBack.mockImplementation(()=>stack.pop());
  let finishApply!:(value:null)=>void;
  const command=jest.fn((input:AppCommand)=>input.type==='filter.apply'
    ?new Promise(resolve=>{finishApply=resolve;}):Promise.resolve('review-token'));
  const app={command} as unknown as AppStore;
  const live=editingSnapshot();live.session.activeFilterID='another-filter';
  const view=render(<Provider live={live} app={app}><ReviewScreen/></Provider>);
  try {
    await waitFor(()=>expect(screen.getByRole('button',{name:'Confirm changes'})).toBeEnabled());
    act(()=>fireEvent.press(screen.getByRole('button',{name:'Confirm changes'})));
    const publishSaved=()=>view.rerender(<Provider live={{...live,session:{...live.session,editing:false}}} app={app}><ReviewScreen/></Provider>);
    if(snapshotFirst){publishSaved();await act(async()=>finishApply(null));}
    else {await act(async()=>finishApply(null));publishSaved();}
    expect(mockGoBack).toHaveBeenCalledTimes(1);
    expect(stack).toEqual(['Your filters','Core']);
  } finally {view.unmount();mockGoBack.mockReset();}
});
const toolbarAction=(label:string,side:'Left'|'Right'='Right')=>toolbarItems(side).find((item:{label:string})=>item.label===localized(label));

test('filter detail keeps toolbar sharing without a duplicate bottom row',()=>{
  const live=editingSnapshot();live.session.editing=false;live.filters[0]!.shareable=true;
  render(<Provider app={{command:jest.fn(async()=>null)} as unknown as AppStore} live={live}><FilterScreen/></Provider>);
  expect(screen.queryByRole('button',{name:'Share your filter'})).toBeNull();
  expect(screen.queryByText('Share via QR or code')).toBeNull();
  const share=toolbarAction('Share my filter');
  expect(share.disabled).toBe(false);
  act(()=>share.onPress());
  expect(mockNavigate).toHaveBeenLastCalledWith('ShareDetail',{id:'active'});
});

test('filter detail rename opens its own native form without a library edit session',async()=>{
  const command=jest.fn(async(_input:AppCommand)=>true);
  render(<Provider app={{command} as unknown as AppStore} live={editingSnapshot()}><FilterScreen/></Provider>);
  await act(async()=>fireEvent.press(screen.getByTestId('filter.identity.rename')));
  expect(command).toHaveBeenCalledWith({type:'filter.renameForm',id:'active'});
  expect(command.mock.calls.some(([input])=>input.type==='library.edit'||input.type==='library.form')).toBe(false);
});

test('entry never refreshes and repeated Edit taps start one edit',async()=>{
  let finishEdit!:(value:null)=>void;
  let finishRefresh!:(value:null)=>void;
  const live=editingSnapshot();live.session.editing=false;
  const command=jest.fn((input:AppCommand)=>input.type==='filter.refresh'?new Promise(resolve=>{finishRefresh=resolve;}):input.type==='filter.edit'?new Promise(resolve=>{finishEdit=resolve;}):Promise.resolve(null));
  const app={command} as unknown as AppStore;
  const view=render(<Provider app={app} live={live}><FilterScreen/></Provider>);
  expect(command).not.toHaveBeenCalledWith({type:'filter.refresh',id:'active'});
  expect(toolbarAction('Refresh now').disabled).toBe(false);
  const edit=toolbarAction('Edit').onPress;
  act(()=>{for(let index=0;index<20;index++)edit();});
  expect(command.mock.calls.filter(([input])=>input.type==='filter.edit')).toEqual([[{type:'filter.edit',id:'active'}]]);
  await act(async()=>finishEdit(null));
  view.rerender(<Provider app={app} live={{...live,session:{...live.session,editing:true}}}><FilterScreen/></Provider>);
  expect(toolbarAction('Save')).toBeDefined();
  expect(command.mock.calls.filter(([input])=>input.type==='filter.refresh')).toHaveLength(0);
});

test.each(['saved','review','failure'])('filter Save follows the native %s disposition and accepts only one pending save',async outcome=>{
  let finish!:(result:string)=>void;let fail!:(error:Error)=>void;
  const command=jest.fn((input:AppCommand)=>input.type==='filter.save'?new Promise<string>((resolve,reject)=>{finish=resolve;fail=reject;}):Promise.resolve(null));
  const alert=jest.spyOn(Alert,'alert').mockImplementation(()=>{});
  try {
    const live=editingSnapshot();live.draft={blocked:['new.example'],allowed:[]};
    render(<Provider live={live} app={{command} as unknown as AppStore}><FilterScreen/></Provider>);
    const save=toolbarAction('Save');expect(save.disabled).toBe(false);
    act(()=>{save.onPress();save.onPress();});
    expect(command.mock.calls.filter(([input])=>input.type==='filter.save')).toEqual([[{type:'filter.save',id:'active'}]]);
    expect(toolbarAction('Save').disabled).toBe(true);
    await act(async()=>outcome==='failure'?fail(new Error('Disk unavailable')):finish(outcome));
    if(outcome==='review')expect(mockNavigate).toHaveBeenLastCalledWith('Review',{id:'active'});
    else expect(mockNavigate).not.toHaveBeenCalled();
    if(outcome==='failure')expect(alert).toHaveBeenLastCalledWith('Couldn’t save','Disk unavailable',undefined,undefined);
    expect(toolbarAction('Save').disabled).toBe(false);
  }finally{alert.mockRestore();}
});

test('staged list and domain removals remain visible with independent Undo actions',()=>{
  const command=jest.fn((_input:AppCommand)=>new Promise(()=>{}));const live=editingSnapshot();
  live.filterEditing={canSave:true,reviewCanConfirm:true,refreshing:false,validation:'',lists:[{id:'first-list',pending:true,undo:true}],blocked:[{id:'one.example',pending:true,undo:true}],allowed:[{id:'trusted.example',pending:false,undo:true}]};
  render(<Provider live={live} app={{command} as unknown as AppStore}><FilterScreen/></Provider>);
  for(const id of ['first-list','one.example','trusted.example']){
    expect(screen.getByTestId(`filter.edit.${id}`)).toHaveProp('accessibilityLabel','Undo');
    fireEvent.press(screen.getByTestId(`filter.edit.${id}`));
  }
  expect(command.mock.calls.filter(([input])=>input.type!=='filter.refresh')).toEqual([
    [{type:'filter.undoList',id:'active',sourceID:'first-list'}],
    [{type:'filter.undoDomain',id:'active',decision:'blocked',domain:'one.example'}],
    [{type:'filter.undoDomain',id:'active',decision:'allowed',domain:'trusted.example'}],
  ]);
});

test('filter content rows lead with a stroke-only outcome mark from the shared row owner',()=>{
  const live=editingSnapshot();
  live.filterEditing={canSave:true,reviewCanConfirm:true,refreshing:false,validation:'',
    lists:[{id:'first-list',pending:false,undo:false}],blocked:[{id:'one.example',pending:false,undo:false}],allowed:[{id:'trusted.example',pending:false,undo:false}]};
  render(<Provider live={live} app={{command:jest.fn().mockResolvedValue(null)} as unknown as AppStore}><FilterScreen/></Provider>);
  // The blocklist and blocked-domain rows carry the blocked outcome; allowed
  // carries allowed. Both live on ListRow so read-only/inactive views inherit it.
  const rows=screen.UNSAFE_getAllByType(ListRow);
  const outcomeFor=(testID:string)=>rows.find(row=>row.props.testID===testID)!.props.outcome;
  expect(outcomeFor('filter.rule.list.first-list')).toBe('blocked');
  expect(outcomeFor('filter.rule.blocked.one.example')).toBe('blocked');
  expect(outcomeFor('filter.rule.allowed.trusted.example')).toBe('allowed');
  // Stroke-only (`xmark.circle`, not `.fill`) in the ordinary label color.
  const decoration=require('../specs/LavaDecorationNativeComponent').default;
  const glyphs=screen.UNSAFE_getAllByType(decoration);
  expect(glyphs.filter(glyph=>glyph.props.symbol==='xmark.circle'&&glyph.props.tone==='primary')).toHaveLength(2);
  expect(glyphs.filter(glyph=>glyph.props.symbol==='arrow.right.circle'&&glyph.props.tone==='primary')).toHaveLength(1);
});

test.each([false,true])('domain quota preserves the native upgrade/remove contract on Plus=%s',async plus=>{
  const live=editingSnapshot();live.limits.maxBlockedDomains=2;live.plus={enabled:plus} as AppSnapshot['plus'];
  const command=jest.fn(async(_input:AppCommand)=>null);
  render(<Provider live={live} app={{command} as unknown as AppStore}><AddDomainScreen/></Provider>);
  if(plus)expect(screen.getByRole('button',{name:'Add domain'})).toBeDisabled();
  else {expect(screen.getByRole('button',{name:'Upgrade'})).toBeEnabled();await act(async()=>fireEvent.press(screen.getByRole('button',{name:'Upgrade'})));expect(mockNavigate).toHaveBeenLastCalledWith('Upgrade');}
  await act(async()=>fireEvent(screen.getByLabelText('Domain to block'),'submitEditing',{nativeEvent:{text:'over-limit.example'}}));
  expect(command.mock.calls.some(([input])=>input.type==='filter.domain')).toBe(false);
  expect(mockGoBack).not.toHaveBeenCalled();
});

test.each(['rejected','cancelled'])('domain addition retains the editor when native validation is %s',async outcome=>{
  const command=jest.fn(async()=>{if(outcome==='cancelled')throw new Error('Authentication cancelled.');return {isAccepted:false,title:'Already blocked',message:'This domain is already in this filter.'};});
  render(<Provider live={editingSnapshot()} app={{command} as unknown as AppStore}><AddDomainScreen/></Provider>);
  fireEvent.changeText(screen.getByLabelText('Domain to block'),'one.example');
  await act(async()=>fireEvent.press(screen.getByRole('button',{name:'Add domain'})));
  expect(mockGoBack).not.toHaveBeenCalled();expect(screen.getByLabelText('Domain to block')).toBeOnTheScreen();
  if(outcome==='rejected'){expect(screen.getByText('Already blocked')).toBeOnTheScreen();expect(screen.getByText('This domain is already in this filter.')).toBeOnTheScreen();}
  else expect(screen.queryByText('Authentication canceled.')).toBeNull();
});

function librarySnapshot():AppSnapshot {
  const live=editingSnapshot();live.session.editing=false;live.plus={enabled:false} as AppSnapshot['plus'];live.limits.maxFilters=3;
  live.filters.push({id:'spare',name:'Spare',count:'0',frozen:false,lists:[],shareable:false,shareSummary:''},{id:'locked',name:'Locked',count:'1',frozen:true,lists:[],shareable:false,shareSummary:''});
  return live;
}
test('Library native draft owns deletions and review cancellation retains them',async()=>{
  const command=jest.fn(async(input:AppCommand):Promise<boolean|null>=>input.type==='library.form'?false:null);
  const live=librarySnapshot();const app={command} as unknown as AppStore;
  const view=render(<Provider live={live} app={app}><LibraryScreen/></Provider>);
  await act(async()=>toolbarAction('Edit').onPress());
  expect(command).toHaveBeenCalledWith({type:'library.edit'});
  expect(toolbarAction('Review changes').disabled).toBe(true);
  await act(async()=>fireEvent.press(screen.getByRole('button',{name:'Delete'})));
  expect(command).toHaveBeenLastCalledWith({type:'library.toggleDeletion',id:'spare'});
  const staged={...live,libraryEditing:{active:true,hasChanges:true,deletions:['spare']}};
  view.rerender(<Provider live={staged} app={app}><LibraryScreen/></Provider>);
  expect(screen.getByRole('button',{name:'Spare'})).toBeDisabled();
  await act(async()=>toolbarAction('Review changes').onPress());
  expect(command).toHaveBeenLastCalledWith({type:'library.form',form:'delete',ids:['spare']});
  expect(screen.getByRole('button',{name:'Undo'})).toBeOnTheScreen();
  expect(command.mock.calls.some(([input])=>input.type==='filter.delete')).toBe(false);
});
test('Library Add reviews staged changes before applying the filter limit',async()=>{
  const live=librarySnapshot();
  live.libraryEditing={active:true,hasChanges:true,deletions:['spare']};
  const command=jest.fn(async(_input:AppCommand)=>false);
  render(<Provider live={live} app={{command} as unknown as AppStore}><LibraryScreen/></Provider>);
  await act(async()=>fireEvent.press(screen.getByRole('button',{name:'Add a filter'})));
  expect(command).toHaveBeenCalledWith({type:'library.form',form:'delete',ids:['spare']});
  expect(command.mock.calls.some(([input])=>input.type==='library.form'&&input.form==='create')).toBe(false);
  expect(mockNavigate).not.toHaveBeenCalledWith('Upgrade');
});
test('Library addition-only and rename-only native drafts enable Review and discard all change kinds',async()=>{
  const live={...librarySnapshot(),libraryEditing:{active:true,hasChanges:true,deletions:[]}};
  const command=jest.fn(async(_input:AppCommand)=>false);const app={command} as unknown as AppStore;
  const alert=jest.spyOn(Alert,'alert').mockImplementation(()=>{});
  try {
    render(<Provider live={live} app={app}><LibraryScreen/></Provider>);
    expect(toolbarAction('Review changes').disabled).toBe(false);
    await act(async()=>toolbarAction('Review changes').onPress());
    expect(command).toHaveBeenLastCalledWith({type:'library.form',form:'delete',ids:[]});
    act(()=>toolbarAction('Close edit mode','Left').onPress());
    expect(alert).toHaveBeenLastCalledWith('Discard changes?','Your draft library changes won’t be applied.',expect.any(Array),undefined);
    await act(async()=>alert.mock.calls.at(-1)![2]!.find(button=>button.style==='destructive')!.onPress!());
    expect(command).toHaveBeenLastCalledWith({type:'library.cancel'});
    expect(command.mock.calls.some(([input])=>['filter.create','filter.rename','filter.delete'].includes(input.type))).toBe(false);
  }finally{alert.mockRestore();}
});
test('Library cancelled authentication never starts the native draft',async()=>{
  const command=jest.fn().mockRejectedValueOnce(new Error('Authentication cancelled.'));
  const alert=jest.spyOn(Alert,'alert').mockImplementation(()=>{});
  try {
    render(<Provider live={librarySnapshot()} app={{command} as unknown as AppStore}><LibraryScreen/></Provider>);
    await act(async()=>toolbarAction('Edit').onPress());
    expect(screen.queryByRole('button',{name:'Delete'})).toBeNull();
    expect(alert).not.toHaveBeenCalled();
    expect(command.mock.calls).toEqual([[{type:'library.edit'}]]);
  }finally{alert.mockRestore();}
});
test('Library opens active filters directly and delegates create/rename validation to native forms',async()=>{
  const live=librarySnapshot();live.filters.pop();const command=jest.fn(async(_input:AppCommand)=>null);
  const app={command} as unknown as AppStore;
  const view=render(<Provider live={live} app={app}><LibraryScreen/></Provider>);
  await act(async()=>fireEvent.press(screen.getByRole('button',{name:'Core'})));
  expect(command).toHaveBeenLastCalledWith({type:'filter.open',id:'active'});
  expect(mockNavigate).toHaveBeenLastCalledWith('Filter',{id:'active'});
  await act(async()=>toolbarAction('Edit').onPress());
  view.rerender(<Provider live={{...live,libraryEditing:{active:true,hasChanges:false,deletions:[]}}} app={app}><LibraryScreen/></Provider>);
  await act(async()=>fireEvent.press(screen.getByRole('button',{name:'Spare'})));
  expect(command).toHaveBeenLastCalledWith({type:'library.form',form:'rename',id:'spare'});
  await act(async()=>fireEvent.press(screen.getByRole('button',{name:'Add a filter'})));
  expect(command).toHaveBeenLastCalledWith({type:'library.form',form:'create'});
});

function dnsSnapshot():AppSnapshot {
  return {...editingSnapshot(),limits:{allowsCustomDNS:true},session:{...initialSession(),deviceDNS:false,fallback:true},dns:{customSelected:true,custom:{name:'Home',primary:'https://dns.example/query',secondary:'',valid:true,context:'primary-revision',metadata:'dns.example'},providers:[{id:'quad9-unfiltered',name:'Quad9',address:'dns10.quad9.net',selected:false}],transports:['DoH']}} as unknown as AppSnapshot;
}





test('security accepts a native biometric credential and serializes protected-surface updates through cancellation',async()=>{
  const live={...editingSnapshot(),security:{hasAuthenticationMethod:true,updatingSurface:false,showBiometrics:true,canEnableBiometrics:true},session:{...initialSession(),passcode:false,biometrics:true}} as unknown as AppSnapshot;
  let reject!:(error:Error)=>void;const command=jest.fn(()=>new Promise((_resolve,fail)=>{reject=fail;}));
  render(<Provider live={live} app={{command} as unknown as AppStore}><SecurityScreen/></Provider>);
  const pause=screen.getByRole('switch',{name:'Pause protection'});expect(pause).toBeEnabled();
  const previous=pause.props.value;
  fireEvent(pause,'valueChange',!previous);
  expect(screen.getByRole('switch',{name:'View Activity'})).toBeDisabled();
  expect(screen.getByRole('switch',{name:'Pause protection'})).toHaveProp('value',!previous);
  fireEvent(screen.getByRole('switch',{name:'View Activity'}),'valueChange',true);
  expect(command).toHaveBeenCalledTimes(1);
  await act(async()=>reject(new Error('Authentication cancelled.')));
  expect(screen.getByRole('switch',{name:'Pause protection'})).toBeEnabled();
  expect(screen.getByRole('switch',{name:'Pause protection'})).toHaveProp('value',previous);
});

test('a retained filter disables editing until its original target is restored and never sends edits to the new active filter',()=>{
  const command=jest.fn((_input:AppCommand)=>new Promise(()=>{}));const app={command} as unknown as AppStore;
  const original=editingSnapshot();
  original.session.editing=false;
  const view=render(<Provider live={original} app={app}><FilterScreen/></Provider>);
  const switched={...original,session:{...original.session,filterID:'other',activeFilterID:'other',filter:'Other'},filters:[...original.filters,{id:'other',name:'Other',count:'4',frozen:false,lists:[],shareable:true,shareSummary:'4 rules'}]};
  view.rerender(<Provider live={switched} app={app}><FilterScreen/></Provider>);
  const edit=()=>[...mockSetOptions.mock.calls].reverse().find(([options])=>options.unstable_headerRightItems)![0].unstable_headerRightItems().find((button:{label:string})=>button.label==='Edit');
  expect(edit().disabled).toBe(true);
  expect(command).toHaveBeenCalledWith({type:'filter.open',id:'active'});
  expect(screen.getByText('Loading filter…')).toBeTruthy();
  expect(screen.queryByText('Other')).toBeNull();
  view.rerender(<Provider live={{...switched,session:{...switched.session,filterID:'active',filter:'Core'}}} app={app}><FilterScreen/></Provider>);
  expect(screen.getByText('Core')).toBeTruthy();
  act(()=>edit().onPress());
  expect(command.mock.lastCall).toEqual([{type:'filter.edit',id:'active'}]);
});
test('a domain edit sheet closes instead of adopting an automation-selected filter',()=>{
  const command=jest.fn((_input:AppCommand)=>new Promise(()=>{}));const app={command} as unknown as AppStore;
  const original=editingSnapshot();
  mockGoBack.mockClear();
  const view=render(<Provider live={original} app={app}><AddDomainScreen/></Provider>);
  fireEvent.changeText(screen.getByLabelText('Domain to block'),'private.example');
  view.rerender(<Provider live={{...original,session:{...original.session,filterID:'other',activeFilterID:'other'}}} app={app}><AddDomainScreen/></Provider>);
  expect(mockGoBack).toHaveBeenCalledTimes(1);
  expect(screen.queryByLabelText('Domain to block')).toBeNull();
  expect(command).not.toHaveBeenCalled();
});

test('rapid domain and blocklist removals target individual entries while native replies are pending', () => {
  const command=jest.fn((_input:AppCommand)=>new Promise(()=>{}));
  render(<Provider live={editingSnapshot()} app={{command} as unknown as AppStore}><FilterScreen /></Provider>);
  for(const name of ['one.example','two.example','first-list','second-list']) fireEvent.press(screen.getByTestId(`filter.edit.${name}`));
  expect(command.mock.calls.filter(([input])=>input.type!=='filter.refresh')).toEqual([
    [{type:'filter.domain',id:'active',decision:'blocked',domain:'one.example',remove:true}],
    [{type:'filter.domain',id:'active',decision:'blocked',domain:'two.example',remove:true}],
    [{type:'filter.removeList',id:'active',sourceID:'first-list'}],
    [{type:'filter.removeList',id:'active',sourceID:'second-list'}],
  ]);
});

test('full-app domain addition sends one native edit and returns only after native acceptance', async () => {
  let accept!:()=>void;
  const command=jest.fn(()=>new Promise<void>(resolve=>{accept=resolve;}));
  mockGoBack.mockClear();
  render(<Provider live={editingSnapshot()} app={{command} as unknown as AppStore}><AddDomainScreen /></Provider>);
  fireEvent(screen.getByLabelText('Domain to block'),'submitEditing',{nativeEvent:{text:'NEW.Example.'}});
  expect(command).toHaveBeenCalledWith({type:'filter.domain',id:'active',domain:'NEW.Example.',decision:'blocked'});
  expect(mockGoBack).not.toHaveBeenCalled();
  await act(async()=>accept());
  expect(mockGoBack).toHaveBeenCalledTimes(1);
});


test.each([false,true])('domain clearing uses unfiltered native history availability on history=%s',async(history)=>{
  const original=AppState.currentState;Object.defineProperty(AppState,'currentState',{configurable:true,value:'active'});
  try {
    const command=jest.fn().mockResolvedValue([]);
    const app={command,subscribe:()=>()=>{},getInvalidation:()=>0} as unknown as AppStore;
    const live={hasDomainHistory:true} as AppSnapshot;
    const {rerender}=render(<Provider app={app} live={live}><DomainListScreen history={history}/></Provider>);
    await waitFor(()=>expect(screen.getByText('No domains saved yet')).toBeOnTheScreen());
    const button=()=>[...mockSetOptions.mock.calls].reverse().find(([options])=>options.unstable_headerRightItems)![0].unstable_headerRightItems()[0];
    await act(async()=>nativeDomainSearch().onChangeText({nativeEvent:{text:'missing.example'}}));
    expect(button().disabled).toBe(false);
    rerender(<Provider app={app} live={{...live,hasDomainHistory:false}}><DomainListScreen history={history}/></Provider>);
    expect(button().disabled).toBe(true);
  } finally {Object.defineProperty(AppState,'currentState',{configurable:true,value:original});}
});

test('local history enable waits for native authority, excludes repeated taps and permits retry',async()=>{
  const original=AppState.currentState;Object.defineProperty(AppState,'currentState',{configurable:true,value:'active'});
  const alert=jest.spyOn(Alert,'alert').mockImplementation(()=>{});
  try{
    let reject!:(error:Error)=>void;
    const command=jest.fn(()=>new Promise<unknown>((_resolve,fail)=>{reject=fail;}));
    const app={command,subscribe:()=>()=>{},getInvalidation:()=>0} as unknown as AppStore;
    const off={session:{...initialSession(),logs:{...initialSession().logs,'Domain logs':false}}} as unknown as AppSnapshot;
    const {rerender}=render(<Provider app={app} live={off}><DomainListScreen history/></Provider>);
    expect(screen.getByText('Domain history is off')).toBeOnTheScreen();
    expect(screen.getByText('Turn on domain history only if you want this searchable list.')).toBeOnTheScreen();
    const button=screen.getByRole('button',{name:'Turn on domain history'});
    act(()=>{fireEvent.press(button);fireEvent.press(button);});
    expect(command.mock.calls).toEqual([[{type:'domains.enableHistory'}]]);
    expect(button).toBeDisabled();
    await act(async()=>reject(new Error('Authentication cancelled.')));
    expect(alert).not.toHaveBeenCalled();
    expect(button).toBeEnabled();
    command.mockResolvedValue([]);
    await act(async()=>fireEvent.press(button));
    expect(command.mock.calls).toEqual([[{type:'domains.enableHistory'}],[{type:'domains.enableHistory'}]]);
    expect(screen.getByText('Domain history is off')).toBeOnTheScreen();
    rerender(<Provider app={app} live={{...off,session:{...off.session,logs:{...off.session.logs,'Domain logs':true}}} as AppSnapshot}><DomainListScreen history/></Provider>);
    await waitFor(()=>expect(command).toHaveBeenCalledWith(expect.objectContaining({type:'domains.query',history:true})));
    expect(screen.queryByRole('button',{name:'Turn on domain history'})).toBeNull();
  }finally{alert.mockRestore();Object.defineProperty(AppState,'currentState',{configurable:true,value:original});}
});

test('disabled Top Domains retains its native explanation without the history-only enable action',()=>{
  const off={session:{...initialSession(),logs:{...initialSession().logs,'Domain logs':false}}} as unknown as AppSnapshot;
  render(<Provider live={off}><DomainListScreen/></Provider>);
  expect(screen.getByText('Turn on domain history to see your most frequent domains.')).toBeOnTheScreen();
  expect(screen.queryByRole('button',{name:'Turn on domain history'})).toBeNull();
  expect(screen.queryByText('Touch and hold a domain to allow or block it.')).toBeNull();
});

test.each([false,true])('empty domain search retains the native reason and hides actions on history=%s',history=>{
  render(<Provider><DomainListScreen history={history}/></Provider>);
  act(()=>nativeDomainSearch().onChangeText({nativeEvent:{text:'missing.example'}}));
  expect(screen.getByText('No domains match this search')).toBeOnTheScreen();
  expect(screen.queryByText('Touch and hold a domain to allow or block it.')).toBeNull();
});

test('network log clearing becomes enabled after the native rows arrive',async()=>{
  const original=AppState.currentState;
  Object.defineProperty(AppState,'currentState',{configurable:true,value:'active'});
  try {
    let resolve!:(value:unknown)=>void;
    const command=jest.fn(()=>new Promise(yes=>{resolve=yes;}));
    const app={command,subscribe:()=>()=>{},getInvalidation:()=>0} as unknown as AppStore;
    render(<Provider app={app}><NetworkScreen /></Provider>);
    const button=()=>[...mockSetOptions.mock.calls].reverse().find(([options])=>options.unstable_headerRightItems)![0].unstable_headerRightItems()[0];
    expect(button().disabled).toBe(true);
    await act(async()=>resolve([{id:'1',title:'Connected',subtitle:'Protection active',metadata:'Now'}]));
    expect(screen.getByText('Connected')).toBeOnTheScreen();
    expect(button().disabled).toBe(false);
  } finally {Object.defineProperty(AppState,'currentState',{configurable:true,value:original});}
});

test('network rows retain native category and warning pills above their event and state text',async()=>{
  const original=AppState.currentState;
  Object.defineProperty(AppState,'currentState',{configurable:true,value:'active'});
  try {
    const rows=[
      {id:'info',title:'Connected',subtitle:'Protection active',metadata:'00:40',theme:{title:'Protection',symbol:'checkmark.shield',tone:'green'}},
      {id:'warning',title:'DNS smoke probe failed',subtitle:'Protection recovering',metadata:'00:39',theme:{title:'Smoke Test',symbol:'xmark.circle',tone:'orange'}},
    ];
    const app={command:jest.fn().mockResolvedValue(rows),subscribe:()=>()=>{},getInvalidation:()=>0} as unknown as AppStore;
    render(<Provider app={app}><NetworkScreen/></Provider>);
    await waitFor(()=>expect(screen.getByText('Protection')).toBeOnTheScreen());
    expect(screen.getByText('Connection check')).toBeOnTheScreen();
    expect(screen.getByLabelText('Protection, 00:40, Connected, Protection active')).toBeOnTheScreen();
    expect(screen.getByLabelText('Connection check, 00:39, DNS smoke probe failed, Protection recovering')).toBeOnTheScreen();
    const symbols=screen.UNSAFE_getAllByType(require('../specs/LavaDecorationNativeComponent').default);
    expect(symbols.find(s=>s.props.symbol==='checkmark.shield')?.props.tone).toBe('green');
    expect(symbols.find(s=>s.props.symbol==='xmark.circle')?.props.tone).toBe('orange');
  } finally {Object.defineProperty(AppState,'currentState',{configurable:true,value:original});}
});


test('sharing chooser preserves native empty and over-capacity gating',()=>{
  mockNavigate.mockClear();
  const filters=[
    {id:'empty',name:'Empty',shareable:false,shareSummary:'Blocks nothing'},
    {id:'huge',name:'Huge',shareable:false,shareSummary:'20,000 rules · Too big to share'},
    {id:'ready',name:'Ready',shareable:true,shareSummary:'10 rules'},
  ];
  render(<Provider live={{filters} as AppSnapshot}><ShareScreen/></Provider>);
  for(const name of ['Empty','Huge']) {
    expect(screen.getByRole('button',{name})).toBeDisabled();
    fireEvent.press(screen.getByRole('button',{name}));
  }
  expect(mockNavigate).not.toHaveBeenCalled();
  expect(screen.getByText('Blocks nothing')).toBeOnTheScreen();
  expect(screen.getByRole('button',{name:'Empty'})).toHaveAccessibilityValue({text:'Blocks nothing'});
  expect(screen.getByRole('button',{name:'Huge'})).toHaveAccessibilityValue({text:'20,000 rules · Too big to share'});
  expect(screen.getByText('20,000 rules · Too big to share')).toBeOnTheScreen();
  fireEvent.press(screen.getByRole('button',{name:'Ready'}));
  expect(mockNavigate).toHaveBeenCalledWith('ShareDetail',{id:'ready'});
});

test.each([null,'data:image/png;base64,example'])('sharing retains setup-code copying and gates the native card on QR availability (%s)',async image=>{
  const original=AppState.currentState;
  Object.defineProperty(AppState,'currentState',{configurable:true,value:'active'});
  mockShareFilterID='chosen';
  try {
    const command=jest.fn().mockResolvedValue({code:'LF1.setup-code',url:'https://example.test/filter',image});
    const app={command,subscribe:()=>()=>{},getInvalidation:()=>0} as unknown as AppStore;
    const live={filters:[{id:'chosen',name:'Renamed since opening'}]} as AppSnapshot;
    render(<Provider app={app} live={live}><ShareDetailScreen/></Provider>);
    await waitFor(()=>expect(screen.getByText('LF1.setup-code')).toBeOnTheScreen());
    expect(screen.getByText(/Your filter is shared as-is\. Review your blocklists/)).toBeOnTheScreen();
    expect(screen.queryByText('Only your block list is shared')).toBeNull();
    expect(command).toHaveBeenCalledWith({type:'share.query',id:'chosen'});
    const shareOptions=[...mockSetOptions.mock.calls].reverse().find(([options])=>options.unstable_headerRightItems)![0];
    expect(shareOptions.unstable_headerLeftItems).toBeUndefined();
    expect(shareOptions.unstable_headerRightItems()).toHaveLength(1);
    const share=()=>shareOptions.unstable_headerRightItems()[0];
    expect(share().disabled).toBe(!image);
    if(image) {
      const region=screen.getByTestId('share-qr-region');
      const layoutBefore=region.props.style;
      expect(screen.queryByLabelText('Filter QR code')).toBeNull();
      fireEvent.press(screen.getByRole('button',{name:localized('Show the QR Code')}));
      expect(screen.getByLabelText('Filter QR code')).toBeOnTheScreen();
      expect(screen.queryByRole('button',{name:localized('Show the QR Code')})).toBeNull();
      expect(screen.getByTestId('share-qr-region')).toHaveStyle(layoutBefore);
      await act(async()=>share().onPress());
      expect(command).toHaveBeenCalledWith({type:'share.card',id:'chosen'});
    } else {
      expect(screen.getByText('This filter is too large for a QR code')).toBeOnTheScreen();
      expect(screen.queryByRole('button',{name:localized('Show the QR code')})).toBeNull();
    }
    expect(screen.getByRole('button',{name:'Copy setup code'})).toBeEnabled();
    await act(async()=>fireEvent.press(screen.getByRole('button',{name:'Copy setup code'})));
    expect(command).toHaveBeenCalledWith({type:'share.copy',id:'chosen'});
    expect(screen.getByRole('button',{name:'Copied'})).toBeOnTheScreen();
  } finally {mockShareFilterID=undefined;Object.defineProperty(AppState,'currentState',{configurable:true,value:original});}
});

test.each([false,true,undefined])('sharing keeps its revealed QR and copied state only for confirmed all-off interruption: %p',async policy=>{
  const originalState=AppState.currentState;AppState.currentState='active';
  const listeners=new Set<(state:string)=>void>();
  const originalSubscribe=jest.mocked(AppState.addEventListener).getMockImplementation()!;
  const lifecycle=jest.spyOn(AppState,'addEventListener').mockImplementation((_event,callback)=>{
    const listener=callback as (state:string)=>void;listeners.add(listener);return{remove:()=>listeners.delete(listener)};
  });
  mockShareFilterID='chosen';
  try {
    const command=jest.fn().mockResolvedValue({code:'LF1.resume-code',url:'https://example.test/filter',image:'data:image/png;base64,resume'});
    const app={command,subscribe:()=>()=>{},getInvalidation:()=>0} as unknown as AppStore;
    const live={backgroundPrivacyCoverRequired:policy,filters:[{id:'chosen',name:'Resume filter'}]} as AppSnapshot;
    const view=render(<Provider app={app} live={live}><ShareDetailScreen/></Provider>);
    await waitFor(()=>expect(screen.getByText('LF1.resume-code')).toBeOnTheScreen());
    fireEvent.press(screen.getByRole('button',{name:localized('Show the QR Code')}));
    await act(async()=>fireEvent.press(screen.getByRole('button',{name:'Copy setup code'})));
    const code=screen.getByText('LF1.resume-code');
    expect(screen.getByLabelText('Filter QR code')).toBeOnTheScreen();
    expect(screen.getByRole('button',{name:'Copied'})).toBeOnTheScreen();
    act(()=>{AppState.currentState='inactive';listeners.forEach(listener=>listener('inactive'));});
    if(policy===false) {
      expect(screen.getByLabelText('Filter QR code')).toBeOnTheScreen();
      expect(screen.getByText('LF1.resume-code')).toBe(code);
      expect(screen.getByRole('button',{name:'Copied'})).toBeOnTheScreen();
    } else {
      expect(screen.queryByLabelText('Filter QR code')).toBeNull();
      expect(screen.queryByRole('button',{name:'Copied'})).toBeNull();
    }
    act(()=>{AppState.currentState='active';listeners.forEach(listener=>listener('active'));});
    await act(async()=>{});
    if(policy===false) {
      expect(screen.getByLabelText('Filter QR code')).toBeOnTheScreen();
      expect(screen.getByRole('button',{name:'Copied'})).toBeOnTheScreen();
    }
    view.unmount();
  } finally {mockShareFilterID=undefined;AppState.currentState=originalState;lifecycle.mockImplementation(originalSubscribe);}
});


test.each(['success','cancel','failure'])('standard log export excludes domain history and rejects rapid duplicate taps through %s',async outcome=>{
  let resolve!:(value:unknown)=>void;let reject!:(error:Error)=>void;
  const command=jest.fn(()=>new Promise((yes,no)=>{resolve=yes;reject=no;}));
  const alert=jest.spyOn(Alert,'alert').mockImplementation(()=>{});
  try {
    render(<Provider app={{command} as unknown as AppStore}><PrivacyScreen/></Provider>);
    expect(screen.queryByRole('switch',{name:'Include domain history in this export'})).toBeNull();
    const button=()=>screen.getByRole('button',{name:'Export local logs'});
    const tap=screen.UNSAFE_getAllByType(ListRow).find(row=>row.props.title==='Export local logs')!.props.onPress;
    act(()=>{tap();tap();});
    expect(command).toHaveBeenCalledTimes(1);
    expect(command).toHaveBeenCalledWith({type:'logs.export',domains:false});
    expect(button()).toBeDisabled();
    await act(async()=>{if(outcome==='success')resolve(null);else reject(new Error(outcome==='cancel'?'Authentication cancelled.':'Archive failed.'));});
    expect(button()).toBeEnabled();
    if(outcome==='failure')expect(screen.getByText('Couldn’t export local logs: Archive failed.')).toBeOnTheScreen();
    expect(alert).not.toHaveBeenCalled();
    fireEvent.press(button());
    expect(command).toHaveBeenCalledTimes(2);
    expect(command).toHaveBeenLastCalledWith({type:'logs.export',domains:false});
    await act(async()=>resolve(null));
  } finally {alert.mockRestore();}
});
test('an already-presented native exporter keeps a remounted privacy screen disabled',()=>{
  const command=jest.fn();
  render(<Provider app={{command} as unknown as AppStore} live={{logExportBusy:true} as AppSnapshot}><PrivacyScreen/></Provider>);
  const button=screen.getByRole('button',{name:'Export local logs'});
  expect(button).toBeDisabled();
  expect(screen.queryByRole('switch',{name:'Include domain history in this export'})).toBeNull();
  fireEvent.press(button);expect(command).not.toHaveBeenCalled();
});
test.each(['de','ja'])('Settings uses native source keys for its %s labels',locale=>{
  configurePresentation({locale,textScales:null});
  try {
    render(<Provider><SettingsScreen/></Provider>);
    for(const key of ['Privacy & Data','Nerd Stats','Network Activity']) {
      const translated=localized(key);
      if(key==='Privacy & Data')expect(translated).not.toBe(key);
      expect(screen.getByText(translated)).toBeOnTheScreen();
    }
  } finally {configurePresentation();}
});


test('Live Activity pause uses the native stepper range and preserves a non-preset value',()=>{
  const command=jest.fn().mockResolvedValue(null);
  const live={guards:[],session:{liveActivities:true},liveActivityPauseMinutes:7,liveActivityPause:{available:true,label:'Pause length: 7 min',minutes:Array.from({length:30},(_,i)=>i+1)}} as unknown as AppSnapshot;
  render(<Provider app={{command} as unknown as AppStore} live={live}><CustomizationScreen/></Provider>);
  const stepper=screen.getByTestId('Live Activity pause length');
  expect(stepper).toHaveProp('stepper',true);expect(stepper).toHaveProp('value','7');
  expect(stepper.props.options.map((option:{value:string})=>option.value)).toEqual(Array.from({length:30},(_,i)=>String(i+1)));
  for(const value of ['1','30'])fireEvent(stepper,'valueChange',{nativeEvent:{value}});
  expect(command.mock.calls.filter(([event])=>event.type!=='haptic')).toEqual([[{type:'settings.set',key:'liveActivityPauseMinutes',value:1}],[{type:'settings.set',key:'liveActivityPauseMinutes',value:30}]]);
  for(const value of ['0','31'])fireEvent(stepper,'valueChange',{nativeEvent:{value}});
  expect(command.mock.calls.filter(([event])=>event.type!=='haptic')).toHaveLength(2);
});

test('filter review can retry a failed save and obtains a new token when the active filter changes',async()=>{
  let tokens=0;let attempts=0;
  const command=jest.fn(async (request:{type:string})=>{
    if(request.type==='filter.review')return `token-${++tokens}`;
    if(request.type==='filter.apply'&&++attempts===1)throw new Error('Save failed; try again.');
    return null;
  });
  const app={command} as unknown as AppStore;const live=editingSnapshot();
  const view=render(<Provider app={app} live={live}><ReviewScreen/></Provider>);
  const confirm=()=>screen.getByRole('button',{name:'Confirm changes'});
  await waitFor(()=>expect(confirm()).toBeEnabled());
  await act(async()=>fireEvent.press(confirm()));
  expect(screen.getByText('Save failed; try again.')).toBeOnTheScreen();
  await act(async()=>fireEvent.press(confirm()));
  expect(command.mock.calls.filter(([request])=>request.type==='filter.apply')).toEqual([
    [{type:'filter.apply',id:'active',review:'token-1'}],[{type:'filter.apply',id:'active',review:'token-1'}],
  ]);
  view.rerender(<Provider app={app} live={{...live,session:{...live.session,activeFilterID:'other'}}}><ReviewScreen/></Provider>);
  await waitFor(()=>expect(tokens).toBe(2));
  await waitFor(()=>expect(confirm()).toBeEnabled());
  await act(async()=>fireEvent.press(confirm()));
  expect(command).toHaveBeenLastCalledWith({type:'filter.apply',id:'active',review:'token-2'});
});

test('Privacy reports a native Files save failure after the exporter closes',()=>{
  render(<Provider live={{logExportBusy:false,logExportError:'Could not save local logs: Storage unavailable.'} as AppSnapshot}><PrivacyScreen/></Provider>);
  expect(screen.getByText('Could not save local logs: Storage unavailable.')).toBeOnTheScreen();
  expect(screen.getByRole('button',{name:'Export local logs'})).toBeEnabled();
});

test('domain-history actions retain native decision metadata and Copy dispatch',async()=>{
  const original=AppState.currentState;Object.defineProperty(AppState,'currentState',{configurable:true,value:'active'});
  const alert=jest.spyOn(Alert,'alert').mockImplementation(()=>{});
  try {
    const command=jest.fn().mockImplementation(command=>Promise.resolve(command.type==='domains.query'?[{id:'event',domain:'paused.example',metadata:'Allowed on Pause · Now'}]:{}));
    const app={command,subscribe:()=>()=>{},getInvalidation:()=>0} as unknown as AppStore;
    render(<Provider app={app} live={{hasDomainHistory:true} as AppSnapshot}><DomainListScreen history/></Provider>);
    await waitFor(()=>expect(screen.getByText('Allowed on Pause · Now')).toBeOnTheScreen());
    fireEvent(screen.getByTestId('domain-menu.event'),'action',{nativeEvent:{id:'copy'}});
    expect(alert).not.toHaveBeenCalled();
    await waitFor(()=>expect(command).toHaveBeenCalledWith({type:'domains.copy',domain:'paused.example'}));
  } finally {alert.mockRestore();Object.defineProperty(AppState,'currentState',{configurable:true,value:original});}
});

const pickerCatalog={sections:[{title:'Built-in',sources:[{id:'first-list',name:'First',licenseName:'MIT'},{id:'second-list',name:'Second',licenseName:'MIT'},{id:'third-list',name:'Third',licenseName:'MIT'}]},{title:'Your Lists',isCustom:true,sources:[{id:'custom-list',name:'Custom',licenseName:'User supplied',sourceURL:'https://lists.example/private.txt'}]}],count:100,budget:500000,pending:0,exceeded:false,summary:'About 100 of 500K rules',fraction:0.0002,indeterminate:false,atOrOverBudget:false};
function pickerSnapshot(ids=['first-list','second-list']) {
  const live=editingSnapshot();
  return {...live,plus:{enabled:false} as AppSnapshot['plus'],session:{...live.session,blocklists:ids},limits:{...live.limits,allowsCustomBlocklists:true}};
}
function pickerToolbar() {
  return [...mockSetOptions.mock.calls].reverse().find(([options])=>options.unstable_headerRightItems)![0].unstable_headerRightItems().find((button:{label:string})=>button.label===localized('Bring your own list'));
}
describe('native blocklist picker',()=>{
let previousAppState: typeof AppState.currentState;
beforeEach(()=>{previousAppState=AppState.currentState;Object.defineProperty(AppState,'currentState',{configurable:true,value:'active'});});
afterEach(()=>{Object.defineProperty(AppState,'currentState',{configurable:true,value:previousAppState});});
test.each([
  {count:999,budget:2000000,summary:'About 999 of 2M rules'},
  {count:1200000,budget:2000000,summary:'About 1.2M of 2M rules'},
  {count:0,budget:2000000,summary:'Calculating rule usage… (1 list pending)',pending:1,indeterminate:true},
])('renders the native picker summary verbatim: $summary',async value=>{
  const command=jest.fn(async()=>({...pickerCatalog,...value}));
  render(<Provider app={{command} as unknown as AppStore} live={pickerSnapshot()}><AddBlocklistScreen/></Provider>);
  await waitFor(()=>expect(screen.getByText(value.summary)).toBeOnTheScreen());
  expect(screen.queryByText(/2,000K/)).toBeNull();
  if('indeterminate' in value)expect(screen.getByRole('progressbar').props.accessibilityValue).toEqual({text:'calculating'});
});
test.each([false,true])('over-limit selections offer Upgrade only on Free (Plus=%s)',async plus=>{
  const command=jest.fn(async()=>({...pickerCatalog,exceeded:true}));
  const live=pickerSnapshot();live.plus.enabled=plus;
  render(<Provider app={{command} as unknown as AppStore} live={live}><AddBlocklistScreen/></Provider>);
  await waitFor(()=>expect(screen.getByText(pickerCatalog.summary)).toBeOnTheScreen());
  if(plus){expect(screen.getByRole('button',{name:'Save selection'})).toBeDisabled();expect(screen.queryByRole('button',{name:'Upgrade'})).toBeNull();}
  else {await act(async()=>fireEvent.press(screen.getByRole('button',{name:'Upgrade'})));expect(mockNavigate).toHaveBeenLastCalledWith('Upgrade');}
});
test.each([['de','  WERBUNG & TRACKER  '],['ja','広告とトラッカー']])('searches the displayed category in %s',async(locale,search)=>{
  configurePresentation({locale,textScales:null});
  try {
    const command=jest.fn(async()=>({...pickerCatalog,sections:[{...pickerCatalog.sections[0],title:'Ads & Trackers'},pickerCatalog.sections[1]]}));
    render(<Provider app={{command} as unknown as AppStore} live={pickerSnapshot()}><AddBlocklistScreen/></Provider>);
    await waitFor(()=>expect(screen.getByRole('button',{name:'First, MIT'})).toBeOnTheScreen());
    expect(screen.getByLabelText(localized('Delete custom blocklist'))).toBeOnTheScreen();
    fireEvent.changeText(screen.getByLabelText(localized('Search lists or categories')),search);
    expect(screen.getByRole('button',{name:'First, MIT'})).toBeOnTheScreen();
    expect(screen.queryByRole('button',{name:'Custom, User supplied'})).toBeNull();
  } finally {configurePresentation();}
});
test.each([['  mit  ','First, MIT'],['lists.example','Custom, User supplied']])('retains native license and custom URL search: %s',async(search,name)=>{
  const command=jest.fn(async()=>pickerCatalog);
  render(<Provider app={{command} as unknown as AppStore} live={pickerSnapshot()}><AddBlocklistScreen/></Provider>);
  await waitFor(()=>expect(screen.getByRole('button',{name:'First, MIT'})).toBeOnTheScreen());
  fireEvent.changeText(screen.getByLabelText('Search blocklists or categories'),search);
  expect(screen.getByRole('button',{name})).toBeOnTheScreen();
});
test('opening and cancelling a custom list keeps checkbox edits local until Save Selection',async()=>{
  const command=jest.fn(async(input:AppCommand)=>input.type==='catalog.query'?pickerCatalog:undefined);
  const app={command} as unknown as AppStore;const live=pickerSnapshot();
  const view=render(<Provider live={live} app={app}><AddBlocklistScreen/></Provider>);
  await waitFor(()=>expect(screen.getByRole('button',{name:'Third, MIT'})).toBeOnTheScreen());
  fireEvent.press(screen.getByRole('button',{name:'Third, MIT'}));
  await waitFor(()=>expect(screen.getByRole('button',{name:'Third, MIT'}).props.accessibilityState.selected).toBe(true));
  await act(async()=>pickerToolbar().onPress());
  expect(command).toHaveBeenCalledWith({type:'filter.customList',id:'active',ids:['first-list','second-list','third-list']});
  expect(command.mock.calls.filter(([input])=>input.type==='filter.lists')).toEqual([]);
  // Dismissing the native form publishes an unchanged draft; the local picker
  // keeps its staged checkboxes until the user closes or saves that picker.
  view.rerender(<Provider live={{...live,revision:2}} app={app}><AddBlocklistScreen/></Provider>);
  expect(screen.getByRole('button',{name:'Third, MIT'}).props.accessibilityState.selected).toBe(true);
  view.unmount();
  render(<Provider live={live} app={app}><AddBlocklistScreen/></Provider>);
  await waitFor(()=>expect(screen.getByRole('button',{name:'Third, MIT'}).props.accessibilityState.selected).toBe(false));
  fireEvent.press(screen.getByRole('button',{name:'Third, MIT'}));
  await waitFor(()=>expect(screen.getByRole('button',{name:'Save selection'})).toBeEnabled());
  await act(async()=>fireEvent.press(screen.getByRole('button',{name:'Save selection'})));
  expect(command).toHaveBeenLastCalledWith({type:'filter.lists',id:'active',ids:['first-list','second-list','third-list']});
});
test('checkbox changes retain catalog rows while native selection totals refresh',async()=>{
  let finish!:(value:typeof pickerCatalog)=>void;
  const command=jest.fn((input:AppCommand)=>input.type==='catalog.query'&&input.ids.includes('third-list')?new Promise<typeof pickerCatalog>(resolve=>{finish=resolve;}):Promise.resolve(pickerCatalog));
  render(<Provider live={pickerSnapshot()} app={{command} as unknown as AppStore}><AddBlocklistScreen/></Provider>);
  await waitFor(()=>expect(screen.getByRole('button',{name:'Third, MIT'})).toBeOnTheScreen());
  const row=screen.getByRole('button',{name:'Third, MIT'});
  fireEvent.press(row);
  expect(screen.getByRole('button',{name:'Third, MIT'})).toBe(row);
  expect(row.props.accessibilityState.selected).toBe(true);
  expect(screen.getByRole('button',{name:'Custom, User supplied'})).toBeOnTheScreen();
  expect(screen.queryByText('Loading blocklists…')).toBeNull();
  expect(screen.getByRole('button',{name:'Save selection'})).toBeDisabled();
  await act(async()=>finish({...pickerCatalog,count:200,summary:'About 200 of 500K rules'}));
  expect(screen.getByRole('button',{name:'Third, MIT'})).toBe(row);
  expect(screen.getByText('About 200 of 500K rules')).toBeOnTheScreen();
  expect(screen.getByRole('button',{name:'Save selection'})).toBeEnabled();
  const save=screen.UNSAFE_getByType(LavaActionButton).props.onPress;
  await act(async()=>{save();save();});
  expect(command.mock.calls.filter(([input])=>input.type==='filter.lists')).toHaveLength(1);
});
test('a staged list disappearing from native availability cannot poison Save Selection',async()=>{
  const withoutThird:typeof pickerCatalog=JSON.parse(JSON.stringify(pickerCatalog));
  for(const section of withoutThird.sections){
    const index=section.sources.findIndex(source=>source.id==='third-list');
    if(index>=0)section.sources.splice(index,1);
  }
  let finish!:(value:typeof pickerCatalog)=>void;
  let removed=false;
  const command=jest.fn((input:AppCommand)=>{
    if(input.type!=='catalog.query')return Promise.resolve(undefined);
    if(removed)return Promise.resolve(withoutThird);
    if(input.ids.includes('third-list'))return new Promise<typeof pickerCatalog>(resolve=>{finish=resolve;});
    return Promise.resolve(pickerCatalog);
  });
  render(<Provider live={pickerSnapshot()} app={{command} as unknown as AppStore}><AddBlocklistScreen/></Provider>);
  await waitFor(()=>expect(screen.getByRole('button',{name:'Third, MIT'})).toBeOnTheScreen());
  fireEvent.press(screen.getByRole('button',{name:'Third, MIT'}));
  await waitFor(()=>expect(finish).toBeDefined());
  removed=true;
  await act(async()=>finish(withoutThird));
  await waitFor(()=>expect(screen.queryByRole('button',{name:'Third, MIT'})).toBeNull());
  fireEvent.press(screen.getByRole('button',{name:'First, MIT'}));
  await waitFor(()=>expect(screen.getByRole('button',{name:'Save selection'})).toBeEnabled());
  await act(async()=>fireEvent.press(screen.getByRole('button',{name:'Save selection'})));
  expect(command).toHaveBeenLastCalledWith({type:'filter.lists',id:'active',ids:['second-list']});
});
test('a failed catalog refresh preserves a newly added native custom list when saving other edits',async()=>{
  const snapshot=(ids?:string[])=>{
    const live=pickerSnapshot(ids);
    return {...live,security:{...live.security,unavailable:false},session:{...live.session,protectedActions:{...live.session.protectedActions,'Update domains and lists':false}}};
  };
  const command=jest.fn(async(input:AppCommand)=>{
    if(input.type!=='catalog.query')return undefined;
    if(input.ids.includes('new-custom-list'))throw new Error('Catalog temporarily unavailable.');
    return pickerCatalog;
  });
  const app={command} as unknown as AppStore;
  const view=render(<Provider live={snapshot()} app={app}><AddBlocklistScreen/></Provider>);
  await waitFor(()=>expect(screen.getByRole('button',{name:'First, MIT'})).toBeOnTheScreen());
  view.rerender(<Provider live={snapshot(['first-list','second-list','new-custom-list'])} app={app}><AddBlocklistScreen/></Provider>);
  await waitFor(()=>expect(command).toHaveBeenCalledWith({type:'catalog.query',ids:['first-list','second-list','new-custom-list']}));
  await act(async()=>{});
  fireEvent.press(screen.getByRole('button',{name:'First, MIT'}));
  await waitFor(()=>expect(screen.getByRole('button',{name:'Save selection'})).toBeEnabled());
  await act(async()=>fireEvent.press(screen.getByRole('button',{name:'Save selection'})));
  expect(command).toHaveBeenLastCalledWith({type:'filter.lists',id:'active',ids:['second-list','new-custom-list']});
});
test('deleting a custom list preserves other unconfirmed checkbox changes without saving them',async()=>{
  const alert=jest.spyOn(Alert,'alert').mockImplementation(()=>{});
  try {
    const command=jest.fn(async(input:AppCommand)=>input.type==='catalog.query'?pickerCatalog:undefined);
    const app={command} as unknown as AppStore;const live=pickerSnapshot(['first-list','second-list','custom-list']);
    const view=render(<Provider live={live} app={app}><AddBlocklistScreen/></Provider>);
    await waitFor(()=>expect(screen.getByRole('button',{name:'Third, MIT'})).toBeOnTheScreen());
    fireEvent.press(screen.getByRole('button',{name:'Third, MIT'}));
    await waitFor(()=>expect(screen.getByRole('button',{name:'First, MIT'})).toBeOnTheScreen());
    fireEvent.press(screen.getByRole('button',{name:'First, MIT'}));
    await waitFor(()=>expect(screen.getByRole('button',{name:'Third, MIT'}).props.accessibilityState.selected).toBe(true));
    fireEvent.press(screen.getByLabelText('Delete custom blocklist'));
    await act(async()=>alert.mock.calls.at(-1)![2]!.find(button=>button.style==='destructive')!.onPress!());
    view.rerender(<Provider live={pickerSnapshot()} app={app}><AddBlocklistScreen/></Provider>);
    await waitFor(()=>expect(screen.getByRole('button',{name:'Third, MIT'})).toBeOnTheScreen());
    expect(screen.getByRole('button',{name:'First, MIT'}).props.accessibilityState.selected).toBe(false);
    expect(screen.getByRole('button',{name:'Third, MIT'}).props.accessibilityState.selected).toBe(true);
    expect(screen.getByRole('button',{name:'Custom, User supplied'}).props.accessibilityState.selected).toBe(false);
    expect(command).toHaveBeenCalledWith({type:'filter.deleteCustomList',id:'active',sourceID:'custom-list'});
    expect(command.mock.calls.filter(([input])=>input.type==='filter.lists')).toEqual([]);
    await act(async()=>fireEvent.press(screen.getByRole('button',{name:'Save selection'})));
    expect(command).toHaveBeenLastCalledWith({type:'filter.lists',id:'active',ids:['second-list','third-list']});
  } finally {alert.mockRestore();}
});
test('a successful native custom-list addition adopts the resulting draft selection',async()=>{
  const command=jest.fn(async(input:AppCommand)=>input.type==='catalog.query'?pickerCatalog:undefined);
  const app={command} as unknown as AppStore;
  const view=render(<Provider live={pickerSnapshot()} app={app}><AddBlocklistScreen/></Provider>);
  await waitFor(()=>expect(screen.getByRole('button',{name:'Third, MIT'})).toBeOnTheScreen());
  fireEvent.press(screen.getByRole('button',{name:'Third, MIT'}));
  await waitFor(()=>expect(screen.getByRole('button',{name:'Third, MIT'}).props.accessibilityState.selected).toBe(true));
  view.rerender(<Provider live={pickerSnapshot(['first-list','second-list','custom-list'])} app={app}><AddBlocklistScreen/></Provider>);
  await waitFor(()=>expect(screen.getByRole('button',{name:'Custom, User supplied'}).props.accessibilityState.selected).toBe(true));
  expect(screen.getByRole('button',{name:'Third, MIT'}).props.accessibilityState.selected).toBe(false);
  expect(command.mock.calls.filter(([input])=>input.type==='filter.lists')).toEqual([]);
});
});

describe('standalone domain review cancellation',()=>{
  let previousAppState: typeof AppState.currentState;
  beforeEach(()=>{previousAppState=AppState.currentState;Object.defineProperty(AppState,'currentState',{configurable:true,value:'active'});mockNavigate.mockClear();});
  afterEach(()=>{mockStandaloneReview=undefined;Object.defineProperty(AppState,'currentState',{configurable:true,value:previousAppState});});
  test.each([false,true])('domain actions transfer native draft ownership to Review (history %s)',async(history)=>{
    const alert=jest.spyOn(Alert,'alert').mockImplementation(()=>{});
    try {
      const command=jest.fn(async(input:AppCommand)=>input.type==='domains.query'?[{id:'event',domain:'tracker.example',metadata:'Blocked'}]:{id:'active',standaloneReview:'domain-review'});
      render(<Provider live={editingSnapshot()} app={{command} as unknown as AppStore}><DomainListScreen history={history}/></Provider>);
      await waitFor(()=>expect(screen.getByTestId('domain-menu.event')).toBeOnTheScreen());
      await act(async()=>fireEvent(screen.getByTestId('domain-menu.event'),'action',{nativeEvent:{id:'blocked'}}));
      expect(command).toHaveBeenCalledWith({type:'domains.stage',domain:'tracker.example',decision:'blocked'});
      expect(mockNavigate).toHaveBeenLastCalledWith('Review',{id:'active',standaloneReview:'domain-review'});
    } finally {alert.mockRestore();}
  });
  test('a domain stage that finishes after its source closes is discarded instead of opening a stale review',async()=>{
    const alert=jest.spyOn(Alert,'alert').mockImplementation(()=>{});
    try {
      let resolve!: (value:{id:string;standaloneReview:string})=>void;
      const staged=new Promise<{id:string;standaloneReview:string}>(accept=>{resolve=accept;});
      const command=jest.fn((input:AppCommand)=>input.type==='domains.query'?Promise.resolve([{id:'event',domain:'tracker.example',metadata:'Blocked'}]):input.type==='domains.stage'?staged:Promise.resolve(null));
      const view=render(<Provider live={editingSnapshot()} app={{command} as unknown as AppStore}><DomainListScreen history/></Provider>);
      await waitFor(()=>expect(screen.getByTestId('domain-menu.event')).toBeOnTheScreen());
      act(()=>fireEvent(screen.getByTestId('domain-menu.event'),'action',{nativeEvent:{id:'allowed'}}));
      view.unmount();
      await act(async()=>resolve({id:'active',standaloneReview:'late-review'}));
      expect(mockNavigate).not.toHaveBeenCalled();
      expect(command).toHaveBeenLastCalledWith({type:'domains.cancel',token:'late-review'});
    } finally {alert.mockRestore();}
  });
  test.each([false,true])('Review dismissal cancels only standalone domain ownership (%s)',async(standalone)=>{
    mockStandaloneReview=standalone?'owned-domain-review':undefined;
    const command=jest.fn(async()=> 'review-token');
    const view=render(<Provider live={editingSnapshot()} app={{command} as unknown as AppStore}><ReviewScreen/></Provider>);
    await waitFor(()=>expect(screen.getByRole('button',{name:'Confirm changes'})).toBeEnabled());
    view.unmount();
    expect(command.mock.calls).toEqual(standalone?[[{type:'filter.review',id:'active'}],[{type:'domains.cancel',token:'owned-domain-review'}]]:[[{type:'filter.review',id:'active'}]]);
  });
  test('a standalone confirmation retains its native origin and can discard after a failed apply',async()=>{
    mockStandaloneReview='owned-domain-review';
    const command=jest.fn(async(input:AppCommand)=>{if(input.type==='filter.apply')throw new Error('Try again.');return 'review-token';});
    const live=editingSnapshot();live.draft={...live.draft,allowed:['trusted.example']};
    const view=render(<Provider live={live} app={{command} as unknown as AppStore}><ReviewScreen/></Provider>);
    await waitFor(()=>expect(screen.getByRole('button',{name:'Confirm changes'})).toBeEnabled());
    expect(screen.getByText('Allowed exceptions let a domain through even when a blocklist would catch it.')).toBeOnTheScreen();
    await act(async()=>fireEvent.press(screen.getByRole('button',{name:'Confirm changes'})));
    expect(command).toHaveBeenCalledWith({type:'filter.apply',id:'active',review:'review-token',standaloneReview:'owned-domain-review'});
    expect(screen.getByText('Try again.')).toBeOnTheScreen();
    view.unmount();
    expect(command).toHaveBeenLastCalledWith({type:'domains.cancel',token:'owned-domain-review'});
  });
});

test.each([false,true])('Settings keeps utility destinations concise with protection and logs %s',enabled=>{
  const live={...editingSnapshot(),version:'1.5.0',build:'123',sourceRevision:'006e019d2ab29bc19f05a62d50b2d5f9f981ac45',account:{status:'Ready'},plus:{enabled},
    session:{...initialSession(),deviceDNS:enabled,fallback:enabled,passcode:enabled,logs:{'Network activity':enabled}},
    settingsSummary:{dns:'dynamic DNS',privacy:'dynamic logs',security:'dynamic security'}} as unknown as AppSnapshot;
  render(<Provider live={live}><SettingsScreen/></Provider>);
  for(const summary of ['Manage your account and encrypted backup','Explore Lava Plus','Choose how Lava looks up websites','Manage local logs and privacy','Control access to Lava','Connection and protection events'])expect(screen.queryByText(summary)).toBeNull();
  for(const title of ['Account & Backup','Customization','Privacy & Data','Security','Feedback','Legal Notices'])expect(screen.getByText(localized(title))).toBeOnTheScreen();
  expect(screen.getByTestId('connection.dns')).toBeOnTheScreen();
  for(const summary of Object.values(live.settingsSummary))expect(screen.queryByText(summary)).toBeNull();
  expect(screen.getByText('Lava 1.5.0 (build 123) · 006e019d2ab2')).toBeOnTheScreen();
});
test.each([['fr',false],['fr',true],['ja',false],['ja',true]] as const)('filter library localizes its single upgrade note for %s and omits it for Plus=%s', (locale,plus)=>{
  configurePresentation({locale,textScales:null});
  try {
    const live={...editingSnapshot(),plus:{enabled:plus}} as AppSnapshot;
    render(<Provider live={live}><LibraryScreen/></Provider>);
    if(plus) {
      expect(screen.queryByText(localized('Manage more than three filters with Lava Plus.'))).toBeNull();
      expect(screen.queryByRole('link')).toBeNull();
    } else {
      const link=screen.getByRole('link',{name:locale==='fr'?'Passez à la version supérieure':'アップグレード'});
      fireEvent.press(link);
      expect(mockNavigate).toHaveBeenLastCalledWith('Upgrade');
      expect(screen.getByText(localized('Manage more than three filters with Lava Plus.'))).toBeOnTheScreen();
    }
    expect(screen.queryByText(/of .* filters/)).toBeNull();
  } finally {configurePresentation();}
});


describe('native backup maintenance confirmations',()=>{
  test.each([
    ['en','Delete online backup copy','backup.delete',"Permanently deletes your account's encrypted backup — this can't be undone. Backup stays on, and a fresh copy uploads next time."],
    ['ja','Delete online backup copy','backup.delete',"Permanently deletes your account's encrypted backup — this can't be undone. Backup stays on, and a fresh copy uploads next time."],
    ['en','Turn off & delete backup','backup.disable',"Turns off backup on this device and permanently deletes your account's copy. This can't be undone — you can set up a new backup later."],
    ['ja','Turn off & delete backup','backup.disable',"Turns off backup on this device and permanently deletes your account's copy. This can't be undone — you can set up a new backup later."],
  ])('preserves the native %s confirmation for %s',async(locale,title,type,message)=>{
    configurePresentation({locale,textScales:null});
    const alert=jest.spyOn(Alert,'alert').mockImplementation(()=>{});
    try {
      const command=jest.fn(async(_input:AppCommand)=>undefined);
      const live={account:{signedIn:true},backup:{enablement:backupEnablement(true,true),configured:true,automatic:true,busy:false}} as AppSnapshot;
      render(<Provider live={live} app={{command} as unknown as AppStore}><AccountScreen/></Provider>);
      fireEvent.press(screen.getByRole('button',{name:localized('Backup maintenance')}));
      if(type==='backup.disable')fireEvent(screen.getByRole('switch',{name:localized('Enable backup')}),'valueChange',false);
      else fireEvent.press(screen.getByRole('button',{name:localized(title)}));
      expect(alert.mock.calls.at(-1)![0]).toBe(localized(title+'?'));
      expect(alert.mock.calls.at(-1)![1]).toBe(localized(message));
      expect(command.mock.calls.filter(([input])=>input.type!=='backup.refresh')).toHaveLength(0);
      const destructive=alert.mock.calls.at(-1)![2]!.find(button=>button.style==='destructive')!;
      expect(destructive.text).toBe(localized(title));
      await act(async()=>destructive.onPress!());
      expect(command.mock.calls.filter(([input])=>input.type!=='backup.refresh')).toHaveLength(1);
      expect(command).toHaveBeenCalledWith({type});
    } finally {alert.mockRestore();configurePresentation();}
  });
});

describe('network activity pagination',()=>{
  let previousAppState: typeof AppState.currentState;
  beforeEach(()=>{previousAppState=AppState.currentState;Object.defineProperty(AppState,'currentState',{configurable:true,value:'active'});});
  afterEach(()=>Object.defineProperty(AppState,'currentState',{configurable:true,value:previousAppState}));
  const rows=Array.from({length:300},(_,index)=>({id:String(index),title:`Event ${index+1}`,subtitle:'Connection',metadata:'Now'}));
  const store=(entries=rows)=>({command:jest.fn(async()=>entries)} as unknown as AppStore);
  const end=()=>fireEvent.scroll(screen.UNSAFE_getByType(ScrollView),{nativeEvent:{contentOffset:{y:1000},layoutMeasurement:{height:700},contentSize:{height:1700}}});
  test('starts with 30 rows and appends one page when the user reaches the end',async()=>{
    render(<Provider app={store()}><NetworkScreen/></Provider>);
    await waitFor(()=>expect(screen.getByText('Event 30')).toBeOnTheScreen());
    expect(screen.queryByText('Event 31')).toBeNull();
    end();
    expect(screen.getByText('Event 60')).toBeOnTheScreen();
    expect(screen.queryByText('Event 61')).toBeNull();
    expect(screen.queryByText('Event 300')).toBeNull();
  });
  test('refreshes preserve the visible page until the entry count changes',async()=>{
    const view=render(<Provider app={store()}><NetworkScreen/></Provider>);
    await waitFor(()=>expect(screen.getByText('Event 30')).toBeOnTheScreen());
    end();expect(screen.getByText('Event 60')).toBeOnTheScreen();
    await act(async()=>view.rerender(<Provider app={store([...rows])}><NetworkScreen/></Provider>));
    expect(screen.getByText('Event 60')).toBeOnTheScreen();
    await act(async()=>view.rerender(<Provider app={store(rows.slice(0,299))}><NetworkScreen/></Provider>));
    expect(screen.getByText('Event 30')).toBeOnTheScreen();
    expect(screen.queryByText('Event 31')).toBeNull();
  });
});




test('Filters uses contextual Import and Share actions while keeping its collection directly accessible',()=>{
  render(<Provider><FiltersScreen/></Provider>);
  expect(screen.queryByText('Got a good filter?')).toBeNull();
  expect(screen.getByText('Now filtering')).toBeOnTheScreen();
  expect(screen.queryByRole('button',{name:'Share your filter'})).toBeNull();
  act(()=>toolbarItems().find((item:{label:string})=>item.label==='Import').onPress());
  expect(mockNavigate).toHaveBeenLastCalledWith('Import');
  fireEvent.press(screen.getByRole('button',{name:'Switch or manage filters'}));
  expect(mockNavigate).toHaveBeenLastCalledWith('Library');
});

test('native fallback subscription offers remain actionable while StoreKit retries',async()=>{
  const command=jest.fn(async()=>null);
  const live={plus:{enabled:false,checking:false,busy:false,message:'',offers:[{id:'yearly',title:'Yearly',subtitle:'Fallback pitch',price:'$29.99'},{id:'monthly',title:'Monthly',subtitle:'Flexible',price:'$3.99'},{id:'commitment',title:'Yearly, paid monthly',subtitle:'Commit for 12 months',price:'$2.99',commitmentPrice:'$35.88 total'}]}} as unknown as AppSnapshot;
  const view=render(<Provider app={{command} as unknown as AppStore} live={live}><UpgradeScreen/></Provider>);
  await act(async()=>fireEvent.press(screen.getByRole('button',{name:'Yearly'})));
  expect(command).toHaveBeenCalledWith({type:'purchase.buy',id:'yearly'});
  expect(screen.getByText('$35.88 total')).toBeOnTheScreen();
  view.rerender(<Provider app={{command} as unknown as AppStore} live={{...live,plus:{...live.plus,busy:true}}}><UpgradeScreen/></Provider>);
  expect(screen.getByRole('button',{name:'Yearly'})).toBeDisabled();
  expect(screen.getByRole('button',{name:'Monthly'})).toBeDisabled();
});




test.each(['Yearly','Restore Purchase','Manage Subscription'])('the %s action excludes queued StoreKit replays through completion or cancellation',async title=>{
  let finish!:(value:null)=>void;
  const pending=new Promise<null>(resolve=>{finish=resolve;});
  const kinds=['purchase.buy','purchase.restore','purchase.manage'];
  const command=jest.fn((input:AppCommand)=>kinds.includes(input.type)?pending:Promise.resolve(null));
  const live={plus:{enabled:title==='Manage Subscription',checking:false,busy:false,message:'',offers:[{id:'yearly',title:'Yearly',subtitle:'Yearly plan',price:'$29.99'},{id:'monthly',title:'Monthly',subtitle:'Monthly plan',price:'$3.99'}]}} as unknown as AppSnapshot;
  render(<Provider live={live} app={{command} as unknown as AppStore}><UpgradeScreen/></Provider>);
  const buttons=screen.UNSAFE_getAllByType(ListRow).filter(node=>['Yearly','Monthly','Restore Purchase','Manage Subscription'].includes(node.props.title));
  const chosen=buttons.find(node=>node.props.title===title)!;
  act(()=>{chosen.props.onPress();for(const button of buttons)button.props.onPress();});
  expect(command.mock.calls.filter(([input])=>kinds.includes(input.type))).toHaveLength(1);
  for(const button of buttons)expect(screen.getByRole('button',{name:localized(button.props.title)})).toBeDisabled();
  // StoreKit cancellation is a native completed result. Nothing from the old
  // tap burst may open another sheet once that operation has settled.
  await act(async()=>finish(null));
  expect(command.mock.calls.filter(([input])=>kinds.includes(input.type))).toHaveLength(1);
  for(const button of buttons)expect(screen.getByRole('button',{name:localized(button.props.title)})).toBeEnabled();
  await act(async()=>fireEvent.press(screen.getByRole('button',{name:localized(title)})));
  expect(command.mock.calls.filter(([input])=>kinds.includes(input.type))).toHaveLength(2);
});

test.each(['Sign in with Apple','Sign in with Google'])('%s cannot queue another provider and can retry after cancelled authentication',async title=>{
  let reject!:(error:Error)=>void;
  const command=jest.fn(()=>new Promise<null>((_resolve,fail)=>{reject=fail;}));
  const alert=jest.spyOn(Alert,'alert').mockImplementation(()=>{});
  try{
    const live={account:{signedIn:false,busy:false},backup:{enablement:backupEnablement(false,false),configured:false,busy:false}} as AppSnapshot;
    render(<Provider live={live} app={{command} as unknown as AppStore}><AccountScreen/></Provider>);
    const buttons=screen.UNSAFE_getAllByType(ListRow).filter(node=>['Sign in with Apple','Sign in with Google'].includes(node.props.title));
    act(()=>{buttons.find(node=>node.props.title===title)!.props.onPress();for(const button of buttons)button.props.onPress();});
    expect(command).toHaveBeenCalledTimes(1);
    for(const button of buttons)expect(screen.getByRole('button',{name:localized(button.props.title)})).toBeDisabled();
    await act(async()=>reject(new Error('Authentication cancelled.')));
    expect(alert).not.toHaveBeenCalled();
    for(const button of buttons)expect(screen.getByRole('button',{name:localized(button.props.title)})).toBeEnabled();
    command.mockResolvedValueOnce(null);
    await act(async()=>fireEvent.press(screen.getByRole('button',{name:localized(title)})));
    expect(command).toHaveBeenCalledTimes(2);
  }finally{alert.mockRestore();}
});

test.each(['backup.now','backup.delete','backup.disable'])('%s excludes replayed backup operations before the native busy snapshot',async type=>{
  let reject!:(error:Error)=>void;
  const command=jest.fn((input:AppCommand)=>input.type==='backup.refresh'?Promise.resolve(null):new Promise<null>((_resolve,fail)=>{reject=fail;}));
  const alert=jest.spyOn(Alert,'alert').mockImplementation(()=>{});
  try{
    const live={account:{signedIn:true,busy:false},backup:{enablement:backupEnablement(true,true),configured:true,automatic:true,busy:false}} as AppSnapshot;
    render(<Provider live={live} app={{command} as unknown as AppStore}><AccountScreen/></Provider>);
    fireEvent.press(screen.getByRole('button',{name:localized('Backup maintenance')}));
    const rows=screen.UNSAFE_getAllByType(ListRow);
    const now=rows.find(node=>node.props.title==='Back Up Now')!.props.onPress;
    const actions:Record<string,()=>void>={'backup.now':now};
    for(const [label,kind] of [['Delete online backup copy','backup.delete'],['Turn off & delete backup','backup.disable']]){
      if(kind==='backup.disable')fireEvent(screen.getByRole('switch',{name:localized('Enable backup')}),'valueChange',false);
      else fireEvent.press(screen.getByRole('button',{name:localized(label!)}));
      const confirm=alert.mock.calls.at(-1)![2]!.find(button=>button.style==='destructive')!.onPress!;
      actions[kind!]=()=>confirm();
    }
    alert.mockClear();
    act(()=>{actions[type]!();for(const action of Object.values(actions))action();screen.UNSAFE_getAllByType(Toggle).find(node=>node.props.title==='Enable backup')!.props.onChange(false);});
    expect(command.mock.calls).toEqual([[{type}]]);
    expect(alert).not.toHaveBeenCalled();
    for(const label of ['Back Up Now','Delete online backup copy'])expect(screen.getByRole('button',{name:localized(label)})).toBeDisabled();
    expect(screen.getByRole('switch',{name:localized('Enable backup')})).toBeDisabled();
    expect(screen.getByRole('switch',{name:localized('Automatic Backup')})).toBeDisabled();
    await act(async()=>reject(new Error('Authentication cancelled.')));
    expect(alert).not.toHaveBeenCalled();
    expect(screen.getByRole('button',{name:localized('Back Up Now')})).toBeEnabled();
  }finally{alert.mockRestore();}
});


test('pending StoreKit intent survives screen recreation and releases the new view after cancellation',async()=>{
  let finish!:(value:null)=>void;const pending=new Promise<null>(resolve=>{finish=resolve;});
  const command=jest.fn((input:AppCommand)=>input.type==='purchase.buy'?pending:Promise.resolve(null));
  const app={command} as unknown as AppStore;
  const live={plus:{enabled:false,checking:false,busy:false,message:'',offers:[{id:'yearly',title:'Yearly',subtitle:'Yearly plan',price:'$29.99'}]}} as unknown as AppSnapshot;
  const first=render(<Provider live={live} app={app}><UpgradeScreen/></Provider>);
  fireEvent.press(screen.getByRole('button',{name:'Yearly'}));
  first.unmount();
  render(<Provider live={live} app={app}><UpgradeScreen/></Provider>);
  expect(screen.getByRole('button',{name:'Yearly'})).toBeDisabled();
  await act(async()=>{await screen.UNSAFE_getAllByType(ListRow).find(node=>node.props.title==='Yearly')!.props.onPress();});
  expect(command.mock.calls.filter(([input])=>input.type==='purchase.buy')).toHaveLength(1);
  await act(async()=>finish(null));
  expect(screen.getByRole('button',{name:'Yearly'})).toBeEnabled();
  await act(async()=>fireEvent.press(screen.getByRole('button',{name:'Yearly'})));
  expect(command.mock.calls.filter(([input])=>input.type==='purchase.buy')).toHaveLength(2);
});


test.each(['en','de','ja'])('tappable row metadata and prefix remain accessible in %s',locale=>{
  configurePresentation({locale,textScales:null});
  try {
    render(<ListRow title="Off" verbatimTitle subtitle="Custom DNS" metadata="Blocks nothing" metadataPrefix="Built-in" disabled onPress={()=>{}}/>);
    const row=screen.getByRole('button',{name:`Off, ${localized('Custom DNS')}`});
    expect(row).toBeDisabled();
    expect(row).toHaveAccessibilityValue({text:`${localized('Built-in')}, ${localized('Blocks nothing')}`});
  } finally {configurePresentation();}
});



test.each(['Sign in with Apple','Sign in with Google'])('%s stays exclusive across recreation until native provider cancellation settles',async title=>{
  let finish!:(value:null)=>void;
  const command=jest.fn(()=>new Promise<null>(resolve=>{finish=resolve;}));
  const app={command} as unknown as AppStore;
  const live={account:{signedIn:false,busy:false},backup:{enablement:backupEnablement(false,false),configured:false,busy:false}} as AppSnapshot;
  const first=render(<Provider live={live} app={app}><AccountScreen/></Provider>);
  fireEvent.press(screen.getByRole('button',{name:localized(title)}));
  first.unmount();
  render(<Provider live={live} app={app}><AccountScreen/></Provider>);
  const rows=screen.UNSAFE_getAllByType(ListRow).filter(node=>['Sign in with Apple','Sign in with Google'].includes(node.props.title));
  act(()=>rows.forEach(row=>row.props.onPress()));
  expect(command).toHaveBeenCalledTimes(1);
  for(const row of rows)expect(screen.getByRole('button',{name:localized(row.props.title)})).toBeDisabled();
  // Provider cancellation is handled by the controller and resolves normally,
  // unlike cancellation of the preceding app-settings authentication.
  await act(async()=>finish(null));
  expect(command).toHaveBeenCalledTimes(1);
  for(const row of rows)expect(screen.getByRole('button',{name:localized(row.props.title)})).toBeEnabled();
  command.mockResolvedValueOnce(null);
  await act(async()=>fireEvent.press(screen.getByRole('button',{name:localized(title)})));
  expect(command).toHaveBeenCalledTimes(2);
});

test('Activity keeps its digest and navigation rows mounted while its first native summary is pending',async()=>{
  Object.defineProperty(AppState,'currentState',{configurable:true,value:'active'});
  mockGetActivityDates.mockResolvedValue(todayRange);
  let resolve!:(value:unknown)=>void;
  const command=jest.fn(()=>new Promise(value=>{resolve=value;}));
  const app={command,subscribe:()=>()=>{},getInvalidation:()=>0} as unknown as AppStore;
  render(<Provider app={app}><ActivityScreen/></Provider>);
  const digest=screen.getByTestId('activity.digest');
  expect(screen.getByText('Loading Activity…')).toBeOnTheScreen();
  expect(screen.queryByLabelText('Allowed 0, Blocked 0')).toBeNull();
  expect(screen.getByTestId('row.Top domains')).toBeOnTheScreen();
  await act(async()=>Promise.resolve());
  await act(async()=>resolve({allowed:12,blocked:3,uptime:'1m'}));
  expect(screen.getByTestId('activity.digest')).toBe(digest);
  expect(screen.queryByText('Loading Activity…')).toBeNull();
  expect(screen.getByText('15')).toBeOnTheScreen();
});

test('a failed domain search explains the failure while keeping the last accepted rows',async()=>{
  const original=AppState.currentState;Object.defineProperty(AppState,'currentState',{configurable:true,value:'active'});
  try {
    const command=jest.fn().mockResolvedValueOnce([{id:'one',domain:'last.example',metadata:'2 requests'}]).mockRejectedValue(new Error('The current read failed.'));
    const app={command,subscribe:()=>()=>{},getInvalidation:()=>0} as unknown as AppStore;
    const live={session:initialSession(),security:{unavailable:false},account:{signedIn:false}} as unknown as AppSnapshot;
    render(<Provider app={app} live={live}><DomainListScreen history/></Provider>);
    await waitFor(()=>expect(screen.getByText('last.example')).toBeOnTheScreen());
    act(()=>nativeDomainSearch().onChangeText({nativeEvent:{text:'missing'}}));
    await waitFor(()=>expect(screen.getByText('The current read failed.')).toBeOnTheScreen());
    expect(screen.getByText('last.example')).toBeOnTheScreen();
  } finally {Object.defineProperty(AppState,'currentState',{configurable:true,value:original});}
});


test('legal notice disclosure keeps full attribution available and search can be cleared without losing notices',async()=>{
  mockLegalNotices.mockReturnValue(JSON.stringify({disclaimer:'Attribution',sections:[{title:'DNS Resolvers',notices:[{id:'example',displayName:'Example Resolver',noticeText:'Complete example attribution text.',plannedUse:'Resolver service',sourceURL:'https://example.test/source',licenseTextURL:'https://example.test/license'},{id:'other',displayName:'Other Resolver',noticeText:'Other full attribution.',plannedUse:'Resolver service'}]}]}));
  const command=jest.fn().mockResolvedValue(null);
  render(<Provider app={{command} as unknown as AppStore}><LegalScreen/></Provider>);
  expect(screen.queryByText('Complete example attribution text.')).toBeNull();
  expect(screen.getByRole('button',{name:'Example Resolver'})).toHaveProp('accessibilityState',{expanded:false});
  expect(screen.getByTestId('row.Example Resolver.accessory').findAllByProps({symbol:'chevron.right'}).length).toBeGreaterThan(0);
  fireEvent.press(screen.getByRole('button',{name:'Example Resolver'}));
  expect(screen.getByRole('button',{name:'Example Resolver'})).toHaveProp('accessibilityState',expect.objectContaining({expanded:true}));
  expect(screen.getByTestId('row.Example Resolver.accessory').findAllByProps({symbol:'chevron.down'}).length).toBeGreaterThan(0);
  expect(screen.getByText('Complete example attribution text.')).toBeOnTheScreen();
  expect(screen.getByText(/https:\/\/example.test\/license/)).toBeOnTheScreen();
  fireEvent.press(screen.getByRole('button',{name:'Other Resolver'}));
  expect(screen.queryByText('Complete example attribution text.')).toBeNull();
  expect(screen.getByText('Other full attribution.')).toBeOnTheScreen();
  expect(screen.getByRole('button',{name:'Example Resolver'})).toHaveProp('accessibilityState',{expanded:false});
  fireEvent.press(screen.getByRole('button',{name:'Example Resolver'}));
  fireEvent.changeText(screen.getByLabelText('Search notices'),'absent notice');
  expect(screen.getByText('No matching notices')).toBeOnTheScreen();
  expect(screen.queryByRole('button',{name:'Example Resolver'})).toBeNull();
  fireEvent.changeText(screen.getByLabelText('Search notices'),'');
  expect(screen.getByText('Complete example attribution text.')).toBeOnTheScreen();
  await act(async()=>fireEvent.press(screen.getByRole('button',{name:'Full license texts'})));
  expect(command).toHaveBeenCalledWith({type:'native.flow',flow:'licenses'});
});

test('diagnostics resolve composed preview values after selecting Traditional Chinese',()=>{
  configurePresentation({locale:'zh-Hant',textScales:null});
  try {
    render(<Provider><StatsScreen/></Provider>);
    expect(screen.getByText('0 次啟用 · 0/0 個請求改用裝置 DNS')).toBeOnTheScreen();
    expect(screen.getByText('關閉\n無法讀取已儲存的設定')).toBeOnTheScreen();
    expect(screen.getByText('關閉\n未使用描述檔')).toBeOnTheScreen();
    expect(screen.getAllByText(/透過 HTTPS 的 DNS/).length).toBeGreaterThan(0);
  } finally {configurePresentation();}
});

test('legal summaries and metadata translate before composition and support translated search',()=>{
  configurePresentation({locale:'zh-Hant',textScales:null});
  mockLegalNotices.mockReturnValue(JSON.stringify({disclaimer:'Attribution',sections:[{title:'DNS Resolvers',notices:[{
    id:'device',displayName:'Device DNS',noticeText:'Device DNS identifies the DNS resolver supplied by the current Wi-Fi, cellular, or system network configuration.',
    plannedUse:'Plain-text identification of the device DNS resolver used for allowed DNS lookups when selected or used as fallback.',
    sourceURL:'https://example.test/source',licenseTextURL:'https://example.test/license'
  }]}]}));
  try {
    render(<Provider><LegalScreen/></Provider>);
    fireEvent.press(screen.getByRole('button',{name:localized('Device DNS')}));
    expect(screen.getByText('裝置 DNS 指目前 Wi-Fi、行動網路或系統網路設定提供的 DNS 解析器。')).toBeOnTheScreen();
    expect(screen.getByText(/來源：https:\/\/example.test\/source/)).toBeOnTheScreen();
    expect(screen.getByText(/授權條款：https:\/\/example.test\/license/)).toBeOnTheScreen();
    fireEvent.changeText(screen.getByLabelText(localized('Search notices')),'行動網路');
    expect(screen.getByRole('button',{name:localized('Device DNS')})).toBeOnTheScreen();
  } finally {configurePresentation();}
});

test('first-load stats exposes busy labelled rows until native values arrive',async()=>{
  let finish!:(value:unknown)=>void;
  const command=jest.fn(()=>new Promise(resolve=>{finish=resolve;}));
  const app={command,subscribe:()=>()=>{},getInvalidation:()=>0} as unknown as AppStore;
  render(<Provider app={app}><StatsScreen/></Provider>);
  await waitFor(()=>expect(command).toHaveBeenCalledWith({type:'stats.query'}));
  expect(screen.getByLabelText('T0 · VPN chaining, Loading…')).toHaveProp('accessibilityState',expect.objectContaining({busy:true}));
  expect(screen.getByLabelText('Version, Loading…')).toBeOnTheScreen();
  expect(screen.getByLabelText('S · System DNS, Loading…')).toBeOnTheScreen();
  await act(async()=>finish({app:[['Version','1.5.0']],tiers:[['T0 · VPN chaining','Off']],health:[['Network','Wi-Fi']]}));
  expect(screen.getByLabelText('T0 · VPN chaining, Off')).toHaveProp('accessibilityState',expect.objectContaining({busy:false}));
  expect(screen.queryByLabelText('Version, Loading…')).toBeNull();
});

// Read-only routes can remain mounted under native editors/authentication. Those
// keyboards must not manufacture additional scroll space on an unrelated page.
test.each([UpgradeScreen, ActivityScreen, SettingsScreen, CustomizationScreen, AccountScreen, DomainListScreen])('read-only route %p does not consume native-sheet keyboard frames',Surface=>{
  render(<Provider><Surface/></Provider>);
  expect(screen.UNSAFE_getByType(ScrollView).props.automaticallyAdjustKeyboardInsets).toBe(false);
});
test.each([LegalScreen])('editable route %p retains native keyboard avoidance',Surface=>{
  render(<Provider><Surface/></Provider>);
  expect(screen.UNSAFE_getByType(ScrollView).props.automaticallyAdjustKeyboardInsets).toBe(true);
});


test('Guard commands the native tunnel while summaries navigate to their real routes',async()=>{
  const command=jest.fn().mockResolvedValue(null);
  const live={...editingSnapshot(),protection:{title:'Protected',subtitle:'Protection happens locally on this phone.',action:'Turn off',mood:'awake',rules:12,canPause:true,paused:false,disabled:false,status:3,today:{countsEnabled:true,allowed:83,blocked:17}}} as AppSnapshot;
  render(<Provider app={{command} as unknown as AppStore} live={live}><GuardScreen/></Provider>);
  await act(async()=>fireEvent.press(screen.getByRole('button',{name:'Turn off'})));
  expect(command).toHaveBeenCalledWith({type:'protection.toggle'});
  fireEvent.press(screen.getByTestId('guard.filter'));expect(mockNavigate).toHaveBeenCalledWith('Filters');
  expect(screen.getByText('17% blocked')).toBeOnTheScreen();
  await act(async()=>fireEvent.press(screen.getByTestId('guard.explore')));
  expect(command).toHaveBeenCalledWith({type:'navigation.authorize',surface:'appSettings'});
  expect(mockNavigate).toHaveBeenCalledWith('Explore');
});

test('connection filter names stay verbatim in accessibility and Explore details when they match a catalog key',async()=>{
  configurePresentation({locale:'de',textScales:null});
  try{
    const base=dnsSnapshot();
    const live={...base,session:{...base.session,activeFilterID:'mine'},filters:[{id:'mine',name:'Cancel',count:'12',lists:[],frozen:false,shareable:true,shareSummary:'12 rules'}]} satisfies AppSnapshot;
    const view=render(<Provider live={live}><SettingsScreen/></Provider>);
    expect(screen.getByTestId('connection.filter')).toHaveProp('accessibilityLabel',localized('Filter')); // Compact Settings intentionally omits configuration detail.
    view.rerender(<Provider live={live}><ExploreScreen/></Provider>);
    await act(async()=>{});
    fireEvent.press(screen.getByTestId('connection.filter'));
    expect(screen.getByTestId('explore.part.title')).toHaveTextContent(localized('Filter'));
    expect(screen.getByTestId('explore.part.summary')).toHaveTextContent(localizedFormat("You're currently using the %@ filter, with %@.",'Cancel','12 Regeln'));
  }finally{configurePresentation();}
});

test('DNS patch discovery moves from the DNS step to its action row while DNS is selected',async()=>{
  const base=dnsSnapshot();
  const live={...base,discoveries:{'ios27Patch.page':true},dnsPatch:{available:true,state:'disabled',busy:false}} satisfies AppSnapshot;
  render(<Provider live={live}><ExploreScreen/></Provider>);
  await act(async()=>{});
  expect(screen.getByTestId('connection.dns.discovery-dot')).toBeOnTheScreen();
  expect(screen.queryByTestId('explore.dns-patch.new')).toBeNull();
  fireEvent.press(screen.getByTestId('connection.dns'));
  expect(screen.queryByTestId('connection.dns.discovery-dot')).toBeNull();
  expect(screen.getByTestId('explore.dns-patch')).toHaveProp('accessibilityHint','New');
  expect(screen.getByRole('button',{name:'Open DNS settings'})).toBeOnTheScreen();
});

test.each(['allow','cancel','leave'])('Guard-side Explore gates DNS settings before navigation: %s',async outcome=>{
  let resolve!:()=>void;let reject!:(error:Error)=>void;
  const command=jest.fn(()=>new Promise<void>((yes,no)=>{resolve=yes;reject=no;}));
  const app={command} as unknown as AppStore;
  const view=render(<Provider app={app} live={dnsSnapshot()}><ExploreScreen/></Provider>);
  await act(async()=>{});
  fireEvent.press(screen.getByTestId('connection.dns'));
  fireEvent.press(screen.getByTestId('explore.configure'));
  expect(command).toHaveBeenCalledWith({type:'navigation.authorize',surface:'appSettings'});
  expect(mockNavigate).not.toHaveBeenCalled();
  if(outcome==='leave'){mockFocused=false;view.rerender(<Provider app={app} live={dnsSnapshot()}><ExploreScreen/></Provider>);}
  await act(async()=>outcome==='cancel'?reject(new Error('Authentication cancelled.')):resolve());
  if(outcome==='allow')expect(mockNavigate).toHaveBeenCalledWith('DNS');
  else expect(mockNavigate).not.toHaveBeenCalled();
});

test('explicit Play autoadvances, manual steps pause, and inspection cancels playback',async()=>{
  const priorState=AppState.currentState;AppState.currentState='active';
  jest.useFakeTimers();const command=jest.fn().mockResolvedValue(null);
  try {
    render(<Provider app={{command} as unknown as AppStore} live={dnsSnapshot()}><ExploreScreen/></Provider>);
    await act(async()=>{});
    expect(screen.getByText('Welcome')).toBeOnTheScreen();
    fireEvent.press(screen.getByTestId('explore.play'));
    expect(screen.getByText('It all starts here, on your device. Before it opens anything, it asks one question: where does this website live?')).toBeOnTheScreen();
    expect(screen.queryByTestId('explore.configure')).toBeNull();
    expect(screen.queryByTestId('explore.play')).toBeNull();
    await act(async()=>jest.advanceTimersByTime(6500));
    expect(screen.getByText('That question goes to DNS, the internet’s address book. It matches each website name to its address.')).toBeOnTheScreen();
    fireEvent.press(screen.getByTestId('explore.previous'));
    expect(screen.getByText('It all starts here, on your device. Before it opens anything, it asks one question: where does this website live?')).toBeOnTheScreen();
    await act(async()=>jest.advanceTimersByTime(10000));
    expect(screen.getByText('It all starts here, on your device. Before it opens anything, it asks one question: where does this website live?')).toBeOnTheScreen();
    fireEvent.press(screen.getByTestId('explore.transport.play'));
    for(let step=0;step<13&&screen.queryByTestId('explore.transport');step++)await act(async()=>jest.advanceTimersByTime(6500));
    expect(screen.getByRole('button',{name:'Play again'})).toBeOnTheScreen();
    expect(screen.getByText('Explore the steps')).toBeOnTheScreen();
    expect(screen.getByText('Tap a step to see what it does.')).toBeOnTheScreen();
    fireEvent.press(screen.getByTestId('explore.play'));
    fireEvent.press(screen.getByTestId('connection.filter'));
    await act(async()=>jest.advanceTimersByTime(10000));
    expect(screen.queryByTestId('explore.transport')).toBeNull();
    expect(screen.getByTestId('connection.filter')).toHaveStyle({borderWidth:1.5,borderColor:colorForScheme('navigationForeground','light')});
    expect(screen.getByRole('button',{name:'Open Filters'})).toBeOnTheScreen();
    expect(command).toHaveBeenCalledWith({type:'haptic',kind:'selected',controlID:expect.stringMatching(/^explore\.step@/),value:'inspection:filter'});
  } finally {AppState.currentState=priorState;jest.useRealTimers();}
});

test('Next on the final demo step finishes playback and restores inspection',async()=>{
  const priorState=AppState.currentState;AppState.currentState='active';
  jest.useFakeTimers();const command=jest.fn().mockResolvedValue(null);
  try{
    render(<Provider app={{command} as unknown as AppStore} live={dnsSnapshot()}><ExploreScreen/></Provider>);
    await act(async()=>{});
    fireEvent.press(screen.getByTestId('explore.play'));
    const total=screen.UNSAFE_getByType(require('../review/story-scaffold').DemoTransport).props.total;
    for(let step=1;step<total;step++)fireEvent.press(screen.getByTestId('explore.next'));
    expect(screen.getByText(`${total}/${total}`)).toBeOnTheScreen();
    expect(screen.getByTestId('explore.next')).toBeEnabled();
    fireEvent.press(screen.getByTestId('explore.next'));
    expect(screen.queryByTestId('explore.transport')).toBeNull();
    expect(screen.getByRole('button',{name:'Play again'})).toBeOnTheScreen();
    expect(screen.getByText('Explore the steps')).toBeOnTheScreen();
    await act(async()=>jest.advanceTimersByTime(10000));
    expect(screen.queryByTestId('explore.transport')).toBeNull();
    fireEvent.press(screen.getByTestId('connection.filter'));
    expect(screen.getByRole('button',{name:'Open Filters'})).toBeOnTheScreen();
  }finally{AppState.currentState=priorState;jest.useRealTimers();}
});

test('Explore selection changes haptic once per crossed step while tapping the selected step still deselects',async()=>{
  const command=jest.fn().mockResolvedValue(null);
  render(<Provider app={{command} as unknown as AppStore} live={dnsSnapshot()}><ExploreScreen/></Provider>);
  await act(async()=>{});
  const scene=screen.UNSAFE_getByType(require('../review/story-scaffold').ConnectionScene);
  const filter=scene.props.stages.find((stage:{id:string})=>stage.id==='filter');
  const dns=scene.props.stages.find((stage:{id:string})=>stage.id==='dns');
  act(()=>{scene.props.onInspect(filter);scene.props.onInspect(filter);});
  expect(command).toHaveBeenCalledTimes(1);
  expect(command).toHaveBeenLastCalledWith({type:'haptic',kind:'selected',controlID:expect.stringMatching(/^explore\.step@/),value:'inspection:filter'});
  act(()=>scene.props.onInspect(dns));
  expect(command).toHaveBeenCalledTimes(2);
  expect(screen.getByTestId('connection.dns')).toHaveProp('accessibilityState',{selected:true});
  fireEvent.press(screen.getByTestId('connection.dns'));
  expect(command).toHaveBeenCalledTimes(3);
  expect(screen.getByText('Welcome')).toBeOnTheScreen();
});

test.each(['blur','background','inactive'] as const)('leaving Explore cancels playback but ordinary inactivity retains the displayed step on %s',async(departure)=>{
  const priorState=AppState.currentState;AppState.currentState='active';
  jest.useFakeTimers();const listeners=new Set<(state:string)=>void>();
  const originalSubscribe=jest.mocked(AppState.addEventListener).getMockImplementation()!;
  const appState=jest.spyOn(AppState,'addEventListener').mockImplementation((_event,callback)=>{
    const listener=callback as (state:string)=>void;listeners.add(listener);return{remove:()=>{listeners.delete(listener);}};
  });
  try {
    const view=render(<Provider live={dnsSnapshot()}><ExploreScreen/></Provider>);
    fireEvent.press(screen.getByTestId('explore.play'));
    if(departure==='blur'){mockFocused=false;view.rerender(<Provider live={dnsSnapshot()}><ExploreScreen/></Provider>);}
    else act(()=>{AppState.currentState=departure;listeners.forEach(listener=>listener(departure));});
    await act(async()=>jest.runAllTimers());
    if(departure==='blur') {
      expect(screen.queryAllByTestId(/^explore\.demo\.caption\./)).toHaveLength(0);
      fireEvent.press(screen.getByTestId('explore.play'));
      expect(screen.queryAllByTestId(/^explore\.demo\.caption\./)).toHaveLength(0);
    } else {
      expect(screen.getByTestId('explore.demo.caption.device')).toBeOnTheScreen();
      expect(screen.UNSAFE_getByType(require('../review/story-scaffold').DemoTransport).props.playing).toBe(false);
      fireEvent.press(screen.getByTestId('explore.transport.play'));
      await act(async()=>jest.advanceTimersByTime(10000));
      expect(screen.getByTestId('explore.demo.caption.device')).toBeOnTheScreen();
    }
    if(departure==='blur'){mockFocused=true;view.rerender(<Provider live={dnsSnapshot()}><ExploreScreen/></Provider>);}
    else act(()=>{AppState.currentState='active';listeners.forEach(listener=>listener('active'));});
    fireEvent.press(screen.getByTestId(departure==='blur'?'explore.play':'explore.transport.play'));
    expect(screen.getByTestId('explore.demo.caption.device')).toBeOnTheScreen();
    view.unmount();
  } finally {AppState.currentState=priorState;appState.mockImplementation(originalSubscribe);jest.useRealTimers();}
});

test('the contextual DNS link uses native removal interception before revealing the protected editor',async()=>{
  mockExploreParams={part:'dns',returnTo:'DNS',returnKey:'dns-editor'};
  mockGetState.mockReturnValue({index:1,routes:[{key:'dns-editor',name:'DNS'},{key:'explore',name:'Explore'}]});
  let resolve!:()=>void;const command=jest.fn(()=>new Promise<void>(yes=>{resolve=yes;}));
  const base=dnsSnapshot();const live={...base,session:{...base.session,protectedActions:{...initialSession().protectedActions,'Update App Settings':true}}};
  render(<Provider app={{command} as unknown as AppStore} live={live}><ExploreScreen/></Provider>);
  await act(async()=>{});
  fireEvent.press(screen.getByRole('button',{name:'Open DNS settings'}));
  expect(mockGoBack).toHaveBeenCalledTimes(1);
  const interception=jest.mocked(usePreventRemove).mock.calls.filter(([enabled])=>enabled).at(-1)!;
  expect(interception).toBeDefined();
  const action={type:'GO_BACK'};
  act(()=>interception[1]({data:{action}}));
  expect(command).toHaveBeenCalledWith({type:'navigation.authorize',surface:'appSettings'});
  expect(mockDispatch).not.toHaveBeenCalled();
  await act(async()=>resolve());
  expect(mockDispatch).toHaveBeenCalledWith(action);
});

test('a contextual DNS example returns to its exact original editor',async()=>{
  mockExploreParams={part:'dns',returnTo:'DNS',returnKey:'dns-editor'};
  mockGetState.mockReturnValue({index:1,routes:[{key:'dns-editor',name:'DNS'},{key:'explore',name:'Explore'}]});
  render(<Provider live={dnsSnapshot()}><ExploreScreen/></Provider>);
  await act(async()=>{});
  fireEvent.press(screen.getByRole('button',{name:'Open DNS settings'}));
  expect(mockGoBack).toHaveBeenCalledTimes(1);expect(mockNavigate).not.toHaveBeenCalled();
});

test('reduced motion keeps explicit autoplay and readable captions',async()=>{
  jest.useFakeTimers();const motion=jest.spyOn(AccessibilityInfo,'isReduceMotionEnabled').mockResolvedValue(true);
  try {
    const view=render(<Provider live={dnsSnapshot()}><ExploreScreen/></Provider>);
    fireEvent.press(screen.getByTestId('explore.play'));
    expect(screen.getByText('It all starts here, on your device. Before it opens anything, it asks one question: where does this website live?')).toBeOnTheScreen();
    await act(async()=>jest.advanceTimersByTime(6500));
    expect(screen.getByText('That question goes to DNS, the internet’s address book. It matches each website name to its address.')).toBeOnTheScreen();
    expect(screen.queryByTestId('explore.spotlight')).toBeNull();
    view.unmount();
  } finally {motion.mockRestore();jest.useRealTimers();}
});






test('Account keeps native failure detail inside the enable row when maintenance is collapsed',()=>{
  const live={account:{signedIn:true},backup:{enablement:backupEnablement(true,true),configured:true,automatic:false,busy:false,title:'Needs attention',summary:'Needs attention',detail:'Upload was not confirmed. Try again.',needsAttention:true}} as AppSnapshot;
  render(<Provider live={live}><AccountScreen/></Provider>);
  expect(screen.getByText('Upload was not confirmed. Try again.')).toBeOnTheScreen();
  const disclosure=screen.getByRole('button',{name:localized('Backup maintenance')});
  expect(disclosure).toHaveProp('accessibilityState',expect.objectContaining({expanded:false}));
  fireEvent.press(disclosure);
  fireEvent.press(disclosure);
  expect(screen.queryByRole('button',{name:localized('Delete online backup copy')})).toBeNull();
  expect(screen.getByText('Upload was not confirmed. Try again.')).toBeOnTheScreen();
});

test('pending deletion keeps its confirmed native retry reachable after local configuration disappears',async()=>{
  const command=jest.fn(async()=>undefined);const alert=jest.spyOn(Alert,'alert').mockImplementation(()=>{});
  const live={account:{signedIn:true},backup:{enablement:backupEnablement(null,true,{state:'deletionPending',canRetryDeletion:true}),configured:false,automatic:false,busy:false,title:'Needs attention',summary:'Needs attention',detail:'Sign in to the original account and try turning off backup again.',needsAttention:true,deletionPending:true}} as AppSnapshot;
  try{
    render(<Provider live={live} app={{command} as unknown as AppStore}><AccountScreen/></Provider>);
    expect(screen.getByText(live.backup.detail!)).toBeOnTheScreen();
    expect(screen.queryByRole('button',{name:localized('Delete online backup copy')})).toBeNull();
    fireEvent.press(screen.getByRole('button',{name:localized('Turn off & delete backup')}));
    expect(command).not.toHaveBeenCalled();
    const confirmation=alert.mock.calls.at(-1)![2]!.find(button=>button.style==='destructive')!;
    await act(async()=>confirmation.onPress!());
    expect(command.mock.calls).toEqual([[{type:'backup.disable'}]]);
  }finally{alert.mockRestore();}
});

test('pending local deletion cleanup remains reachable after sign-out',()=>{
  const live={account:{signedIn:true},backup:{enablement:backupEnablement(null,true,{state:'deletionPending',canRetryDeletion:true}),configured:false,automatic:false,busy:false,deletionPending:true}} as AppSnapshot;
  const view=render(<Provider live={live}><AccountScreen/></Provider>);
  expect(screen.getByRole('button',{name:localized('Turn off & delete backup')})).toBeEnabled();
  view.rerender(<Provider live={{...live,account:{...live.account,signedIn:false}}}><AccountScreen/></Provider>);
  expect(screen.getByRole('button',{name:localized('Turn off & delete backup')})).toBeEnabled();
});

test('an unconfigured ordinary setup failure does not expose destructive backup maintenance',()=>{
  const live={account:{signedIn:true},backup:{enablement:backupEnablement(false,true),configured:false,automatic:false,busy:false,title:'Needs attention',summary:'Needs attention',detail:'Setup could not be completed.',needsAttention:true,deletionPending:false}} as AppSnapshot;
  render(<Provider live={live}><AccountScreen/></Provider>);
  expect(screen.getByText(live.backup.detail!)).toBeOnTheScreen();
  expect(screen.queryByRole('button',{name:localized('Backup maintenance')})).toBeNull();
});


describe('Activity periods and contextual filter summaries',()=>{
  beforeEach(()=>{
    jest.mocked(AppState.addEventListener).mockImplementation(()=>({remove:jest.fn()}));
    Object.defineProperty(AppState,'currentState',{configurable:true,value:'active'});
  });

test('Filters reads the active saved composition even when another filter has an unsaved draft',async()=>{
  const live=editingSnapshot();
  live.session.activeFilterID='saved';live.session.filterID='active';
  live.filters.push({id:'saved',name:'My saved filter',count:'4,321',lists:['a','b','c'],blockedDomainCount:7,allowedExceptionCount:2,frozen:false,shareable:true,shareSummary:'4,321 rules'});
  live.draft={blocked:Array(20).fill('draft.example'),allowed:Array(10).fill('draft.example')};
  const command=jest.fn(async()=>null);
  render(<Provider app={{command} as unknown as AppStore} live={live}><FiltersScreen/></Provider>);
  expect(screen.getByTestId('row.Now filtering').props.accessibilityLabel).toContain('Blocklists, 3, Blocked domains, 7, Allowed exceptions, 2');
  expect(screen.getByText('4,321 rules')).toBeOnTheScreen();
  expect(screen.queryByRole('button',{name:'Share your filter'})).toBeNull();
  await act(async()=>toolbarItems().find((item:{label:string})=>item.label==='Import').onPress());
  expect(command).toHaveBeenCalledWith({type:'native.flow',flow:'import'});
  await act(async()=>fireEvent.press(screen.getByTestId('row.Now filtering')));
  expect(command).toHaveBeenCalledWith({type:'filter.open',id:'saved'});
  expect(mockNavigate).toHaveBeenLastCalledWith('Filter',{id:'saved'});
});

test('unshareable saved filters keep sharing disabled without borrowing another filter’s data',()=>{
  const live=editingSnapshot();live.filters[0]={...live.filters[0]!,shareable:false,shareSummary:'Too big to share'};
  render(<Provider app={{command:jest.fn()} as unknown as AppStore} live={live}><FiltersScreen/></Provider>);
  expect(screen.queryByRole('button',{name:'Share your filter'})).toBeNull();
  expect(screen.getByTestId('row.Now filtering').props.accessibilityLabel).toContain('Blocked domains, —');
  expect(screen.getByTestId('row.Now filtering').props.accessibilityLabel).not.toContain('Blocked Domains, 2');
});

test('library sharing keeps the chosen inactive identity and excludes unavailable exports',async()=>{
  const live=librarySnapshot();live.filters[1]!.shareable=true;
  const alert=jest.spyOn(Alert,'alert').mockImplementation(()=>{});
  try{
    render(<Provider app={{command:jest.fn(async()=>null)} as unknown as AppStore} live={live}><LibraryScreen/></Provider>);
    mockChooseFilterAction.mockResolvedValueOnce('share');
    await act(async()=>fireEvent.press(screen.getByRole('button',{name:live.filters[1]!.name})));
    expect(mockChooseFilterAction).toHaveBeenLastCalledWith(live.filters[1]!.name,true,true);
    expect(mockNavigate).toHaveBeenLastCalledWith('ShareDetail',{id:live.filters[1]!.id});
    fireEvent.press(screen.getByRole('button',{name:live.filters[2]!.name}));
    expect(mockChooseFilterAction).toHaveBeenLastCalledWith(live.filters[2]!.name,false,false);
  }finally{alert.mockRestore();}
});

test('Activity period changes query native calendar ranges and never display today’s result under a new range',async()=>{
  mockGetActivityDates.mockResolvedValue(todayRange);
  let finishWeek!:(value:unknown)=>void;
  const command=jest.fn((input:AppCommand)=>input.type==='activity.query'&&input.start===10?new Promise(resolve=>{finishWeek=resolve;}):Promise.resolve({allowed:12,blocked:3,uptime:'1m'}));
  const app={command,subscribe:()=>()=>{},getInvalidation:()=>0} as unknown as AppStore;
  render(<Provider app={app}><ActivityScreen/></Provider>);
  await waitFor(()=>expect(screen.getByText('15')).toBeOnTheScreen());
  const digest=screen.getByTestId('activity.digest');
  await act(async()=>fireEvent.press(screen.getByRole('button',{name:localized('7 days')})));
  expect(mockGetActivityDatePreset).toHaveBeenCalledWith('week');
  expect(command).toHaveBeenCalledWith({type:'activity.query',start:10,end:1000,hourly:false});
  expect(screen.queryByText('15')).toBeNull();
  expect(screen.getByText('Loading Activity…')).toBeOnTheScreen();
  await act(async()=>finishWeek({allowed:120,blocked:180,uptime:'5h'}));
  expect(screen.getByText('300')).toBeOnTheScreen();
  expect(screen.getByTestId('activity.digest')).toBe(digest);
  expect(screen.getByTestId('activity.domain-logs')).toBeOnTheScreen();
  await act(async()=>fireEvent.press(screen.getByTestId('row.Top domains')));
  expect(mockNavigate).toHaveBeenLastCalledWith('TopDomains',{start:10,end:1000});
});

test('a late calendar preset reply cannot replace a newer period selection',async()=>{
  let finishWeek!:(value:unknown)=>void;
  mockGetActivityDatePreset.mockImplementationOnce(()=>new Promise(resolve=>{finishWeek=resolve as typeof finishWeek;}));
  render(<Provider example><ActivityScreen/></Provider>);
  await waitFor(()=>expect(screen.getByText(expectedNumber.format(3246))).toBeOnTheScreen());
  fireEvent.press(screen.getByRole('button',{name:localized('7 days')}));
  await act(async()=>fireEvent.press(screen.getByRole('button',{name:localized('Month')})));
  expect(screen.getByRole('button',{name:localized('Month')})).toBeSelected();
  await act(async()=>finishWeek({start:10,end:1000,label:'Sep 7–13',includesToday:true}));
  expect(screen.getByRole('button',{name:localized('Month')})).toBeSelected();
  expect(screen.queryByText(expectedNumber.format(3246))).toBeNull();
});

test.each(['today','week','month'] as const)('a failed midnight %s refresh retries on polling without repeated alerts',async preset=>{
  jest.useFakeTimers();jest.setSystemTime(new Date(2026,8,30,23,59,58));
  const originalPreset=mockGetActivityDatePreset.getMockImplementation()!;
  const alert=jest.spyOn(Alert,'alert').mockImplementation(()=>{});
  mockGetActivityDates.mockResolvedValue(todayRange);
  mockGetActivityDatePreset.mockResolvedValue(todayRange);
  const command=jest.fn(async()=>({allowed:12,blocked:3,uptime:'1m'}));
  const app={command,subscribe:()=>()=>{},getInvalidation:()=>0} as unknown as AppStore;
  const view=render(<Provider app={app}><ActivityScreen/></Provider>);
  try{
    await act(async()=>{});
    if(preset!=='today')await act(async()=>fireEvent.press(screen.getByRole('button',{name:localized(preset==='week'?'7 days':'Month')})));
    mockGetActivityDatePreset.mockClear();
    mockGetActivityDatePreset.mockRejectedValueOnce(new Error('Transient bridge failure'))
      .mockResolvedValue({start:2000,end:3000,label:'New calendar range',includesToday:true});
    await act(async()=>jest.advanceTimersByTimeAsync(5000));
    expect(mockGetActivityDatePreset).toHaveBeenCalledTimes(1);
    expect(alert).not.toHaveBeenCalled();
    await act(async()=>jest.advanceTimersByTimeAsync(5000));
    expect(mockGetActivityDatePreset).toHaveBeenCalledTimes(2);
    expect(command).toHaveBeenCalledWith({type:'activity.query',start:2000,end:3000,hourly:preset==='today'});
    await act(async()=>jest.advanceTimersByTimeAsync(5000));
    expect(mockGetActivityDatePreset).toHaveBeenCalledTimes(2);
  }finally{view.unmount();alert.mockRestore();mockGetActivityDatePreset.mockImplementation(originalPreset);jest.useRealTimers();}
});

test.each(['today','week','month'] as const)('foreground polling advances %s at midnight and preserves a later Custom range',async preset=>{
  jest.useFakeTimers();jest.setSystemTime(new Date(2026,8,30,23,59,58));
  const originalPreset=mockGetActivityDatePreset.getMockImplementation()!;
  mockGetActivityDates.mockResolvedValue(todayRange);
  const nextRange={start:2000,end:3000,label:'New calendar range',includesToday:true};
  mockGetActivityDatePreset.mockImplementation(async()=>new Date().getMonth()===8?todayRange:nextRange);
  const command=jest.fn(async()=>({allowed:12,blocked:3,uptime:'1m'}));
  const app={command,subscribe:()=>()=>{},getInvalidation:()=>0} as unknown as AppStore;
  const view=render(<Provider app={app}><ActivityScreen/></Provider>);
  try{
    await act(async()=>{});
    if(preset!=='today')await act(async()=>fireEvent.press(screen.getByRole('button',{name:localized(preset==='week'?'7 days':'Month')})));
    mockGetActivityDatePreset.mockClear();
    await act(async()=>jest.advanceTimersByTimeAsync(5000));
    expect(mockGetActivityDatePreset).toHaveBeenCalledTimes(1);
    expect(mockGetActivityDatePreset).toHaveBeenLastCalledWith(preset);
    expect(command).toHaveBeenCalledWith({type:'activity.query',start:2000,end:3000,hourly:preset==='today'});
    await act(async()=>jest.advanceTimersByTimeAsync(5000));
    expect(mockGetActivityDatePreset).toHaveBeenCalledTimes(1);
    mockPickActivityDates.mockResolvedValueOnce({start:20,end:30,label:'My dates',includesToday:false});
    await act(async()=>fireEvent.press(screen.getByRole('button',{name:localized('Custom')})));
    expect(mockGetActivityDatePreset).toHaveBeenLastCalledWith('fortnight');
    mockGetActivityDatePreset.mockClear();
    jest.setSystemTime(new Date(2026,10,1,0,0,1));
    await act(async()=>jest.advanceTimersByTimeAsync(5000));
    expect(mockGetActivityDatePreset).not.toHaveBeenCalled();
    expect(screen.getByTestId('activity.custom-range')).toHaveTextContent('My dates');
    expect(command).toHaveBeenLastCalledWith({type:'activity.query',start:20,end:30,hourly:false});
  }finally{view.unmount();mockGetActivityDatePreset.mockImplementation(originalPreset);jest.useRealTimers();}
});

});


test('unchanged filter Save stays available and ends through the native save owner',async()=>{
  const live=editingSnapshot();live.filterEditing={canSave:false,validation:'',refreshing:false,lists:[],blocked:[],allowed:[]};
  const command=jest.fn().mockResolvedValue('saved');
  render(<Provider app={{command} as unknown as AppStore} live={live}><FilterScreen/></Provider>);
  expect(toolbarAction('Save').disabled).toBe(false);
  await act(async()=>toolbarAction('Save').onPress());
  expect(command).toHaveBeenCalledWith({type:'filter.save',id:'active'});
  expect(mockNavigate).not.toHaveBeenCalledWith('Review',expect.anything());
});








const dnsTier=(id:string,name:string,transport='DoH')=>({id,name,transport,metadata:`${name}.example`,primary:'',secondary:''});
function tierSnapshot():AppSnapshot {
  const live=dnsSnapshot();live.dns.tiers=[dnsTier('cloudflare-doh','Cloudflare'),dnsTier('google-dot','Google','DoT')];
  live.dns.tiersContext='saved-tier-context';live.dns.choices=[...live.dns.tiers,dnsTier('device-dns','Device DNS','Device')];return live;
}
test('DNS editing promotes the second row, preserves the saved configuration until Save and keeps the last row',async()=>{
  const command=jest.fn().mockResolvedValue(null);const live=tierSnapshot();
  render(<Provider live={live} app={{command} as unknown as AppStore}><DNSScreen/></Provider>);
  expect(screen.queryByRole('button',{name:'Remove Cloudflare'})).toBeNull();
  act(()=>toolbarItems().find((item:{label:string})=>item.label==='Edit').onPress());
  const remove=screen.UNSAFE_getAllByType(require('../src').LavaIconButton).find(node=>node.props.item==='Cloudflare')!;
  fireEvent.press(remove);
  expect(command).not.toHaveBeenCalled();
  expect(screen.queryByText('Cloudflare')).toBeNull();expect(screen.getByText('Google')).toBeOnTheScreen();
  expect(screen.UNSAFE_queryAllByType(require('../src').LavaIconButton)).toHaveLength(0);
  await act(async()=>toolbarItems().find((item:{label:string})=>item.label==='Save').onPress());
  expect(command).toHaveBeenCalledWith({type:'dns.tiers',context:'saved-tier-context',tiers:[{id:'google-dot',name:'Google',primary:'',secondary:''}]});
});
test('DNS panel swaps both tiers in its Add footer and commits only on Save',async()=>{
  const live=tierSnapshot();const command=jest.fn().mockResolvedValue(null);
  render(<Provider live={live} app={{command} as unknown as AppStore}><DNSScreen/></Provider>);
  expect(screen.queryByText('Swap order')).toBeNull();
  act(()=>toolbarAction('Edit').onPress());
  expect(screen.queryByText('Add secondary DNS')).toBeNull();
  const swap=screen.UNSAFE_getAllByType(LavaActionButton).find(button=>button.props.title==='Swap order')!;
  expect(swap.props.role).toBe('panel');expect(swap.props.icon).toBe('swap');
  fireEvent.press(swap);
  const rows=screen.UNSAFE_getAllByType(ListRow).filter(row=>['Cloudflare','Google'].includes(row.props.title));
  expect(rows.map(row=>row.props.title)).toEqual(['Google','Cloudflare']);
  expect(rows.map(row=>row.props.leading.props.name)).toEqual(['1.circle','2.circle']);
  expect(command).not.toHaveBeenCalled();
  await act(async()=>toolbarAction('Save').onPress());
  expect(command).toHaveBeenCalledWith({type:'dns.tiers',context:'saved-tier-context',tiers:[
    {id:'google-dot',name:'Google',primary:'',secondary:''},{id:'cloudflare-doh',name:'Cloudflare',primary:'',secondary:''}]});
});
test('DNS swapped order is discarded by Cancel and a single row keeps Add',async()=>{
  const alert=jest.spyOn(Alert,'alert').mockImplementation(()=>{});const live=tierSnapshot();const command=jest.fn();
  try{
    render(<Provider live={live} app={{command} as unknown as AppStore}><DNSScreen/></Provider>);
    act(()=>toolbarAction('Edit').onPress());fireEvent.press(screen.getByText('Swap order'));
    act(()=>toolbarAction('Cancel editing','Left').onPress());
    act(()=>alert.mock.calls.at(-1)![2]!.find(button=>button.text==='Discard')!.onPress!());
    expect(screen.UNSAFE_getAllByType(ListRow).filter(row=>['Cloudflare','Google'].includes(row.props.title)).map(row=>row.props.title)).toEqual(['Cloudflare','Google']);
    expect(command).not.toHaveBeenCalled();
    act(()=>toolbarAction('Edit').onPress());
    fireEvent.press(screen.UNSAFE_getAllByType(require('../src').LavaIconButton).find(node=>node.props.item==='Cloudflare')!);
    expect(screen.queryByText('Swap order')).toBeNull();expect(screen.getByText('Add fallback DNS')).toBeOnTheScreen();
  }finally{alert.mockRestore();}
});
test('DNS tier Save excludes same-frame replay and keeps the draft on rejection',async()=>{
  let reject!:(error:Error)=>void;const command=jest.fn(()=>new Promise((_,no)=>{reject=no;}));const alert=jest.spyOn(Alert,'alert').mockImplementation(()=>{});
  try {render(<Provider live={tierSnapshot()} app={{command} as unknown as AppStore}><DNSScreen/></Provider>);
    act(()=>toolbarItems().find((item:{label:string})=>item.label==='Edit').onPress());
    fireEvent.press(screen.UNSAFE_getAllByType(require('../src').LavaIconButton).find(node=>node.props.item==='Cloudflare')!);
    const save=toolbarItems().find((item:{label:string})=>item.label==='Save').onPress;
    act(()=>{save();save();});expect(command).toHaveBeenCalledTimes(1);
    await act(async()=>reject(new Error('DNS settings changed. Reopen the editor before saving.')));
    expect(toolbarItems().find((item:{label:string})=>item.label==='Save')).toBeDefined();expect(alert).toHaveBeenCalled();
  }finally{alert.mockRestore();}
});
test('VPN-owned DNS hides saved tiers and the edit action',()=>{
  const live=tierSnapshot();live.dns.editable=false;
  render(<Provider live={live} app={{command:jest.fn()} as unknown as AppStore}><DNSScreen/></Provider>);
  expect(screen.queryByText('Cloudflare')).toBeNull();
  expect(screen.getByText('Review VPN chaining')).toBeOnTheScreen();
  expect(toolbarItems()).toEqual([]);
});

test('DNS picker uses a dedicated Device section and stages a selection without a native settings write',async()=>{
  mockExploreParams={target:'tier',index:0};const command=jest.fn();
  render(<Provider live={tierSnapshot()} app={{command} as unknown as AppStore}><DNSPickerScreen/></Provider>);
  expect(screen.getAllByText('Device').length).toBeGreaterThan(0);
  fireEvent.press(screen.getByRole('button',{name:'Cloudflare'}));
  await act(async()=>fireEvent.press(screen.getByRole('button',{name:'Save selection'})));
  expect(command).not.toHaveBeenCalled();expect(mockGoBack).toHaveBeenCalled();
});
test('DNS picker transport pills read Device, DoH, DoT, then IP',()=>{
  mockExploreParams={target:'tier',index:0};const live=tierSnapshot();
  live.dns.choices=[...(live.dns.choices??[]),dnsTier('quad9-ip','Quad9','IP')];
  render(<Provider live={live} app={{command:jest.fn()} as unknown as AppStore}><DNSPickerScreen/></Provider>);
  const pills=screen.getAllByRole('button').map(button=>String(button.props.accessibilityLabel))
    .filter(label=>['Device','DoH','DoT','IP','DoQ'].includes(label));
  expect(pills).toEqual(['Device','DoH','DoT','IP']);
});
test('profile status distinguishes installed from selected without creating a profile on render',()=>{
  const live=tierSnapshot();live.dnsPatch={available:true,state:'disabled',busy:false,provider:dnsTier('quad9-dot','Quad9','DoT')};const command=jest.fn();
  render(<Provider live={live} app={{command} as unknown as AppStore}><DNSScreen/></Provider>);
  expect(screen.getByText('Select the System DNS profile')).toBeOnTheScreen();expect(screen.queryByText('Install DNS profile')).toBeNull();
  expect(screen.queryByText('Profile installed and selected')).toBeNull();expect(command).not.toHaveBeenCalled();
});

test.each(['enabled','disabled','different'] as const)('installed System DNS (%s) offers a confirmed destructive uninstall without editing',async state=>{
  const live=tierSnapshot();live.dnsPatch={available:true,state,busy:false,provider:dnsTier('quad9-dot','Quad9','DoT')};
  let complete!:()=>void;const command=jest.fn(()=>new Promise<void>(resolve=>{complete=resolve;}));
  const alert=jest.spyOn(Alert,'alert').mockImplementation(()=>{});const app={command} as unknown as AppStore;
  try {const view=render(<Provider live={live} app={app}><DNSScreen/></Provider>);
    const row=()=>screen.UNSAFE_getAllByType(ListRow).find(node=>node.props.testID==='dns.profile.uninstall')!;
    expect(row().props).toMatchObject({title:'Uninstall profile',icon:'trash',color:colors.errorText,action:true});
    fireEvent.press(screen.getByRole('button',{name:'Uninstall profile'}));
    expect(command).not.toHaveBeenCalled();
    let buttons=alert.mock.calls.at(-1)?.[2];
    expect(buttons?.map(button=>button.text)).toEqual(['Cancel','Remove profile']);
    act(()=>buttons?.find(button=>button.style==='cancel')?.onPress?.());
    expect(command).not.toHaveBeenCalled();expect(screen.getByText('Quad9')).toBeOnTheScreen();
    fireEvent.press(screen.getByRole('button',{name:'Uninstall profile'}));buttons=alert.mock.calls.at(-1)?.[2];
    const confirm=buttons?.find(button=>button.style==='destructive')?.onPress;
    act(()=>{confirm?.();confirm?.();});
    expect(command).toHaveBeenCalledTimes(1);expect(command).toHaveBeenCalledWith({type:'settings.set',key:'dnsPatchRemove',value:true});
    expect(screen.getByRole('button',{name:'Uninstall profile'})).toBeDisabled();
    await act(async()=>complete());
    view.rerender(<Provider live={{...live,dnsPatch:{...live.dnsPatch!,state:'absent',provider:null}}} app={app}><DNSScreen/></Provider>);
    expect(screen.queryByTestId('dns.profile.uninstall')).toBeNull();expect(screen.getByText('System DNS not configured')).toBeOnTheScreen();
    expect(toolbarItems().find((item:{label:string})=>item.label==='Edit')).toBeDefined();
  }finally{alert.mockRestore();}
});

test('System DNS uninstall reports removal failure and leaves the installed profile retryable',async()=>{
  const live=tierSnapshot();live.dnsPatch={available:true,state:'enabled',busy:false,provider:dnsTier('quad9-dot','Quad9','DoT')};
  const command=jest.fn().mockRejectedValueOnce(new Error('The DNS profile could not be removed.')).mockResolvedValue(null);
  const alert=jest.spyOn(Alert,'alert').mockImplementation(()=>{});
  const app={command} as unknown as AppStore;
  try {const view=render(<Provider live={live} app={app}><DNSScreen/></Provider>);
    const confirm=async()=>{fireEvent.press(screen.getByRole('button',{name:'Uninstall profile'}));
      await act(async()=>alert.mock.calls.at(-1)?.[2]?.find(button=>button.style==='destructive')?.onPress?.());};
    await confirm();expect(alert.mock.calls.at(-1)?.slice(0,2)).toEqual(['Lava',localized('The DNS profile could not be removed.')]);
    // Native removal failure publishes error status while readback still identifies
    // the installed provider. Exercise that snapshot rather than keeping live stale.
    view.rerender(<Provider live={{...live,dnsPatch:{...live.dnsPatch!,state:'error'}}} app={app}><DNSScreen/></Provider>);
    expect(screen.getByText('Quad9')).toBeOnTheScreen();expect(screen.getByRole('button',{name:'Uninstall profile'})).not.toBeDisabled();
    await confirm();expect(command).toHaveBeenCalledTimes(2);
  }finally{alert.mockRestore();}
});

test('System DNS uninstall is disabled during profile work and hidden while editing',()=>{
  const live=tierSnapshot();live.dnsPatch={available:true,state:'enabled',busy:true,provider:dnsTier('quad9-dot','Quad9','DoT')};
  const command=jest.fn();const app={command} as unknown as AppStore;
  const view=render(<Provider live={live} app={app}><DNSScreen/></Provider>);
  expect(screen.getByRole('button',{name:'Uninstall profile'})).toBeDisabled();
  view.rerender(<Provider live={{...live,dnsPatch:{...live.dnsPatch!,busy:false}}} app={app}><DNSScreen/></Provider>);
  act(()=>toolbarItems().find((item:{label:string})=>item.label==='Edit').onPress());
  expect(screen.queryByTestId('dns.profile.uninstall')).toBeNull();expect(command).not.toHaveBeenCalled();
});

test.each(['absent','checking','different','disabled','enabled','error'] as const)('System DNS (%s) without installed configuration readback never offers uninstall',state=>{
  const live=tierSnapshot();live.dnsPatch={available:true,state,busy:false,provider:null};
  const command=jest.fn();render(<Provider live={live} app={{command} as unknown as AppStore}><DNSScreen/></Provider>);
  expect(screen.queryByTestId('dns.profile.uninstall')).toBeNull();expect(command).not.toHaveBeenCalled();
});

test('an installed System DNS readback remains visible but cannot uninstall while checking',()=>{
  const live=tierSnapshot();live.dnsPatch={available:true,state:'checking',busy:false,provider:dnsTier('quad9-dot','Quad9','DoT')};
  const command=jest.fn();const alert=jest.spyOn(Alert,'alert').mockImplementation(()=>{});
  try {
    render(<Provider live={live} app={{command} as unknown as AppStore}><DNSScreen/></Provider>);
    const row=screen.getByRole('button',{name:'Uninstall profile'});
    expect(row).toBeDisabled();fireEvent.press(row);
    expect(alert).not.toHaveBeenCalled();expect(command).not.toHaveBeenCalled();
  }finally{alert.mockRestore();}
});

test('custom DNS opens the shared pushed form and a saved custom draft stays uncommitted in the picker',async()=>{
  mockExploreParams={target:'tier',index:0};const live=tierSnapshot();const command=jest.fn().mockResolvedValue('dns-editor-token');
  const app={command} as unknown as AppStore;
  const view=render(<Provider live={live} app={app}><DNSPickerScreen/></Provider>);
  await act(async()=>toolbarItems().find((item:{label:string})=>item.label==='Add custom DNS').onPress());
  expect(command).toHaveBeenCalledWith({type:'dns.customDraft',choice:undefined});
  expect(mockNavigate).toHaveBeenCalledWith('CustomEntry',{id:'dns-editor-token',kind:'dns'});
  const choice={id:'custom-dns',name:'Private resolver',primary:'https://dns.example/query',secondary:'',transport:'DoH',metadata:'https://dns.example/query'};
  view.rerender(<Provider live={{...live,dns:{...live.dns,customDraft:choice,customDraftToken:'dns-editor-token'}}} app={app}><DNSPickerScreen/></Provider>);
  expect(screen.getByRole('button',{name:'Private resolver'})).toHaveProp('accessibilityState',expect.objectContaining({selected:true}));
  await act(async()=>fireEvent.press(screen.getByRole('button',{name:'Save selection'})));
  expect(command).toHaveBeenCalledTimes(1);
});
test('profile picker only offers its native eligible encrypted choices',()=>{
  mockExploreParams={target:'profile'};const live=tierSnapshot();live.dnsPatch={available:true,state:'disabled',busy:false,choices:[dnsTier('google-dot','Google','DoT'),dnsTier('cloudflare-doh','Cloudflare','DoH')]};
  render(<Provider live={live}><DNSPickerScreen/></Provider>);
  expect(screen.queryByText('Device')).toBeNull();expect(screen.queryByText('IP')).toBeNull();expect(screen.queryByText('DoQ')).toBeNull();
  expect(screen.getAllByText('DoT').length).toBeGreaterThan(0);expect(screen.getAllByText('DoH').length).toBeGreaterThan(0);
});


test('System DNS minus stages removal and only page Save with confirmation removes the profile',async()=>{
  const live=tierSnapshot();live.dnsPatch={available:true,state:'enabled',busy:false,provider:dnsTier('quad9-dot','Quad9','DoT')};
  const command=jest.fn().mockResolvedValue(null);const alert=jest.spyOn(Alert,'alert').mockImplementation(()=>{});
  const app={command} as unknown as AppStore;
  try {const view=render(<Provider live={live} app={app}><DNSScreen/></Provider>);
    const row=()=>screen.UNSAFE_getAllByType(ListRow).find(node=>node.props.title==='Quad9')!;
    expect(row().props.onPress).toBeUndefined();
    expect(screen.UNSAFE_queryAllByType(require('../src').LavaIconButton)).toHaveLength(0);
    act(()=>toolbarItems().find((item:{label:string})=>item.label==='Edit').onPress());
    fireEvent.press(row());expect(mockNavigate).toHaveBeenCalledWith('DNSPicker',{target:'profile'});
    const minus=screen.UNSAFE_getAllByType(require('../src').LavaIconButton).find(node=>node.props.item==='System DNS')!;
    expect(minus.props.icon).toBe('remove');fireEvent.press(minus);
    expect(screen.queryByText('Quad9')).toBeNull();
    expect(screen.getByText('System DNS not configured')).toBeOnTheScreen();
    expect(screen.getByText('Add System DNS')).toBeOnTheScreen();
    expect(screen.queryByText('Profile installed and selected')).toBeNull();
    expect(command).not.toHaveBeenCalled();expect(alert).not.toHaveBeenCalled();
    act(()=>toolbarItems().find((item:{label:string})=>item.label==='Save').onPress());
    expect(command).not.toHaveBeenCalled();
    const buttons=alert.mock.calls.at(-1)?.[2];
    expect(buttons?.map(button=>button.text)).toEqual(['Cancel','Remove profile']);
    await act(async()=>buttons?.find(button=>button.style==='destructive')?.onPress?.());
    expect(command).toHaveBeenCalledTimes(1);expect(command).toHaveBeenCalledWith({type:'settings.set',key:'dnsPatchRemove',value:true});
    view.rerender(<Provider live={{...live,dnsPatch:{...live.dnsPatch!,state:'absent',provider:null}}} app={app}><DNSScreen/></Provider>);
    expect(screen.getByText('System DNS not configured')).toBeOnTheScreen();
    expect(screen.queryByText('Quad9')).toBeNull();expect(screen.queryByText('Select the System DNS profile')).toBeNull();
    expect(screen.queryByText('Add System DNS')).toBeNull();
  } finally {alert.mockRestore();}
});

test('DNS Save without changed tiers does not rewrite native settings and live diagnostics do not rebuild the toolbar',async()=>{
  const live=tierSnapshot();const command=jest.fn();const app={command} as unknown as AppStore;
  const view=render(<Provider live={live} app={app}><DNSScreen/></Provider>);
  const before=mockSetOptions.mock.calls.length;
  view.rerender(<Provider live={{...live,dns:{...live.dns,tiers:live.dns.tiers?.map(row=>({...row,metadata:'Updated address'}))}}} app={app}><DNSScreen/></Provider>);
  expect(mockSetOptions.mock.calls).toHaveLength(before);
  act(()=>toolbarItems().find((item:{label:string})=>item.label==='Edit').onPress());
  await act(async()=>toolbarItems().find((item:{label:string})=>item.label==='Save').onPress());
  expect(command).not.toHaveBeenCalled();expect(toolbarItems().find((item:{label:string})=>item.label==='Edit')).toBeDefined();
});


test('VPN-owned DNS hides System DNS even when a profile is installed',()=>{
  const live=tierSnapshot();live.dns.editable=false;live.dnsPatch={available:true,state:'enabled',busy:false,provider:dnsTier('quad9-dot','Quad9','DoT')};
  render(<Provider live={live} app={{command:jest.fn()} as unknown as AppStore}><DNSScreen/></Provider>);
  expect(screen.queryByText('System DNS')).toBeNull();
  expect(screen.queryByText('Quad9')).toBeNull();
  expect(screen.queryByText('Cloudflare')).toBeNull();
  expect(toolbarItems()).toEqual([]);
});

test('missing System DNS keeps an empty panel and only offers Add in Edit',()=>{
  const command=jest.fn();const live=tierSnapshot();live.dnsPatch={available:true,state:'absent',busy:false,provider:null};
  render(<Provider live={live} app={{command} as unknown as AppStore}><DNSScreen/></Provider>);
  expect(screen.getByText('System DNS not configured')).toBeOnTheScreen();
  expect(screen.queryByText('Select the System DNS profile')).toBeNull();expect(screen.queryByText('Add System DNS')).toBeNull();
  act(()=>toolbarItems().find((item:{label:string})=>item.label==='Edit').onPress());
  fireEvent.press(screen.getByRole('button',{name:'Add System DNS'}));
  expect(mockNavigate).toHaveBeenCalledWith('DNSPicker',{target:'profile'});expect(command).not.toHaveBeenCalled();
});

test('canceling a staged System DNS removal preserves the installed provider',()=>{
  const live=tierSnapshot();live.dnsPatch={available:true,state:'enabled',busy:false,provider:dnsTier('quad9-dot','Quad9','DoT')};
  const command=jest.fn();const alert=jest.spyOn(Alert,'alert').mockImplementation(()=>{});
  try {render(<Provider live={live} app={{command} as unknown as AppStore}><DNSScreen/></Provider>);
    act(()=>toolbarItems().find((item:{label:string})=>item.label==='Edit').onPress());
    fireEvent.press(screen.UNSAFE_getAllByType(require('../src').LavaIconButton).find(node=>node.props.item==='System DNS')!);
    act(()=>toolbarItems('Left').find((item:{label:string})=>item.label==='Cancel editing').onPress());
    act(()=>alert.mock.calls.at(-1)?.[2]?.find(button=>button.text==='Discard')?.onPress?.());
    expect(screen.getByText('Quad9')).toBeOnTheScreen();expect(screen.getByText('Profile installed and selected')).toBeOnTheScreen();
    expect(command).not.toHaveBeenCalled();
  } finally {alert.mockRestore();}
});

test('System DNS picker only stages its selection',async()=>{
  mockExploreParams={target:'profile'};const live=tierSnapshot();const choice=dnsTier('quad9-dot','Quad9','DoT');
  live.dnsPatch={available:true,state:'absent',busy:false,provider:null,choices:[choice]};const command=jest.fn();
  let draftID:string|undefined;function Probe(){draftID=useDNSEditor().draft.systemDNS?.id;return null;}
  render(<Provider live={live} app={{command} as unknown as AppStore}><DNSPickerScreen/><Probe/></Provider>);
  fireEvent.press(screen.getByRole('button',{name:'Quad9'}));expect(draftID).toBeUndefined();
  await act(async()=>fireEvent.press(screen.getByRole('button',{name:'Save selection'})));
  expect(draftID).toBe(choice.id);expect(command).not.toHaveBeenCalled();expect(mockGoBack).toHaveBeenCalled();
});

test('page Save installs the staged System DNS choice and retains it after a failed save',async()=>{
  const live=tierSnapshot();live.dnsPatch={available:true,state:'absent',busy:false,provider:null};
  const choice=dnsTier('quad9-dot','Quad9','DoT');const command=jest.fn().mockRejectedValueOnce(new Error('Unable to save DNS configuration.')).mockResolvedValue(null);
  const alert=jest.spyOn(Alert,'alert').mockImplementation(()=>{});
  let stage!:()=>void;function PickerDraft(){const {draft,setDraft}=useDNSEditor();stage=()=>setDraft({...draft,systemDNS:choice});return null;}
  try {render(<Provider live={live} app={{command} as unknown as AppStore}><DNSScreen/><PickerDraft/></Provider>);
    act(()=>toolbarItems().find((item:{label:string})=>item.label==='Edit').onPress());act(()=>stage());
    expect(command).not.toHaveBeenCalled();expect(screen.getByText('Quad9')).toBeOnTheScreen();
    await act(async()=>toolbarItems().find((item:{label:string})=>item.label==='Save').onPress());
    expect(command).toHaveBeenCalledWith({type:'settings.set',key:'dnsPatchProvider',value:choice.id});
    expect(screen.getByText('Quad9')).toBeOnTheScreen();expect(toolbarItems().find((item:{label:string})=>item.label==='Save')).toBeDefined();
    await act(async()=>toolbarItems().find((item:{label:string})=>item.label==='Save').onPress());
    expect(command).toHaveBeenCalledTimes(2);expect(toolbarItems().find((item:{label:string})=>item.label==='Edit')).toBeDefined();
  }finally{alert.mockRestore();}
});


test('a mismatched DNS profile is repaired before opening Settings',async()=>{
  const live=tierSnapshot();live.dnsPatch={available:true,state:'different',busy:false,provider:dnsTier('quad9-dot','Quad9','DoT')};
  let complete!:()=>void;const command=jest.fn(()=>new Promise<void>(resolve=>{complete=resolve;}));
  const settings=jest.spyOn(Linking,'openSettings').mockResolvedValue();
  try{
    render(<Provider live={live} app={{command} as unknown as AppStore}><DNSScreen/></Provider>);
    fireEvent.press(screen.getByText('Select the System DNS profile'));
    expect(command).toHaveBeenCalledWith({type:'settings.set',key:'dnsPatchSetup',value:true});
    expect(settings).not.toHaveBeenCalled();
    await act(async()=>complete());
    expect(settings).toHaveBeenCalledTimes(1);
  }finally{settings.mockRestore();}
});
test('a failed DNS profile repair stays on the page and reports the failure',async()=>{
  const live=tierSnapshot();live.dnsPatch={available:true,state:'different',busy:false,provider:dnsTier('quad9-dot','Quad9','DoT')};
  const command=jest.fn().mockRejectedValue(new Error('Profile save failed.'));
  const settings=jest.spyOn(Linking,'openSettings').mockResolvedValue();const alert=jest.spyOn(Alert,'alert').mockImplementation(()=>{});
  try{
    render(<Provider live={live} app={{command} as unknown as AppStore}><DNSScreen/></Provider>);
    await act(async()=>fireEvent.press(screen.getByText('Select the System DNS profile')));
    expect(settings).not.toHaveBeenCalled();expect(alert.mock.calls[0]?.slice(0,2)).toEqual(['Lava','Profile save failed.']);
  }finally{settings.mockRestore();alert.mockRestore();}
});

function vpnSnapshot(overrides:Partial<NonNullable<AppSnapshot['vpn']>>={}):AppSnapshot {
  const live=tierSnapshot();live.qaTools=true;
  live.vpn={setup:true,enabled:false,canEnable:true,canEdit:true,fallback:false,canChangeFallback:true,
    needsPlus:false,busy:false,restriction:'',error:'',unavailable:false,generation:'42',rows:[],...overrides};return live;
}
const vpnCommands=(rows:NonNullable<AppSnapshot['vpn']>['rows']=[])=>jest.fn(async(command:any):Promise<any>=>{
  if(command.type==='vpn.begin')return {id:command.id,revision:0,changed:false,containsFullTunnel:false,rows};
  return null;
});
test('VPN prerequisite hides the lower page and edit action while retaining provider guidance',()=>{
  const command=vpnCommands();
  render(<Provider live={vpnSnapshot({setup:false})} app={{command} as unknown as AppStore}><VPNChainingScreen/></Provider>);
  expect(screen.getByText('Get a WireGuard config from your VPN provider.')).toBeOnTheScreen();
  expect(screen.queryByTestId('vpn.configuration-panel')).toBeNull();expect(toolbarItems()).toEqual([]);
  expect(command).not.toHaveBeenCalled();
});
test('empty VPN panel retains Add while opening the native editor, without collapsing on busy',async()=>{
  let finish!:()=>void;const command=vpnCommands();
  command.mockImplementation(async input=>input.type==='vpn.begin'?{id:input.id,revision:0,changed:false,containsFullTunnel:false,rows:[]}:new Promise<void>(resolve=>{finish=resolve;}));
  render(<Provider live={vpnSnapshot()} app={{command} as unknown as AppStore}><VPNChainingScreen/></Provider>);
  await act(async()=>toolbarAction('Edit').onPress());
  fireEvent.press(screen.getByText('Add configuration'));await act(async()=>{});
  expect(screen.getByText('Add configuration')).toBeOnTheScreen();
  expect(command).toHaveBeenCalledWith(expect.objectContaining({type:'vpn.edit',index:0}));
  await act(async()=>finish());
});
test('VPN rows only open configuration sheets after entering edit mode',async()=>{
  const rows=[{name:'Entry',mode:'Full tunnel'}];const command=vpnCommands(rows);
  render(<Provider live={vpnSnapshot({rows})} app={{command} as unknown as AppStore}><VPNChainingScreen/></Provider>);
  fireEvent.press(screen.getByText('Entry'));await act(async()=>{});
  expect(command).not.toHaveBeenCalled();
  await act(async()=>toolbarAction('Edit').onPress());
  fireEvent.press(screen.getByText('Entry'));await act(async()=>{});
  expect(command).toHaveBeenCalledWith(expect.objectContaining({type:'vpn.edit',index:0}));
});
test('two VPN rows reuse DNS numbered rows and disallow a third addition',async()=>{
  const rows=[{name:'Entry',mode:'Full tunnel'},{name:'Exit',mode:'Full tunnel'}];const command=vpnCommands(rows);
  render(<Provider live={vpnSnapshot({rows})} app={{command} as unknown as AppStore}><VPNChainingScreen/></Provider>);
  await act(async()=>toolbarAction('Edit').onPress());
  expect(screen.queryByText('Add configuration')).toBeNull();
  const rendered=screen.UNSAFE_getAllByType(ListRow).filter(row=>['Entry','Exit'].includes(row.props.title));
  expect(rendered.map(row=>row.props.leading.props.name)).toEqual(['1.circle','2.circle']);
  expect(screen.getAllByRole('button',{name:'Remove'})).toHaveLength(2);
  fireEvent.press(screen.getByText('Exit'));await act(async()=>{});
  expect(command).toHaveBeenCalledWith(expect.objectContaining({type:'vpn.edit',index:1}));
  expect(command).not.toHaveBeenCalledWith(expect.objectContaining({type:'vpn.commit'}));
});
test('VPN Swap order stages native row identities without committing profiles or rebuilding the toolbar',async()=>{
  const rows=[{name:'Entry',mode:'Full tunnel'},{name:'Exit',mode:'Full tunnel'}];const command=vpnCommands(rows);
  const base=command.getMockImplementation()!;
  command.mockImplementation(async input=>input.type==='vpn.swap'?{id:input.id,revision:1,changed:true,containsFullTunnel:true,rows:[...rows].reverse()}:base(input));
  render(<Provider live={vpnSnapshot({rows})} app={{command} as unknown as AppStore}><VPNChainingScreen/></Provider>);
  expect(screen.queryByText('Swap order')).toBeNull();
  await act(async()=>toolbarAction('Edit').onPress());
  expect(screen.queryByText('Add configuration')).toBeNull();
  const swap=screen.UNSAFE_getAllByType(LavaActionButton).find(button=>button.props.title==='Swap order')!;
  expect(swap.props.role).toBe('panel');expect(swap.props.icon).toBe('swap');
  const save=toolbarAction('Save');mockSetOptions.mockClear();
  await act(async()=>fireEvent.press(swap));
  expect(mockSetOptions).not.toHaveBeenCalled();
  const rendered=screen.UNSAFE_getAllByType(ListRow).filter(row=>['Entry','Exit'].includes(row.props.title));
  expect(rendered.map(row=>row.props.title)).toEqual(['Exit','Entry']);
  expect(rendered.map(row=>row.props.leading.props.name)).toEqual(['1.circle','2.circle']);
  expect(command.mock.calls.map(([input])=>input.type)).toEqual(['vpn.begin','vpn.swap']);
  await act(async()=>save.onPress());
  expect(command).toHaveBeenCalledWith({type:'vpn.commit',id:expect.any(String)});
});
test('VPN Save keeps the latest sheet draft visible until the commit acknowledgement',async()=>{
  const rows=[{name:'Entry',mode:'Split tunnel'}];const both=[...rows,{name:'Second',mode:'Full tunnel'}];
  const command=vpnCommands(rows);const base=command.getMockImplementation()!;
  let finish!:()=>void;let id='';
  command.mockImplementation(async input=>{if(input.type==='vpn.begin')id=input.id;
    if(input.type==='vpn.commit')return new Promise<void>(resolve=>{finish=resolve;});return base(input);});
  const app={command} as unknown as AppStore;const live=vpnSnapshot({rows});
  const view=render(<Provider live={live} app={app}><VPNChainingScreen/></Provider>);
  await act(async()=>toolbarAction('Edit').onPress());
  // The native sheet publishes revision 1 without a page stage() callback.
  view.rerender(<Provider live={vpnSnapshot({rows,draft:{id,revision:1,changed:true,containsFullTunnel:true,rows:both}})} app={app}><VPNChainingScreen/></Provider>);
  act(()=>toolbarAction('Save').onPress());
  // Native completion publishes saved rows / clears its draft before the Promise resolves.
  view.rerender(<Provider live={vpnSnapshot({rows:both,draft:null})} app={app}><VPNChainingScreen/></Provider>);
  expect(screen.getByText('Second')).toBeOnTheScreen();
  expect(screen.getByText('Swap order')).toBeOnTheScreen();
  expect(screen.queryByText('Add configuration')).toBeNull();
  await act(async()=>finish());
  expect(screen.getByText('Second')).toBeOnTheScreen();
  expect(toolbarAction('Edit')).toBeDefined();
});
test('an incompatible VPN swap reports the native refusal and leaves the visible order unchanged',async()=>{
  const rows=[{name:'Full',mode:'Full tunnel'},{name:'Split',mode:'Split tunnel'}];const command=vpnCommands(rows);
  const base=command.getMockImplementation()!;command.mockImplementation(async input=>{if(input.type==='vpn.swap')throw new Error('The first full-tunnel configuration needs a larger MTU.');return base(input);});
  const alert=jest.spyOn(Alert,'alert').mockImplementation(()=>{});
  try{
    render(<Provider live={vpnSnapshot({rows})} app={{command} as unknown as AppStore}><VPNChainingScreen/></Provider>);
    await act(async()=>toolbarAction('Edit').onPress());
    await act(async()=>fireEvent.press(screen.getByText('Swap order')));
    expect(screen.UNSAFE_getAllByType(ListRow).filter(row=>['Full','Split'].includes(row.props.title)).map(row=>row.props.title)).toEqual(['Full','Split']);
    expect(alert).toHaveBeenCalled();
    expect(command).not.toHaveBeenCalledWith(expect.objectContaining({type:'vpn.commit'}));
  }finally{alert.mockRestore();}
});
test('full-tunnel presence disables fallback and replaces its deeplink with an explanation',()=>{
  render(<Provider live={vpnSnapshot({canChangeFallback:false})} app={{command:vpnCommands()} as unknown as AppStore}><VPNChainingScreen/></Provider>);
  const toggle=screen.UNSAFE_getAllByType(Toggle).find(row=>row.props.title==='Use Lava DNS settings as fallback')!;
  expect(toggle.props.disabled).toBe(true);
  expect(screen.getByText('DNS fallback is unavailable with an active full-tunnel VPN.')).toBeOnTheScreen();
  expect(screen.queryByText('Review DNS settings')).toBeNull();
});
test.each(['setup','fallback'] as const)('VPN %s toggle persists independently without entering WireGuard editing',async key=>{
  const command=vpnCommands();
  render(<Provider live={vpnSnapshot({rows:[{name:'Entry',mode:'Split tunnel'}]})} app={{command} as unknown as AppStore}><VPNChainingScreen/></Provider>);
  await act(async()=>screen.UNSAFE_getAllByType(Toggle).find(row=>row.props.testID===`vpn.${key}-toggle`)!.props.onChange(key!=='setup'));
  expect(command.mock.calls.map(([input])=>input)).toEqual([{type:'vpn.toggle',key,value:key!=='setup'}]);
  expect(toolbarAction('Edit')).toBeDefined();
  expect(screen.queryByText('Add configuration')).toBeNull();
});
test('VPN numbered row switches replace routing row and disappear in edit mode',async()=>{
  const rows=[{name:'Entry',mode:'Full tunnel',isEnabled:true},{name:'Exit',mode:'Split tunnel',isEnabled:false}];
  const command=vpnCommands(rows);
  render(<Provider live={vpnSnapshot({rows,enabled:true})} app={{command} as unknown as AppStore}><VPNChainingScreen/></Provider>);
  const controls=screen.UNSAFE_getAllByType(require('../src').LavaToggleControl);
  expect(controls.map(row=>row.props.value)).toEqual([true,false]);
  expect(screen.queryByText('Route my traffic through this VPN setup')).toBeNull();
  expect(screen.getByText('The order determines which VPN your traffic uses and when it uses both.')).toBeOnTheScreen();
  await act(async()=>controls[1].props.onValueChange(true));
  expect(command).toHaveBeenCalledWith({type:'vpn.rowToggle',generation:'42',index:1,value:true});
  await act(async()=>toolbarAction('Edit').onPress());
  expect(screen.UNSAFE_queryAllByType(require('../src').LavaToggleControl)).toHaveLength(0);
});
test('DNS numbered row switches preserve the last active row and disappear in edit mode',async()=>{
  const live=tierSnapshot();live.dns.tiers=[{...dnsTier('cloudflare-doh','Cloudflare','DoH'),isEnabled:false},{...dnsTier('quad9-dot','Quad9','DoT'),isEnabled:true}];
  const command=jest.fn().mockResolvedValue(null);
  render(<Provider live={live} app={{command} as unknown as AppStore}><DNSScreen/></Provider>);
  const controls=screen.UNSAFE_getAllByType(require('../src').LavaToggleControl);
  expect(controls.map(row=>[row.props.value,row.props.disabled])).toEqual([[false,false],[true,true]]);
  await act(async()=>controls[0].props.onValueChange(true));
  expect(command).toHaveBeenCalledWith({type:'dns.toggle',context:live.dns.tiersContext,index:0,value:true});
  act(()=>toolbarAction('Edit').onPress());
  expect(screen.UNSAFE_queryAllByType(require('../src').LavaToggleControl)).toHaveLength(0);
});
test('System DNS explanatory text follows both the provider and selection indicator',()=>{
  const live=tierSnapshot();live.dnsPatch={available:true,state:'enabled',busy:false,provider:dnsTier('quad9-dot','Quad9','DoT')};
  render(<Provider live={live} app={{command:jest.fn()} as unknown as AppStore}><DNSScreen/></Provider>);
  const section=screen.UNSAFE_getAllByType(require('../review/primitives').Section).find(node=>node.props.title==='System DNS')!;
  const children=require('react').Children.toArray(section.props.children) as any[];
  expect(children.at(-1)?.props.children).toBe('This profile handles system DNS requests and helps Lava filter with Connectivity Assist.');
});
test('a no-change checkmark exits WireGuard edit mode without committing or flashing a disabled action',async()=>{
  const command=vpnCommands();
  render(<Provider live={vpnSnapshot()} app={{command} as unknown as AppStore}><VPNChainingScreen/></Provider>);
  const back=toolbarAction('Back','Left');const edit=toolbarAction('Edit');
  await act(async()=>edit.onPress());
  expect(toolbarAction('Cancel editing','Left').identifier).toBe(back.identifier);
  expect(toolbarAction('Save').identifier).toBe(edit.identifier);
  expect(toolbarAction('Save').disabled).toBe(false);
  const save=toolbarAction('Save');mockSetOptions.mockClear();
  await act(async()=>save.onPress());
  expect(command.mock.calls.map(([input])=>input.type)).toEqual(['vpn.begin','vpn.cancel']);
  expect(toolbarAction('Edit').disabled).toBe(false);
  expect(mockSetOptions.mock.calls).toHaveLength(1);
});
test('opening another WireGuard row leaves the native toolbar identity untouched',async()=>{
  const rows=[{name:'Entry',mode:'Full tunnel'},{name:'Exit',mode:'Split tunnel'}];const command=vpnCommands(rows);
  render(<Provider live={vpnSnapshot({rows})} app={{command} as unknown as AppStore}><VPNChainingScreen/></Provider>);
  await act(async()=>toolbarAction('Edit').onPress());mockSetOptions.mockClear();
  await act(async()=>fireEvent.press(screen.getByText('Entry')));
  await act(async()=>fireEvent.press(screen.getByText('Exit')));
  expect(mockSetOptions).not.toHaveBeenCalled();
});
test('cancel confirms staged row removal and leaves saved settings active',async()=>{
  const alert=jest.spyOn(Alert,'alert').mockImplementation(()=>{});const rows=[{name:'Entry',mode:'Split tunnel'}];const command=vpnCommands(rows);
  const base=command.getMockImplementation()!;
  command.mockImplementation(async input=>input.type==='vpn.remove'?{id:input.id,revision:1,changed:true,containsFullTunnel:false,rows:[]}:base(input));
  try{
    render(<Provider live={vpnSnapshot({rows})} app={{command} as unknown as AppStore}><VPNChainingScreen/></Provider>);
    await act(async()=>toolbarAction('Edit').onPress());
    await act(async()=>fireEvent.press(screen.getByRole('button',{name:'Remove'})));
    act(()=>toolbarAction('Cancel editing','Left').onPress());
    await act(async()=>alert.mock.calls.at(-1)![2]!.find(button=>button.text==='Discard')!.onPress!());
    expect(screen.getByText('Entry')).toBeOnTheScreen();
    expect(command.mock.calls.map(([input])=>input.type)).toEqual(['vpn.begin','vpn.remove','vpn.cancel']);
  }finally{alert.mockRestore();}
});
test('VPN OFF consumes the authoritative DNS snapshot while setup stays ON',async()=>{
  const initial=vpnSnapshot({enabled:true,rows:[{name:'Entry',mode:'Full tunnel'}],canChangeFallback:false});initial.dns.editable=false;
  const updated={...initial,vpn:{...initial.vpn!,enabled:false},dns:{...initial.dns,editable:true}};
  const command=vpnCommands();
  function Harness({dns=false}:{dns?:boolean}) {
    const [live,setLive]=useState(initial);
    const [app]=useState(()=>({command:command.mockImplementation(async input=>{expect(input).toEqual({type:'vpn.rowToggle',generation:'42',index:0,value:false});setLive(updated);return null;})} as unknown as AppStore));
    return <Provider live={live} app={app}>{dns?<DNSScreen/>:<VPNChainingScreen/>}</Provider>;
  }
  const view=render(<Harness/>);
  await act(async()=>screen.UNSAFE_getAllByType(require('../src').LavaToggleControl).find(row=>row.props.testID==='vpn.row-toggle.0')!.props.onValueChange(false));
  expect(screen.UNSAFE_getAllByType(Toggle).find(row=>row.props.testID==='vpn.setup-toggle')!.props.value).toBe(true);
  view.rerender(<Harness dns/>);
  expect(screen.getByText('DNS order')).toBeOnTheScreen();
  expect(screen.queryByText('Review VPN chaining')).toBeNull();
});
test('unreadable VPN storage stages recovery until page Save',async()=>{
  const command=vpnCommands();
  command.mockImplementation(async input=>({id:input.id,revision:input.type==='vpn.reset'?1:0,changed:input.type==='vpn.reset',containsFullTunnel:false,rows:[]}));
  render(<Provider live={vpnSnapshot({unavailable:true,needsRepair:true})} app={{command} as unknown as AppStore}><VPNChainingScreen/></Provider>);
  await act(async()=>toolbarAction('Edit').onPress());
  expect(screen.queryByText('Add configuration')).toBeNull();
  fireEvent.press(screen.getByText('Delete configuration'));await act(async()=>{});
  expect(command.mock.calls.map(([input])=>input.type)).toEqual(['vpn.begin','vpn.reset']);
});
test('missing VPN keys keep recovery available without Add or Swap',async()=>{
  const rows=[{name:'Entry',mode:'Full tunnel'},{name:'Exit',mode:'Full tunnel'}];const command=vpnCommands(rows);
  render(<Provider live={vpnSnapshot({needsRepair:true,unavailable:false,rows})} app={{command} as unknown as AppStore}><VPNChainingScreen/></Provider>);
  await act(async()=>toolbarAction('Edit').onPress());
  expect(screen.queryByText('Swap order')).toBeNull();expect(screen.queryByText('Add configuration')).toBeNull();
  expect(screen.getByText('Delete configuration')).toBeOnTheScreen();
});
test('ineligible VPN rows retain removal without offering an unusable editor',async()=>{
  const rows=[{name:'Entry',mode:'Full tunnel'}];const command=vpnCommands(rows);
  render(<Provider live={vpnSnapshot({canEdit:false,rows})} app={{command} as unknown as AppStore}><VPNChainingScreen/></Provider>);
  await act(async()=>toolbarAction('Edit').onPress());
  expect(screen.queryByText('Add configuration')).toBeNull();expect(screen.getByTestId('vpn.configuration-row')).toBeDisabled();
  expect(screen.getByRole('button',{name:'Remove'})).toBeEnabled();
});

test('failed VPN Save retains the staged values for retry without hiding the page',async()=>{
  const alert=jest.spyOn(Alert,'alert').mockImplementation(()=>{});const command=vpnCommands();
  const base=command.getMockImplementation()!;
  command.mockImplementation(async input=>{if(input.type==='vpn.commit')throw new Error('Save failed.');if(input.type==='vpn.reset')return {id:input.id,revision:1,changed:true,containsFullTunnel:false,rows:[]};return base(input);});
  try{
    render(<Provider live={vpnSnapshot({needsRepair:true})} app={{command} as unknown as AppStore}><VPNChainingScreen/></Provider>);
    await act(async()=>toolbarAction('Edit').onPress());
    await act(async()=>fireEvent.press(screen.getByText('Delete configuration')));
    await act(async()=>toolbarAction('Save').onPress());
    expect(screen.getByTestId('vpn.configuration-panel')).toBeOnTheScreen();
    expect(toolbarAction('Save').disabled).toBe(false);
    expect(command).not.toHaveBeenCalledWith(expect.objectContaining({type:'vpn.cancel'}));
  }finally{alert.mockRestore();}
});
