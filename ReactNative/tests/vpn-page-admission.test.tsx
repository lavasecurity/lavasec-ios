import {AppState,type AppStateStatus} from 'react-native';
import {act,fireEvent,render,renderHook,screen} from '@testing-library/react-native';
import type {PropsWithChildren} from 'react';
import type {AppCommand,ForegroundFlow} from '../app/contract';
import {LiveRenderBoundary,ReviewContext,type ReviewState} from '../review/ReviewContext';
import {initialSession} from '../review/session';
import {useVPNPageAdmission} from '../review/vpn-page-admission';
import {VPNChainingScreen} from '../review/VPNChainingScreen';

let mockFocused=true;let mockRouteKey='vpn-visit';
const mockGoBack=jest.fn();const mockSetOptions=jest.fn();
let mockState={index:1,routes:[{name:'Settings',key:'settings'},{name:'VPNChaining',key:'vpn-visit'}]};
const mockNavigation={goBack:mockGoBack,setOptions:mockSetOptions,getState:()=>mockState,navigate:jest.fn()};
jest.mock('@react-navigation/native',()=>({useIsFocused:()=>mockFocused,useRoute:()=>({key:mockRouteKey}),useNavigation:()=>mockNavigation,usePreventRemove:jest.fn()}));
jest.mock('react-native-safe-area-context',()=>require('react-native-safe-area-context/jest/mock').default);
jest.mock('../specs/NativeLavaReview',()=>({__esModule:true,default:{getGuardAccents:()=>JSON.stringify({original:{light:'#BF4000',dark:'#FF8855'}})}}));
jest.mock('../specs/LavaNativePageNativeComponent',()=>({__esModule:true,default:require('react-native').View}));
jest.mock('../specs/LavaDecorationNativeComponent',()=>({__esModule:true,default:require('react-native').View}));
jest.mock('../specs/LavaSliderNativeComponent',()=>({__esModule:true,default:require('react-native').View}));

const deferred=()=>{let resolve!:()=>void;let reject!:(error:Error)=>void;const promise=new Promise<void>((yes,no)=>{resolve=yes;reject=no;});return {promise,resolve,reject};};
let previousPhase:typeof AppState.currentState;let lifecycle:Set<(value:AppStateStatus)=>void>;
beforeEach(()=>{
  previousPhase=AppState.currentState;AppState.currentState='active';mockFocused=true;mockRouteKey='vpn-visit';
  mockState={index:1,routes:[{name:'Settings',key:'settings'},{name:'VPNChaining',key:'vpn-visit'}]};
  mockGoBack.mockClear();mockSetOptions.mockClear();lifecycle=new Set();
  jest.spyOn(AppState,'addEventListener').mockImplementation((_event,listener)=>{lifecycle.add(listener);return {remove:()=>lifecycle.delete(listener)};});
});
afterEach(()=>{AppState.currentState=previousPhase;jest.restoreAllMocks();});
function emit(value:AppStateStatus){AppState.currentState=value;act(()=>{for(const listener of lifecycle)listener(value);});}
// The page never paints its own cover; the route's shared boundary owns that.
function expectNoPageCover(){
  expect(screen.queryByTestId('vpn-page-privacy-cover',{includeHiddenElements:true})).toBeNull();
  expect(screen.queryByText('Lava Security',{includeHiddenElements:true})).toBeNull();
}
// Without a current grant native withholds rows; React must not repaint a draft.
function expectRowsWithheld(){
  expect(screen.queryByTestId('vpn.setup-toggle',{includeHiddenElements:true})).toBeNull();
  expect(screen.queryByTestId('vpn.configuration-panel',{includeHiddenElements:true})).toBeNull();
}
function setup(authorized=true){
  const listeners=new Set<()=>void>();let authoritative=true;let hydrated=true;let fieldsAvailable=true;let privacyCoverRequired:boolean|undefined=false;
  const command=jest.fn(async(_command:AppCommand):Promise<unknown>=>null);
  const app={command,getSnapshot:()=>({snapshot:authoritative?live:null,privacyCoverRequired}),getPresentationHydration:()=>({epoch:1,required:!hydrated}),
    subscribe:(listener:()=>void)=>{listeners.add(listener);return()=>{listeners.delete(listener);};},
    registerPresentationRead:jest.fn(()=>({epoch:1,id:1})),settlePresentationRead:jest.fn()};
  let live={foregroundFlow:undefined as ForegroundFlow|null|undefined,vpn:{authorized,setup:true,enabled:false,canEdit:true,canChangeFallback:true,needsPlus:false,rows:[] as {name:string;mode:string;isEnabled?:boolean}[],generation:'saved'},plus:{enabled:true},security:{ownerRevision:'native-owner',readRevision:1}};
  const wrapper=({children}:PropsWithChildren)=><ReviewContext.Provider value={{app,live:fieldsAvailable?live:undefined,session:initialSession()} as unknown as ReviewState}>{children}</ReviewContext.Provider>;
  const notify=()=>act(()=>{for(const listener of listeners)listener();});
  return {app,command,wrapper,setAuthorized:(value:boolean,revision=live.security.readRevision)=>{live={...live,vpn:{...live.vpn,authorized:value},security:{...live.security,readRevision:revision}};},
    setNativeChild:(id?:string)=>{live={...live,foregroundFlow:id?{id,kind:'vpnConfiguration',name:'',emoji:'',dismissAttempt:0,canCreate:false,templates:[],vpnEditor:null}:null};},
    setPrivacyPolicy:(value:boolean|undefined)=>{privacyCoverRequired=value;},
    replaceOwner:()=>{live={...live,security:{...live.security,ownerRevision:'replacement-owner'}};},
    setFieldsAvailable:(value:boolean)=>{fieldsAvailable=value;},
    setLive:(value:Partial<typeof live>)=>{live={...live,...value} as typeof live;},
    setAuthority:(value:boolean)=>{authoritative=value;notify();},setHydrated:(value:boolean)=>{hydrated=value;notify();}};
}

test('a revoked return withholds rows and retains its actual native draft until native reauthorization',async()=>{
  const fixture=setup();const draft={id:'native-draft',revision:1,changed:false,containsFullTunnel:false,rows:[]};
  fixture.command.mockImplementation(async action=>action.type==='vpn.begin'?draft:null);
  const view=render(<VPNChainingScreen/>,{wrapper:fixture.wrapper});await act(async()=>{});
  expect(fixture.command).not.toHaveBeenCalled();
  act(()=>mockSetOptions.mock.calls.at(-1)![0].unstable_headerRightItems()[0].onPress());await act(async()=>{});
  expect(screen.getByTestId('vpn.configuration-panel')).toBeOnTheScreen();
  expect(fixture.command.mock.calls).toEqual([[{type:'vpn.begin',id:expect.any(String),generation:'saved'}]]);
  mockFocused=false;view.rerender(<VPNChainingScreen/>);await act(async()=>{});
  const staleSave=mockSetOptions.mock.calls.at(-1)![0].unstable_headerRightItems()[0];
  fixture.setAuthorized(false,2);mockFocused=true;
  const request=deferred();fixture.command.mockImplementation(async action=>action.type==='vpn.enter'?request.promise:null);
  view.rerender(<VPNChainingScreen/>);await act(async()=>{});
  expectRowsWithheld();expectNoPageCover();
  act(()=>staleSave.onPress());await act(async()=>{});
  expect(fixture.command.mock.calls.map(([action])=>action.type)).toEqual(['vpn.begin','vpn.enter']);
  await act(async()=>request.resolve());
  expectRowsWithheld();
  fixture.setAuthorized(true);view.rerender(<VPNChainingScreen/>);await act(async()=>{});
  expect(screen.getByTestId('vpn.configuration-panel')).toBeOnTheScreen();
  fireEvent.press(screen.getByRole('button',{name:'Add configuration'}));await act(async()=>{});
  expect(fixture.command.mock.calls.at(-1)).toEqual([{type:'vpn.edit',id:draft.id,index:0}]);
  expect(fixture.command.mock.calls.some(([action])=>action.type==='vpn.cancel')).toBe(false);
  view.unmount();await act(async()=>{});
  expect(fixture.command.mock.calls.at(-1)).toEqual([{type:'vpn.cancel',id:draft.id}]);
});

test('the native WireGuard modal owns resume authorization without retiring its painted parent draft',async()=>{
  const fixture=setup();const draft={id:'native-draft',revision:1,changed:false,containsFullTunnel:false,rows:[]};
  fixture.command.mockImplementation(async action=>action.type==='vpn.begin'?draft:null);
  const view=render(<VPNChainingScreen/>,{wrapper:fixture.wrapper});await act(async()=>{});
  act(()=>mockSetOptions.mock.calls.at(-1)![0].unstable_headerRightItems()[0].onPress());await act(async()=>{});
  fixture.setNativeChild('wireguard-child');view.rerender(<VPNChainingScreen/>);await act(async()=>{});
  // The modal owns input and accessibility above the parent, not its paint.
  expect(screen.getByTestId('vpn.setup-toggle')).toBeOnTheScreen();
  expectNoPageCover();
  const toolbar=mockSetOptions.mock.calls.at(-1)![0];
  const cancel=toolbar.unstable_headerLeftItems()[0];const save=toolbar.unstable_headerRightItems()[0];
  expect(cancel.disabled).toBe(false);expect(save.disabled).toBe(false);
  act(()=>{cancel.onPress();save.onPress();});await act(async()=>{});
  expect(fixture.command.mock.calls.map(([action])=>action.type)).toEqual(['vpn.begin']);
  emit('background');fixture.setFieldsAvailable(false);fixture.setAuthority(false);view.rerender(<VPNChainingScreen/>);
  fixture.setAuthorized(false,2);fixture.setFieldsAvailable(true);emit('active');fixture.setAuthority(true);view.rerender(<VPNChainingScreen/>);await act(async()=>{});
  expect(fixture.command.mock.calls.map(([action])=>action.type)).toEqual(['vpn.begin']);
  fixture.command.mockRejectedValueOnce(new Error('Authentication cancelled.'));
  await act(async()=>{await fixture.command({type:'vpnEditor.enter',id:'wireguard-child'}).catch(()=>{});});
  view.rerender(<VPNChainingScreen/>);await act(async()=>{});
  expect(mockGoBack).not.toHaveBeenCalled();
  expect(fixture.command.mock.calls.some(([action])=>action.type==='vpn.cancel'||action.type==='vpn.enter')).toBe(false);
  expectRowsWithheld();expectNoPageCover();

  const request=deferred();fixture.command.mockImplementation(async action=>action.type==='vpn.enter'?request.promise:null);
  fixture.setNativeChild();view.rerender(<VPNChainingScreen/>);await act(async()=>{});
  expect(fixture.command.mock.calls.at(-1)).toEqual([{type:'vpn.enter'}]);
  await act(async()=>request.resolve());expectRowsWithheld();
  fixture.setAuthorized(true);view.rerender(<VPNChainingScreen/>);await act(async()=>{});
  fireEvent.press(screen.getByRole('button',{name:'Add configuration'}));await act(async()=>{});
  expect(fixture.command.mock.calls.at(-1)).toEqual([{type:'vpn.edit',id:draft.id,index:0}]);
  expect(fixture.command.mock.calls.some(([action])=>action.type==='vpn.cancel')).toBe(false);
});

test('an authorized parent below the native modal has no input admission through a read pause',async()=>{
  const fixture=setup();fixture.setNativeChild('wireguard-child');
  const {result,rerender}=renderHook(()=>useVPNPageAdmission(),{wrapper:fixture.wrapper});await act(async()=>{});
  expect(result.current.canInteract).toBe(false);
  expect(result.current.isAdmitted()).toBe(false);expect(fixture.command).not.toHaveBeenCalled();
  emit('background');fixture.setAuthority(false);rerender(undefined);await act(async()=>{});
  expect(result.current.canInteract).toBe(false);
  emit('active');fixture.setAuthority(true);rerender(undefined);await act(async()=>{});
  expect(result.current.canInteract).toBe(false);
  expect(result.current.isAdmitted()).toBe(false);expect(fixture.command).not.toHaveBeenCalled();
});

test.each([true,false,undefined] as const)('with %s policy a current grant paints the parent; revocation withholds rows without a page-owned cover',async policy=>{
  const fixture=setup();fixture.setPrivacyPolicy(policy);fixture.setNativeChild('wireguard-child');
  const view=render(<VPNChainingScreen/>,{wrapper:fixture.wrapper});await act(async()=>{});
  expect(screen.getByTestId('vpn.setup-toggle')).toBeOnTheScreen();expectNoPageCover();
  fixture.setAuthorized(false);view.rerender(<VPNChainingScreen/>);await act(async()=>{});
  expectRowsWithheld();expectNoPageCover();
  fixture.setAuthorized(true);view.rerender(<VPNChainingScreen/>);await act(async()=>{});
  expect(screen.getByTestId('vpn.setup-toggle')).toBeOnTheScreen();expectNoPageCover();
  fixture.setAuthority(false);view.rerender(<VPNChainingScreen/>);await act(async()=>{});
  expectNoPageCover();
  expect(fixture.command).not.toHaveBeenCalled();expect(mockGoBack).not.toHaveBeenCalled();
});

test('an unauthorized parent paints no rows even with explicit opt-out while the native child owns accessibility',async()=>{
  const fixture=setup(false);fixture.setNativeChild('wireguard-child');
  render(<VPNChainingScreen/>,{wrapper:fixture.wrapper});await act(async()=>{});
  expectRowsWithheld();expectNoPageCover();expect(fixture.command).not.toHaveBeenCalled();
});

test('a failed admission offers Unlock inside the shared Screen and retries without granting',async()=>{
  const fixture=setup(false);fixture.command.mockRejectedValueOnce(new Error('Read access changed.'));
  const view=render(<VPNChainingScreen/>,{wrapper:fixture.wrapper});await act(async()=>{});
  expect(view.toJSON()).toMatchObject({props:{testID:'screen.scroll'}});
  expectRowsWithheld();expectNoPageCover();
  fireEvent.press(screen.getByRole('button',{name:'Unlock Lava'}));await act(async()=>{});
  expect(fixture.command.mock.calls).toEqual([[{type:'vpn.enter'}],[{type:'vpn.enter'}]]);
  expectRowsWithheld();
});

test('a parent cancellation published after native child presentation cannot pop it, including before the React commit',async()=>{
  const fixture=setup(false);const old=deferred();const fresh=deferred();
  fixture.command.mockReturnValueOnce(old.promise).mockReturnValueOnce(fresh.promise);
  const {result,rerender}=renderHook(()=>useVPNPageAdmission(),{wrapper:fixture.wrapper});await act(async()=>{});
  fixture.setNativeChild('wireguard-child');
  // The command callback sees current native identity before React commits the
  // subscription render. Promise cancellation cannot remove the modal's parent.
  await act(async()=>old.reject(new Error('Authentication cancelled.')));
  expect(mockGoBack).not.toHaveBeenCalled();
  rerender(undefined);await act(async()=>{});expect(result.current.canInteract).toBe(false);
  expect(fixture.command).toHaveBeenCalledTimes(1);
  fixture.setNativeChild();rerender(undefined);await act(async()=>{});
  expect(fixture.command).toHaveBeenCalledTimes(2);expect(mockGoBack).not.toHaveBeenCalled();
  await act(async()=>fresh.reject(new Error('Authentication cancelled.')));
  expect(mockGoBack).toHaveBeenCalledTimes(1);
});

test('only a fresh native child removal resumes the parent; missing fields and replacement security owners grant nothing',async()=>{
  const fixture=setup();fixture.setNativeChild('wireguard-child');
  const {result,rerender}=renderHook(()=>useVPNPageAdmission(),{wrapper:fixture.wrapper});await act(async()=>{});
  expect(result.current.canInteract).toBe(false);expect(fixture.command).not.toHaveBeenCalled();
  fixture.setFieldsAvailable(false);rerender(undefined);await act(async()=>{});
  expect(result.current.canInteract).toBe(false);expect(fixture.command).not.toHaveBeenCalled();
  fixture.replaceOwner();fixture.setAuthorized(false,2);fixture.setFieldsAvailable(true);rerender(undefined);await act(async()=>{});
  expect(result.current.canInteract).toBe(false);expect(fixture.command).not.toHaveBeenCalled();
  fixture.setNativeChild();rerender(undefined);await act(async()=>{});
  expect(fixture.command.mock.calls).toEqual([[{type:'vpn.enter'}]]);expect(result.current.canInteract).toBe(false);
});

test('cancelled edge Back retains the native grant and does not issue another authentication',async()=>{
  const fixture=setup();const {result,rerender}=renderHook(()=>useVPNPageAdmission(),{wrapper:fixture.wrapper});
  expect(result.current.canInteract).toBe(true);
  // A cancelled interactive transition does not commit another navigation state.
  rerender(undefined);await act(async()=>{});
  expect(result.current.canInteract).toBe(true);expect(fixture.command).not.toHaveBeenCalled();
});

test('retired callbacks cannot inherit a replacement admission or reopen an unmounted visit',async()=>{
  const fixture=setup();const {result,rerender,unmount}=renderHook(()=>useVPNPageAdmission(),{wrapper:fixture.wrapper});
  const previous=result.current.isAdmitted;expect(previous()).toBe(true);
  fixture.replaceOwner();rerender(undefined);await act(async()=>{});
  expect(previous()).toBe(false);expect(result.current.isAdmitted()).toBe(true);
  const current=result.current.isAdmitted;unmount();expect(current()).toBe(false);
});

test('current authentication cancellation releases hydration before leaving only the protected VPN visit',async()=>{
  const fixture=setup(false);fixture.setHydrated(false);const request=deferred();fixture.command.mockReturnValue(request.promise);
  renderHook(()=>useVPNPageAdmission(),{wrapper:fixture.wrapper});await act(async()=>{});
  expect(fixture.command.mock.calls).toEqual([[{type:'vpn.enter'}]]);expect(mockGoBack).not.toHaveBeenCalled();
  await act(async()=>request.reject(new Error('Authentication cancelled.')));
  expect(fixture.app.settlePresentationRead).toHaveBeenCalled();expect(mockGoBack).not.toHaveBeenCalled();
  fixture.setHydrated(true);await act(async()=>{});
  expect(mockGoBack).toHaveBeenCalledTimes(1);
});

test('a biometric inactive/active interval retains one pending native admission and one cancellation leaves the page',async()=>{
  const fixture=setup(false);const request=deferred();fixture.command.mockReturnValue(request.promise);
  const {result,rerender}=renderHook(()=>useVPNPageAdmission(),{wrapper:fixture.wrapper});await act(async()=>{});
  expect(fixture.command.mock.calls).toEqual([[{type:'vpn.enter'}]]);
  emit('inactive');fixture.setAuthority(false);fixture.setFieldsAvailable(false);rerender(undefined);await act(async()=>{});
  expect(result.current.canInteract).toBe(false);
  emit('active');fixture.setFieldsAvailable(true);fixture.setAuthority(true);rerender(undefined);await act(async()=>{});
  expect(result.current.canInteract).toBe(false);
  expect(fixture.command.mock.calls).toEqual([[{type:'vpn.enter'}]]);
  await act(async()=>request.reject(new Error('Authentication cancelled.')));
  expect(mockGoBack).toHaveBeenCalledTimes(1);
  expect(fixture.command.mock.calls).toEqual([[{type:'vpn.enter'}]]);
});

test('a current biometric cancellation delivered while inactive waits for foreground before popping',async()=>{
  const fixture=setup(false);const request=deferred();fixture.command.mockReturnValue(request.promise);
  const {result,rerender}=renderHook(()=>useVPNPageAdmission(),{wrapper:fixture.wrapper});await act(async()=>{});
  emit('inactive');fixture.setAuthority(false);fixture.setFieldsAvailable(false);rerender(undefined);await act(async()=>{});
  await act(async()=>request.reject(new Error('Authentication cancelled.')));
  expect(mockGoBack).not.toHaveBeenCalled();expect(result.current.canInteract).toBe(false);
  emit('active');fixture.setFieldsAvailable(true);fixture.setAuthority(true);rerender(undefined);await act(async()=>{});
  expect(mockGoBack).toHaveBeenCalledTimes(1);
  expect(fixture.command.mock.calls).toEqual([[{type:'vpn.enter'}]]);
});

test.each(['cancel','success'] as const)('true background retirement waits for the old %s before requesting fresh evidence without borrowing its result',async outcome=>{
  const fixture=setup(false);const old=deferred();const fresh=deferred();
  fixture.command.mockReturnValueOnce(old.promise).mockReturnValueOnce(fresh.promise);
  const {result,rerender}=renderHook(()=>useVPNPageAdmission(),{wrapper:fixture.wrapper});await act(async()=>{});
  emit('background');fixture.setAuthority(false);fixture.setFieldsAvailable(false);rerender(undefined);
  fixture.setAuthorized(false,2);fixture.setFieldsAvailable(true);emit('active');fixture.setAuthority(true);rerender(undefined);await act(async()=>{});
  expect(fixture.command.mock.calls).toEqual([[{type:'vpn.enter'}]]);
  await act(async()=>outcome==='cancel'?old.reject(new Error('Authentication cancelled.')):old.resolve());
  expect(mockGoBack).not.toHaveBeenCalled();expect(result.current.canInteract).toBe(false);
  expect(fixture.command.mock.calls).toEqual([[{type:'vpn.enter'}],[{type:'vpn.enter'}]]);
  await act(async()=>fresh.reject(new Error('Authentication cancelled.')));
  expect(mockGoBack).toHaveBeenCalledTimes(1);
});

test.each(['blur','background','inactive','replace-route','replace-owner','revision','unmount'] as const)('a stale authentication cancellation after %s cannot pop or reopen the page',async event=>{
  const fixture=setup(false);const request=deferred();fixture.command.mockReturnValueOnce(request.promise).mockImplementation(()=>new Promise<unknown>(()=>{}));
  const {result,rerender,unmount}=renderHook(()=>useVPNPageAdmission(),{wrapper:fixture.wrapper});await act(async()=>{});
  if(event==='blur'){mockFocused=false;rerender(undefined);}
  if(event==='background'||event==='inactive')emit(event);
  if(event==='replace-route')mockState={index:1,routes:[{name:'Settings',key:'settings'},{name:'VPNChaining',key:'other-visit'}]};
  if(event==='replace-owner'){fixture.replaceOwner();rerender(undefined);}
  if(event==='revision'){fixture.setAuthorized(false,2);rerender(undefined);}
  if(event==='unmount')unmount();
  await act(async()=>request.reject(new Error('Authentication cancelled.')));
  expect(mockGoBack).not.toHaveBeenCalled();
  if(event!=='unmount')expect(result.current.canInteract).toBe(false);
});

test('resume entry waits for current native fields, may run beneath hydration, and never admits mutations from its promise',async()=>{
  const fixture=setup(false);fixture.setAuthority(false);fixture.setHydrated(false);
  const request=deferred();fixture.command.mockReturnValue(request.promise);
  const {result,rerender}=renderHook(()=>useVPNPageAdmission(),{wrapper:fixture.wrapper});await act(async()=>{});
  expect(fixture.command).not.toHaveBeenCalled();expect(result.current.canInteract).toBe(false);
  fixture.setAuthority(true);await act(async()=>{});
  expect(fixture.command.mock.calls).toEqual([[{type:'vpn.enter'}]]);
  await act(async()=>request.resolve());expect(result.current.canInteract).toBe(false);
  fixture.setAuthorized(true);rerender(undefined);await act(async()=>{});
  expect(result.current.canInteract).toBe(false);
  fixture.setHydrated(true);await act(async()=>{});expect(result.current.canInteract).toBe(true);
});

test('an admission error remains concealed and can retry without granting or changing VPN setup',async()=>{
  const fixture=setup(false);fixture.command.mockRejectedValueOnce(new Error('Read access changed.'));
  const {result}=renderHook(()=>useVPNPageAdmission(),{wrapper:fixture.wrapper});await act(async()=>{});
  expect(result.current.canRetry).toBe(true);expect(result.current.canInteract).toBe(false);expect(mockGoBack).not.toHaveBeenCalled();
  act(()=>result.current.retry());await act(async()=>{});
  expect(fixture.command.mock.calls).toEqual([[{type:'vpn.enter'}],[{type:'vpn.enter'}]]);
  expect(result.current.canInteract).toBe(false);
});

// The native-stack large title tracks the ScrollView it finds as the route's
// direct child (primitives.tsx `Screen`). Any wrapper view breaks the header.
test('the VPN page renders the shared Screen scroll view as its route root, like DNS',async()=>{
  const fixture=setup();
  const view=render(<VPNChainingScreen/>,{wrapper:fixture.wrapper});await act(async()=>{});
  expect(view.toJSON()).toMatchObject({props:{testID:'screen.scroll'}});
});

// Concealment belongs to the route's shared LiveRenderBoundary and the native
// security policy. Background alone never paints a page-owned cover.
test('backgrounding an all-off VPN page keeps its painted body without a page-owned cover',async()=>{
  const fixture=setup();
  fixture.setLive({vpn:{authorized:true,setup:true,enabled:true,canEdit:true,canChangeFallback:true,needsPlus:false,rows:[{name:'Home VPN',mode:'Split tunnel',isEnabled:true}],generation:'saved'}});
  const view=render(<VPNChainingScreen/>,{wrapper:fixture.wrapper});await act(async()=>{});
  emit('background');fixture.setAuthority(false);view.rerender(<VPNChainingScreen/>);await act(async()=>{});
  expect(screen.queryByTestId('vpn-page-privacy-cover',{includeHiddenElements:true})).toBeNull();
  expect(screen.queryByText('Lava Security',{includeHiddenElements:true})).toBeNull();
  expect(screen.getByText('Home VPN',{includeHiddenElements:true})).toBeTruthy();
  expect(mockSetOptions.mock.calls.at(-1)![0].unstable_headerLeftItems()[0].disabled).toBe(false);
  emit('active');fixture.setAuthority(true);view.rerender(<VPNChainingScreen/>);await act(async()=>{});
  expect(screen.getByText('Home VPN')).toBeOnTheScreen();
  expect(fixture.command).not.toHaveBeenCalled();
});

// The route composition from LavaUIReview.tsx `privateRoute`: the shared
// boundary alone decides concealment, from the native security choice.
test.each([[false,false],[true,true]] as const)('inside its route boundary, privacy policy %s shows the shared cover on background: %s',async(policy,covered)=>{
  const fixture=setup();fixture.setPrivacyPolicy(policy);
  fixture.setLive({vpn:{authorized:true,setup:true,enabled:true,canEdit:true,canChangeFallback:true,needsPlus:false,rows:[{name:'Home VPN',mode:'Split tunnel',isEnabled:true}],generation:'saved'}});
  const route=()=><LiveRenderBoundary component={VPNChainingScreen} retainBody directScrollRoot retireOnPolicyChange/>;
  const view=render(route(),{wrapper:fixture.wrapper});await act(async()=>{});
  expect(screen.queryByTestId('lava-route-privacy-cover',{includeHiddenElements:true})).toBeNull();
  expect(screen.getByText('Home VPN')).toBeOnTheScreen();
  // An all-off app keeps its accepted display frame; protected policy has none.
  emit('background');fixture.setAuthority(false);if(covered)fixture.setFieldsAvailable(false);view.rerender(route());await act(async()=>{});
  expect(screen.queryByTestId('vpn-page-privacy-cover',{includeHiddenElements:true})).toBeNull();
  if(covered)expect(screen.getByTestId('lava-route-privacy-cover')).toBeOnTheScreen();
  else{
    expectNoPageCover();
    expect(screen.queryByTestId('lava-route-privacy-cover',{includeHiddenElements:true})).toBeNull();
    expect(screen.getByText('Home VPN',{includeHiddenElements:true})).toBeTruthy();
  }
});
