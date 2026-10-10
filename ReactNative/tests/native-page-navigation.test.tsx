import type {PropsWithChildren} from 'react';
import {AppState} from 'react-native';
import {act,fireEvent,render,screen} from '@testing-library/react-native';
import {AutoSwitchScreen,VPNChainingScreen,DNSPatchScreen,CustomEntryScreen} from '../review/NativePageScreen';
import {CustomEntryRoute} from '../review/CustomEntryScreen';
import {DNSScreen} from '../review/DNSScreen';
import {useDNSEditor} from '../review/dns-editor';
import {LiveRenderBoundary,ReviewContext,type ReviewState} from '../review/ReviewContext';
import {initialSession} from '../review/session';
import type {AppCommand} from '../app/contract';
import {Sheet} from '../review/scaffold';

const mockNavigate=jest.fn();const mockGoBack=jest.fn();const mockGetState=jest.fn();
let mockParams:{returnTo?:'DNS';returnKey?:string;id?:string;kind?:'dns'|'blocklist'}|undefined;
let mockFocused=true;
const mockSetOptions=jest.fn();
const mockNavigation={addListener:jest.fn(()=>()=>{}),setOptions:mockSetOptions,navigate:mockNavigate,goBack:mockGoBack,getState:mockGetState};
let previousAppPhase:typeof AppState.currentState;
jest.mock('@react-navigation/native',()=>({useNavigation:()=>mockNavigation,useRoute:()=>({key:'native-page',params:mockParams}),useIsFocused:()=>mockFocused,usePreventRemove:jest.fn()}));
jest.mock('../specs/NativeLavaReview',()=>({__esModule:true,default:{getGuardAccents:()=>JSON.stringify({original:{light:'#BF4000',dark:'#FF8855'}})}}));
jest.mock('../specs/LavaSliderNativeComponent',()=>({__esModule:true,default:require('react-native').View}));
jest.mock('../specs/LavaNativePageNativeComponent' ,()=>({__esModule:true,default:require('react-native').View}));
jest.mock('react-native-safe-area-context',()=>require('react-native-safe-area-context/jest/mock').default);

beforeEach(()=>{
  previousAppPhase=AppState.currentState;
  mockParams=undefined;mockFocused=true;mockSetOptions.mockClear();mockNavigate.mockClear();mockGoBack.mockClear();
  mockGetState.mockReturnValue({index:1,routes:[{name:'Settings',key:'settings'},{name:'VPNChaining',key:'native-page'}]});
  jest.spyOn(AppState,'addEventListener').mockReturnValue({remove:jest.fn()});
});
afterEach(()=>{AppState.currentState=previousAppPhase;jest.restoreAllMocks();});
test('the real retained DNS parent restores its selection context and clears it on actual removal after reauthorization',async()=>{
  let editor!:ReturnType<typeof useDNSEditor>;
  function Observer(){editor=useDNSEditor();return null;}
  const tier={id:'device',name:'Device DNS',primary:'',secondary:'',transport:'Device',metadata:'',isEnabled:true};
  const app={command:jest.fn(async()=>null)};
  const live={dns:{editable:true,tiers:[tier],tiersContext:'original-native-context'},security:{ownerRevision:'owner',readRevision:1}};
  const content=(snapshot:typeof live|undefined,mounted=true)=><ReviewContext.Provider value={{app,live:snapshot,session:initialSession()} as unknown as ReviewState}><Observer/>{mounted&&<LiveRenderBoundary component={DNSScreen} retainBody/>}</ReviewContext.Provider>;
  const view=render(content(live));await act(async()=>{});
  act(()=>mockSetOptions.mock.calls.at(-1)![0].unstable_headerRightItems()[0].onPress());await act(async()=>{});
  expect(editor.draft.context).toBe('original-native-context');
  const chosen={...tier,id:'custom-dns',name:'Retained resolver',primary:'https://dns.example.test/dns-query',transport:'DoH'};
  act(()=>editor.setDraft({...editor.draft,tiers:[chosen]}));
  view.rerender(content(undefined));await act(async()=>{});
  expect(screen.queryByText('Retained resolver')).toBeNull();expect(editor.draft.tiers).toEqual([]);
  view.rerender(content({...live,security:{...live.security,readRevision:2}}));await act(async()=>{});
  expect(editor.draft.context).toBe('original-native-context');expect(editor.draft.tiers).toEqual([chosen]);
  expect(screen.getByText('Retained resolver')).toBeTruthy();
  view.rerender(content(live,false));await act(async()=>{});
  expect(editor.draft).toEqual({tiers:[],context:''});
});
test('the real retained VPN parent keeps the same native draft through privacy revocation and cancels only on removal',async()=>{
  AppState.currentState='active';
  const draft={id:'parent-draft',revision:1,changed:false,containsFullTunnel:false,rows:[]};
  const command=jest.fn(async(action:AppCommand)=>action.type==='vpn.begin'?draft:null);const app={command};
  const live={vpn:{authorized:true,setup:true,enabled:false,canEdit:true,canChangeFallback:true,rows:[],generation:'saved'},plus:{enabled:true},security:{ownerRevision:'owner',readRevision:1}};
  const content=(snapshot:typeof live|undefined)=><ReviewContext.Provider value={{app,live:snapshot,session:initialSession()} as unknown as ReviewState}><LiveRenderBoundary component={VPNChainingScreen} retainBody/></ReviewContext.Provider>;
  const view=render(content(live));await act(async()=>{});
  act(()=>mockSetOptions.mock.calls.at(-1)![0].unstable_headerRightItems()[0].onPress());await act(async()=>{});
  expect(screen.getByRole('button',{name:'Add configuration'})).toBeTruthy();
  expect(command.mock.calls.map(([action])=>action.type)).toEqual(['vpn.begin']);
  view.rerender(content(undefined));await act(async()=>{});
  expect(screen.queryByRole('button',{name:'Add configuration'})).toBeNull();
  expect(screen.getByTestId('lava-route-privacy-cover')).toBeTruthy();
  expect(command.mock.calls.map(([action])=>action.type)).toEqual(['vpn.begin']);
  view.rerender(content({...live,security:{...live.security,readRevision:2}}));await act(async()=>{});
  fireEvent.press(screen.getByRole('button',{name:'Add configuration'}));await act(async()=>{});
  expect(command).toHaveBeenCalledWith({type:'vpn.edit',id:'parent-draft',index:0});
  expect(command.mock.calls.some(([action])=>action.type==='vpn.cancel')).toBe(false);
  view.unmount();await act(async()=>{});
  expect(command.mock.calls.at(-1)).toEqual([{type:'vpn.cancel',id:'parent-draft'}]);
});
function provider(command=jest.fn().mockResolvedValue(null),qaTools=true){
  return ({children}:PropsWithChildren)=><ReviewContext.Provider value={{app:{command},live:{qaTools,vpn:{authorized:true,setup:true,rows:[],generation:"",canChangeFallback:true}},session:initialSession()} as unknown as ReviewState}>{children}</ReviewContext.Provider>;
}
test('shared Auto-switch renders the real instructions and opens only the requested system destination',async()=>{
  const command=jest.fn().mockResolvedValue(null);
  const view=render(<AutoSwitchScreen/>,{wrapper:provider(command)});
  expect(screen.getByText('Switch filters on a schedule or with a Focus.')).toBeTruthy();
  expect(screen.getByText('Choose Lava, then pick the filter to switch to.')).toBeTruthy();
  expect(command).not.toHaveBeenCalled();
  fireEvent.press(screen.getByText('Open Shortcuts'));await act(async()=>{});
  expect(command.mock.calls).toEqual([[{type:'system.open',target:'shortcuts'}]]);
  fireEvent.press(screen.getByText('Open the Settings app'));await act(async()=>{});
  expect(command.mock.calls.at(-1)).toEqual([{type:'system.open',target:'settings'}]);
  mockFocused=false;view.rerender(<AutoSwitchScreen/>);
  mockFocused=true;view.rerender(<AutoSwitchScreen/>);
  expect(command).toHaveBeenCalledTimes(2);
  expect(mockNavigate).not.toHaveBeenCalled();
  expect(mockGoBack).not.toHaveBeenCalled();
});


test('DNS patch uses the same native scaffold boundary as Auto-switch without setup on mount',()=>{
  const command=jest.fn();
  render(<DNSPatchScreen/>,{wrapper:provider(command)});
  expect(screen.getByTestId('dns-patch-page').props.page).toBe('dnsPatch');
  expect(command).not.toHaveBeenCalled();
});

test('DNS patch opens VPN chaining through the protected parent navigator',async()=>{
  const command=jest.fn().mockResolvedValue(null);
  render(<DNSPatchScreen/>,{wrapper:provider(command)});
  fireEvent(screen.getByTestId('dns-patch-page'),'navigate',{nativeEvent:{destination:'VPNChaining'}});
  await act(async()=>{});
  expect(command).toHaveBeenCalledWith({type:'navigation.authorize',surface:'appSettings'});
  expect(mockNavigate).toHaveBeenCalledWith('VPNChaining');
});


test.each([true,false])('patch discovery acknowledges only a focused page (%s), never DNS setup',async focused=>{
  mockFocused=focused;
  const command=jest.fn().mockResolvedValue(null);
  const wrapper=({children}:PropsWithChildren)=><ReviewContext.Provider value={{app:{command},live:{discoveries:{'ios27Patch.page':true}},session:initialSession()} as unknown as ReviewState}>{children}</ReviewContext.Provider>;
  render(<DNSPatchScreen/>,{wrapper});
  await act(async()=>{});
  expect(command.mock.calls).toEqual(focused?[[{type:'discovery.seen',target:'ios27Patch.page'}]]:[]);
});

// Both forms return to their retained picker and release only their own draft.
test.each(['dns','blocklist'] as const)('custom %s Close returns without saving and releases its draft on removal',async kind=>{
  mockParams={id:'custom-draft',kind};
  const command=jest.fn().mockResolvedValue(null);
  const view=render(<CustomEntryScreen/>,{wrapper:provider(command)});
  const options=mockSetOptions.mock.calls.at(-1)![0];
  const close=options.unstable_headerLeftItems()[0];
  expect(close.identifier).toBe('lava.toolbar.close');
  expect(close.icon).toEqual({type:'sfSymbol',name:'xmark'});
  act(()=>close.onPress());
  expect(mockGoBack).toHaveBeenCalledTimes(1);
  expect(mockNavigate).not.toHaveBeenCalled();
  expect(command).not.toHaveBeenCalled();
  view.unmount();
  await act(async()=>{});
  expect(command.mock.calls).toEqual([[{type:'customEntry.dismiss',id:'custom-draft'}]]);
});
test.each(['dns','blocklist'] as const)('custom %s form conceals retained text and reauthorizes the exact visit',async kind=>{
  mockParams={id:'custom-draft',kind};
  const previous=AppState.currentState;Object.defineProperty(AppState,'currentState',{configurable:true,value:'active'});
  try{
    const command=jest.fn(async(_action:AppCommand)=>null);
    const app={command};
    const entry={id:'custom-draft',kind,name:'',primary:'1.1.1.1',secondary:'',allowed:true,overBudget:false};
    const content=(authorized:boolean,revision:number,background=false)=><ReviewContext.Provider value={{app,live:background?undefined:{customEntry:authorized?entry:null,security:{readRevision:revision}},session:initialSession()} as unknown as ReviewState}><CustomEntryRoute/></ReviewContext.Provider>;
    const view=render(content(true,1));await act(async()=>{});
    const sheet=screen.UNSAFE_getByType(Sheet),field=screen.getByLabelText('Name (optional)');
    fireEvent.changeText(screen.getByLabelText('Name (optional)'),'Private draft');
    Object.defineProperty(AppState,'currentState',{configurable:true,value:'background'});
    view.rerender(content(false,2,true));await act(async()=>{});
    expect(screen.getByTestId('custom-entry-privacy-cover')).toBeTruthy();
    expect(screen.queryByLabelText('Name (optional)')).toBeNull();
    expect(screen.UNSAFE_getByType(Sheet)).toBe(sheet);
    expect(screen.getByLabelText('Name (optional)',{includeHiddenElements:true})).toBe(field);
    expect(screen.getByLabelText('Name (optional)',{includeHiddenElements:true}).props.editable).toBe(false);
    expect(command).not.toHaveBeenCalled();
    Object.defineProperty(AppState,'currentState',{configurable:true,value:'active'});
    view.rerender(content(false,2));await act(async()=>{});
    expect(screen.getByTestId('custom-entry-privacy-cover')).toBeTruthy();
    expect(screen.queryByLabelText('Name (optional)')).toBeNull();
    expect(command).toHaveBeenCalledWith({type:'customEntry.enter',id:'custom-draft'});
    expect(command.mock.calls.some((args)=>args[0]?.type==='customEntry.save')).toBe(false);
    view.rerender(content(true,3));await act(async()=>{});
    expect(screen.getByLabelText('Name (optional)').props).toMatchObject({kind:'plain',value:'Private draft',resetRevision:0});
    expect(screen.UNSAFE_getByType(Sheet)).toBe(sheet);expect(screen.getByLabelText('Name (optional)')).toBe(field);
    expect(command.mock.calls.some((args)=>args[0]?.type==='customEntry.dismiss')).toBe(false);
    view.unmount();await act(async()=>{});
    expect(command.mock.calls.at(-1)).toEqual([{type:'customEntry.dismiss',id:'custom-draft'}]);
  }finally{Object.defineProperty(AppState,'currentState',{configurable:true,value:previous});}
});
test('custom entry initializes its fields before settling shared readiness after a blocked first projection',async()=>{
  AppState.currentState='active';mockParams={id:'custom-draft',kind:'dns'};
  const hydration={epoch:1,required:true};const ticket={epoch:1,id:1};
  const entry={id:'custom-draft',kind:'dns',name:'Native initial resolver',primary:'https://dns.example.test/dns-query',secondary:'',allowed:true,overBudget:false};
  let live:{customEntry:typeof entry|null;security:{ownerRevision:string;readRevision:number}}={customEntry:null,security:{ownerRevision:'owner',readRevision:2}};
  const settle=jest.fn();const app={command:jest.fn(async()=>null),getSnapshot:()=>({snapshot:live}),getReadEpoch:()=>2,
    getPresentationHydration:()=>hydration,subscribe:()=>()=>{},registerPresentationRead:()=>ticket,settlePresentationRead:settle};
  const content=()=><ReviewContext.Provider value={{app,live,session:initialSession()} as unknown as ReviewState}><CustomEntryScreen/></ReviewContext.Provider>;
  const view=render(content());await act(async()=>{});const sheet=screen.UNSAFE_getByType(Sheet);
  expect(settle).not.toHaveBeenCalled();expect(screen.getByTestId('custom-entry-privacy-cover')).toBeTruthy();
  live={...live,customEntry:entry};view.rerender(content());await act(async()=>{});
  expect(screen.UNSAFE_getByType(Sheet)).toBe(sheet);
  expect(screen.getByLabelText('Name (optional)',{includeHiddenElements:true}).props).toMatchObject({value:'Native initial resolver',resetRevision:1});
  expect(screen.getByLabelText('Primary DNS',{includeHiddenElements:true}).props).toMatchObject({value:entry.primary,resetRevision:1});
  expect(settle).toHaveBeenCalledWith(ticket);
});
test('failed custom entry preparation releases shared readiness to an explicit retry, without unmounting fields',async()=>{
  AppState.currentState='active';mockParams={id:'custom-draft',kind:'dns'};
  const hydration={epoch:1,required:true},ticket={epoch:1,id:1};
  const live={customEntry:null,security:{ownerRevision:'owner',readRevision:2}};
  const settle=jest.fn();const command=jest.fn(async()=>{throw new Error('Native editor unavailable');});
  const app={command,getSnapshot:()=>({snapshot:live}),getPresentationHydration:()=>hydration,subscribe:()=>()=>{},registerPresentationRead:()=>ticket,settlePresentationRead:settle};
  render(<ReviewContext.Provider value={{app,live,session:initialSession()} as unknown as ReviewState}><CustomEntryScreen/></ReviewContext.Provider>);
  await act(async()=>{});expect(settle).toHaveBeenCalledWith(ticket);
  expect(screen.getByText('Native editor unavailable')).toBeTruthy();
  expect(screen.getByRole('button',{name:'Unlock Lava'})).toBeTruthy();
  expect(screen.getByLabelText('Name (optional)',{includeHiddenElements:true}).props.editable).toBe(false);
});

test('custom entry authorizes its retained visit beneath the resume cover after native authority returns',async()=>{
  mockParams={id:'custom-draft',kind:'dns'};
  const previous=AppState.currentState;Object.defineProperty(AppState,'currentState',{configurable:true,value:'active'});
  try{
    let authoritative=false;const listeners=new Set<()=>void>();const command=jest.fn(async(_action:AppCommand)=>null);
    const app={command,getSnapshot:()=>({snapshot:authoritative?{}:null}),getPresentationHydration:()=>({required:true}),subscribe:(listener:()=>void)=>{listeners.add(listener);return()=>{listeners.delete(listener);};}};
    render(<ReviewContext.Provider value={{app,live:{customEntry:null,security:{readRevision:2}},session:initialSession()} as unknown as ReviewState}><CustomEntryScreen/></ReviewContext.Provider>);
    await act(async()=>{});expect(command).not.toHaveBeenCalled();
    expect(screen.getByTestId('custom-entry-privacy-cover')).toBeTruthy();
    await act(async()=>{authoritative=true;for(const listener of listeners)listener();});
    expect(command.mock.calls).toEqual([[{type:'customEntry.enter',id:'custom-draft'}]]);
  }finally{Object.defineProperty(AppState,'currentState',{configurable:true,value:previous});}
});

test.each([true,false])('VPN DNS review returns only to the exact retained DNS editor (%s)',async exact=>{
  AppState.currentState='active';
  mockParams={returnTo:'DNS',returnKey:'original-dns'};
  mockGetState.mockReturnValue({index:1,routes:[{name:'DNS',key:exact?'original-dns':'other-dns'},{name:'VPNChaining',key:'native-page'}]});
  const command=jest.fn().mockResolvedValue(null);
  render(<VPNChainingScreen/>,{wrapper:provider(command)});
  await act(async()=>{});
  fireEvent.press(screen.getByText('Review DNS settings'));
  await act(async()=>{});
  // Exact returns use the retained route's usePreventRemove authentication gate.
  if(!exact)expect(command).toHaveBeenCalledWith({type:'navigation.authorize',surface:'appSettings'});
  if(exact){expect(mockGoBack).toHaveBeenCalledTimes(1);expect(mockNavigate).not.toHaveBeenCalled();}
  else {expect(mockGoBack).not.toHaveBeenCalled();expect(mockNavigate).toHaveBeenCalledWith('DNS');}
});

test('VPN page stays mounted through Control Center, background and focus changes like DNS',async()=>{
  AppState.currentState='active';
  const command=jest.fn().mockResolvedValue(null);
  const view=render(<VPNChainingScreen/>,{wrapper:provider(command)});
  const panel=screen.getByTestId('vpn.configuration-panel');
  for(const state of ['inactive','background','active'] as const){
    act(()=>{for(const [event,listener] of jest.mocked(AppState.addEventListener).mock.calls)if(event==='change')listener(state);});
    expect(screen.getByTestId('vpn.configuration-panel',{includeHiddenElements:true})).toBe(panel);
  }
  mockFocused=false;view.rerender(<VPNChainingScreen/>);
  mockFocused=true;view.rerender(<VPNChainingScreen/>);
  expect(screen.getByTestId('vpn.configuration-panel')).toBe(panel);
  expect(command).not.toHaveBeenCalled();
});
