import {AppState,type AppStateStatus} from 'react-native';
import {act,fireEvent,render,renderHook,screen} from '@testing-library/react-native';
import type {PropsWithChildren} from 'react';
import type {AppCommand,ForegroundFlow} from '../app/contract';
import {ReviewContext,type ReviewState} from '../review/ReviewContext';
import {initialSession} from '../review/session';
import {useVPNPageAdmission} from '../review/vpn-page-admission';
import {VPNChainingScreen} from '../review/NativePageScreen';

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
function parentCoverFence(){
  let ancestor=screen.getByTestId('vpn-page-privacy-cover',{includeHiddenElements:true}).parent;
  while(ancestor&&ancestor.props.importantForAccessibility!=='no-hide-descendants')ancestor=ancestor.parent;
  return ancestor;
}
function setup(authorized=true){
  const listeners=new Set<()=>void>();let authoritative=true;let hydrated=true;let fieldsAvailable=true;let privacyCoverRequired:boolean|undefined=false;
  const command=jest.fn(async(_command:AppCommand):Promise<unknown>=>null);
  const app={command,getSnapshot:()=>({snapshot:authoritative?live:null,privacyCoverRequired}),getPresentationHydration:()=>({epoch:1,required:!hydrated}),
    subscribe:(listener:()=>void)=>{listeners.add(listener);return()=>{listeners.delete(listener);};},
    registerPresentationRead:jest.fn(()=>({epoch:1,id:1})),settlePresentationRead:jest.fn()};
  let live={foregroundFlow:undefined as ForegroundFlow|null|undefined,vpn:{authorized,setup:true,enabled:false,canEdit:true,canChangeFallback:true,needsPlus:false,rows:[],generation:'saved'},plus:{enabled:true},security:{ownerRevision:'native-owner',readRevision:1}};
  const wrapper=({children}:PropsWithChildren)=><ReviewContext.Provider value={{app,live:fieldsAvailable?live:undefined,session:initialSession()} as unknown as ReviewState}>{children}</ReviewContext.Provider>;
  const notify=()=>act(()=>{for(const listener of listeners)listener();});
  return {app,command,wrapper,setAuthorized:(value:boolean,revision=live.security.readRevision)=>{live={...live,vpn:{...live.vpn,authorized:value},security:{...live.security,readRevision:revision}};},
    setNativeChild:(id?:string)=>{live={...live,foregroundFlow:id?{id,kind:'vpnConfiguration',name:'',emoji:'',dismissAttempt:0,canCreate:false,templates:[],vpnEditor:null}:null};},
    setPrivacyPolicy:(value:boolean|undefined)=>{privacyCoverRequired=value;},
    replaceOwner:()=>{live={...live,security:{...live.security,ownerRevision:'replacement-owner'}};},
    setFieldsAvailable:(value:boolean)=>{fieldsAvailable=value;},
    setAuthority:(value:boolean)=>{authoritative=value;notify();},setHydrated:(value:boolean)=>{hydrated=value;notify();}};
}

test('a committed child return conceals controls and retains its actual native draft until native reauthorization',async()=>{
  const fixture=setup();const draft={id:'native-draft',revision:1,changed:false,containsFullTunnel:false,rows:[]};
  fixture.command.mockImplementation(async action=>action.type==='vpn.begin'?draft:null);
  const view=render(<VPNChainingScreen/>,{wrapper:fixture.wrapper});await act(async()=>{});
  expect(fixture.command).not.toHaveBeenCalled();
  act(()=>mockSetOptions.mock.calls.at(-1)![0].unstable_headerRightItems()[0].onPress());await act(async()=>{});
  const panel=screen.getByTestId('vpn.configuration-panel');
  expect(fixture.command.mock.calls).toEqual([[{type:'vpn.begin',id:expect.any(String),generation:'saved'}]]);
  mockFocused=false;view.rerender(<VPNChainingScreen/>);await act(async()=>{});
  const staleSave=mockSetOptions.mock.calls.at(-1)![0].unstable_headerRightItems()[0];
  fixture.setAuthorized(false,2);mockFocused=true;
  const request=deferred();fixture.command.mockImplementation(async action=>action.type==='vpn.enter'?request.promise:null);
  view.rerender(<VPNChainingScreen/>);await act(async()=>{});
  expect(screen.queryByTestId('vpn.setup-toggle')).toBeNull();
  expect(screen.getByTestId('vpn-page-content',{includeHiddenElements:true}).props).toMatchObject({pointerEvents:'none',accessibilityElementsHidden:true,importantForAccessibility:'no-hide-descendants'});
  act(()=>staleSave.onPress());await act(async()=>{});
  expect(fixture.command.mock.calls.map(([action])=>action.type)).toEqual(['vpn.begin','vpn.enter']);
  await act(async()=>request.resolve());
  expect(screen.queryByTestId('vpn.setup-toggle')).toBeNull();
  fixture.setAuthorized(true);view.rerender(<VPNChainingScreen/>);await act(async()=>{});
  expect(screen.getByTestId('vpn.configuration-panel')).toBe(panel);
  fireEvent.press(screen.getByRole('button',{name:'Add configuration'}));await act(async()=>{});
  expect(fixture.command.mock.calls.at(-1)).toEqual([{type:'vpn.edit',id:draft.id,index:0}]);
  expect(fixture.command.mock.calls.some(([action])=>action.type==='vpn.cancel')).toBe(false);
  view.unmount();await act(async()=>{});
  expect(fixture.command.mock.calls.at(-1)).toEqual([{type:'vpn.cancel',id:draft.id}]);
});

test('the native WireGuard modal owns resume authorization without retiring its obscured parent draft',async()=>{
  const fixture=setup();const draft={id:'native-draft',revision:1,changed:false,containsFullTunnel:false,rows:[]};
  fixture.command.mockImplementation(async action=>action.type==='vpn.begin'?draft:null);
  const view=render(<VPNChainingScreen/>,{wrapper:fixture.wrapper});await act(async()=>{});
  act(()=>mockSetOptions.mock.calls.at(-1)![0].unstable_headerRightItems()[0].onPress());await act(async()=>{});
  fixture.setNativeChild('wireguard-child');view.rerender(<VPNChainingScreen/>);await act(async()=>{});
  expect(screen.queryByTestId('vpn.setup-toggle')).toBeNull();
  expect(screen.queryByTestId('vpn-page-privacy-cover',{includeHiddenElements:true})).toBeNull();
  expect(screen.queryByText('Lava Security',{includeHiddenElements:true})).toBeNull();
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
  expect(screen.getByTestId('vpn-page-content',{includeHiddenElements:true}).props).toMatchObject({pointerEvents:'none',accessibilityElementsHidden:true,importantForAccessibility:'no-hide-descendants'});

  const request=deferred();fixture.command.mockImplementation(async action=>action.type==='vpn.enter'?request.promise:null);
  fixture.setNativeChild();view.rerender(<VPNChainingScreen/>);await act(async()=>{});
  expect(fixture.command.mock.calls.at(-1)).toEqual([{type:'vpn.enter'}]);
  await act(async()=>request.resolve());expect(screen.queryByTestId('vpn.setup-toggle')).toBeNull();
  fixture.setAuthorized(true);view.rerender(<VPNChainingScreen/>);await act(async()=>{});
  fireEvent.press(screen.getByRole('button',{name:'Add configuration'}));await act(async()=>{});
  expect(fixture.command.mock.calls.at(-1)).toEqual([{type:'vpn.edit',id:draft.id,index:0}]);
  expect(fixture.command.mock.calls.some(([action])=>action.type==='vpn.cancel')).toBe(false);
});

test('an authorized all-off parent keeps its accepted paint below the native modal with no input or privacy accessibility',async()=>{
  const fixture=setup();fixture.setNativeChild('wireguard-child');
  const {result,rerender}=renderHook(()=>useVPNPageAdmission(),{wrapper:fixture.wrapper});await act(async()=>{});
  expect(result.current).toMatchObject({canInteract:false,coverRequired:false,coverAccessibilityHidden:true});
  expect(result.current.isAdmitted()).toBe(false);expect(fixture.command).not.toHaveBeenCalled();
  emit('background');fixture.setAuthority(false);rerender(undefined);await act(async()=>{});
  expect(result.current).toMatchObject({canInteract:false,coverRequired:false,coverAccessibilityHidden:true});
  emit('active');fixture.setAuthority(true);rerender(undefined);await act(async()=>{});
  expect(result.current).toMatchObject({canInteract:false,coverRequired:false,coverAccessibilityHidden:true});
  expect(result.current.isAdmitted()).toBe(false);expect(fixture.command).not.toHaveBeenCalled();
});

test.each([true,undefined] as const)('a current grant paints the parent with %s policy; revocation conceals it while the native child owns accessibility',async policy=>{
  const fixture=setup();fixture.setPrivacyPolicy(policy);fixture.setNativeChild('wireguard-child');
  const view=render(<VPNChainingScreen/>,{wrapper:fixture.wrapper});await act(async()=>{});
  expect(screen.queryByTestId('vpn-page-privacy-cover',{includeHiddenElements:true})).toBeNull();
  expect(screen.getByTestId('vpn-page-content',{includeHiddenElements:true}).props).toMatchObject({pointerEvents:'none',accessibilityElementsHidden:true,importantForAccessibility:'no-hide-descendants'});
  fixture.setAuthorized(false);view.rerender(<VPNChainingScreen/>);await act(async()=>{});
  expect(screen.queryByTestId('vpn-page-privacy-cover')).toBeNull();
  expect(parentCoverFence()?.props).toMatchObject({accessibilityElementsHidden:true,importantForAccessibility:'no-hide-descendants'});
  expect(screen.queryByText('Lava Security')).toBeNull();
  fixture.setAuthorized(true);view.rerender(<VPNChainingScreen/>);await act(async()=>{});
  expect(screen.queryByTestId('vpn-page-privacy-cover',{includeHiddenElements:true})).toBeNull();
  fixture.setAuthority(false);view.rerender(<VPNChainingScreen/>);await act(async()=>{});
  expect(screen.queryByTestId('vpn-page-privacy-cover')).toBeNull();
  expect(parentCoverFence()?.props).toMatchObject({accessibilityElementsHidden:true,importantForAccessibility:'no-hide-descendants'});
  expect(screen.queryByText('Lava Security')).toBeNull();
  expect(fixture.command).not.toHaveBeenCalled();expect(mockGoBack).not.toHaveBeenCalled();
});

test('an unauthorized parent retains opaque concealment even with explicit opt-out while the native child owns accessibility',async()=>{
  const fixture=setup(false);fixture.setNativeChild('wireguard-child');
  render(<VPNChainingScreen/>,{wrapper:fixture.wrapper});await act(async()=>{});
  expect(screen.queryByTestId('vpn-page-privacy-cover')).toBeNull();
  expect(parentCoverFence()?.props).toMatchObject({accessibilityElementsHidden:true,importantForAccessibility:'no-hide-descendants'});
  expect(screen.queryByText('Lava Security')).toBeNull();expect(fixture.command).not.toHaveBeenCalled();
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
