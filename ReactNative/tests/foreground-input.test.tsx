import {createRef,useSyncExternalStore,type ComponentRef} from 'react';
import {AppState,Alert as NativeAlert,Platform,ScrollView,TextInput,View,type AppStateStatus} from 'react-native';
import {act,fireEvent,render,screen} from '@testing-library/react-native';
import {ReviewContext,type ReviewState} from '../review/ReviewContext';
import {VPNEditorFlow} from '../review/VPNEditorFlow';
import {FeedbackFlow} from '../review/FeedbackFlow';
import {ForegroundFlowScreen} from '../review/ForegroundFlowScreen';
import {Search} from '../review/scaffold';
import {CharacterCounter,FormField,FormActions,FlowSheet} from '../review/form-scaffold';
import {PresentationContext} from '../app/presentation';
import {localized} from '../app/presentation';
import type {AppCommand,AppSnapshot,FeedbackState,ForegroundFlow,VPNEditorState} from '../app/contract';
import {AppStore} from '../app/store';
import {LavaActionButton} from '../src';
import type {Spec} from '../specs/NativeLavaApp';

const mockNavigation={setOptions:jest.fn(),isFocused:()=>true};
jest.mock('@react-navigation/native',()=>({useNavigation:()=>mockNavigation,useIsFocused:()=>true,useRoute:()=>({params:{id:'visit'}})}));
jest.mock('react-native-safe-area-context',()=>require('react-native-safe-area-context/jest/mock').default);
jest.mock('../specs/LavaDecorationNativeComponent',()=>({__esModule:true,default:require('react-native').View}));
jest.mock('../specs/LavaTextFieldNativeComponent',()=>({__esModule:true,default:require('react-native').View}));
jest.mock('../specs/NativeLavaReview',()=>({__esModule:true,default:{getGuardAccents:()=>JSON.stringify({})}}));
const originalState=AppState.currentState;
beforeAll(()=>Object.defineProperty(AppState,'currentState',{configurable:true,value:'active'}));
afterAll(()=>Object.defineProperty(AppState,'currentState',{configurable:true,value:originalState}));
beforeEach(()=>{mockNavigation.setOptions.mockClear();jest.spyOn(AppState,'addEventListener').mockReturnValue({remove:jest.fn()});});
afterEach(()=>jest.restoreAllMocks());
const deferred=<T,>()=>{let resolve!:(value:T)=>void;const promise=new Promise<T>(yes=>{resolve=yes;});return {promise,resolve};};
const vpn:VPNEditorState={name:'',nameResetRevision:0,dirty:false,hasContent:false,concealed:false,reading:false,canEdit:true,canSave:false,error:''};
const formValue=(title:string)=>screen.UNSAFE_getAllByType(FormField).find(field=>field.props.title===title)?.props.value;
const measureForegroundViewport=()=>fireEvent(screen.UNSAFE_getByType(ScrollView),'layout',{nativeEvent:{layout:{x:0,y:0,width:390,height:650}}});
const feedback:FeedbackState={topic:'suggestion',site:'',details:'A useful suggestion',email:'',diagnostics:false,step:2,furthest:2,revision:'7',review:'7',normalizedSite:'',normalizedDetails:'A useful suggestion',normalizedEmail:'',count:19,canContinue:true,dirty:true,busy:false,prepared:true,sent:false,error:'',receipt:'',copied:false,topics:[{id:'suggestion',title:'I have a suggestion'}]};
const controlledLifecycle=()=>{
  const listeners=new Set<(state:AppStateStatus)=>void>();
  jest.mocked(AppState.addEventListener).mockImplementation((_type,listener)=>{
    const callback=listener as (state:AppStateStatus)=>void;listeners.add(callback);return {remove:()=>{listeners.delete(callback);}};
  });
  return(state:AppStateStatus)=>{Object.defineProperty(AppState,'currentState',{configurable:true,value:state});for(const listener of [...listeners])listener(state);};
};
// The real AppStore consumes native-like authority/source metadata. Every
// mutation ACK advances sourceRevision, just as the actual bridge does.
const foregroundStoreFixture=(flow:ForegroundFlow|null,privacy=false,initialPresentation=false)=>{
  const state={flow:flow as ForegroundFlow|null,closing:[] as string[],authority:1,source:0,revision:0,dirty:false};
  const projection=()=>({schema:1,fullApp:true,revision:++state.revision,backgroundPrivacyCoverRequired:privacy,
    foregroundFlow:state.flow,foregroundClosing:state.closing,security:{readRevision:state.authority,sourceRevision:`${state.source}:0`,ownerRevision:'native-owner',displayClearRevision:'0:0:0'},
    session:{passcode:privacy,protectedActions:{},logs:{}}} as unknown as AppSnapshot);
  let publish:((value:string)=>void)|undefined;
  const reads:ReturnType<typeof deferred<string>>[]=[];
  const native={getSnapshot:jest.fn(()=>{const read=deferred<string>();reads.push(read);return read.promise;}),
    command:jest.fn(async(request:string)=>{
      const action=JSON.parse(request) as AppCommand;++state.source;let result:unknown=null;
      if(action.type==='foreground.identity')result={valid:true,dirty:false,message:''};
      if(action.type==='foreground.dirty')state.dirty=action.dirty;
      if(action.type==='foreground.dismiss'){
        if(state.dirty&&!action.discardConfirmed){
          result=false;
          if(state.flow?.kind==='vpnConfiguration'&&state.flow.vpnEditor)state.flow={...state.flow,vpnEditor:{...state.flow.vpnEditor,dirty:true}};
        }
        else {state.closing=state.flow?[state.flow.id]:[];state.flow=null;state.dirty=false;}
      }
      if(action.type==='vpnEditor.save'){state.closing=state.flow?[state.flow.id]:[];state.flow=null;state.dirty=false;}
      return JSON.stringify({snapshot:projection(),result});
    }),onSnapshot:(listener:(value:string)=>void)=>{publish=listener;return {remove:()=>{publish=undefined;}};}};
  const app=new AppStore(native as unknown as Spec,projection(),initialPresentation?{initial:true}:undefined);const disconnect=app.connect();
  return {app,native,state,projection,reads,disconnect,publish:()=>publish?.(JSON.stringify(projection()))};
};
function StoreForeground({app}:{app:AppStore}){
  const state=useSyncExternalStore(app.subscribe,app.getSnapshot);
  return <ReviewContext.Provider value={{app,live:state.snapshot??undefined} as unknown as ReviewState}><ForegroundFlowScreen/></ReviewContext.Provider>;
}
test('a cold withheld foreground visit waits for its exact owner and native form viewport before reveal',async()=>{
  const fixture=foregroundStoreFixture(null,true,true);
  const entry=deferred<string>();fixture.native.command.mockImplementationOnce(()=>entry.promise);
  // Native may withhold the private flow while retaining the presented route.
  const view=render(<StoreForeground app={fixture.app}/>);
  try{
    await act(async()=>{});
    expect(fixture.native.command.mock.calls.map(([request])=>JSON.parse(request))).toEqual([{type:'foreground.enter',id:'visit'}]);
    expect(screen.getByTestId('foreground-flow-privacy-cover')).toBeTruthy();
    expect(screen.queryByLabelText('Name')).toBeNull();
    await act(async()=>fixture.app.completePresentationLayout(fixture.app.getPresentationHydration().epoch));
    expect(fixture.app.getPresentationHydration().required).toBe(true);
    fixture.state.flow={id:'visit',kind:'renameFilter',name:'Restored owner',emoji:'🌱',dismissAttempt:0,canCreate:true,templates:[]};
    await act(async()=>entry.resolve(JSON.stringify({snapshot:fixture.projection(),result:null})));
    expect(screen.getByLabelText('Name')).toBeTruthy();expect(formValue('Name')).toBe('Restored owner');
    expect(fixture.app.getPresentationHydration().required).toBe(true);
    await act(async()=>measureForegroundViewport());
    expect(fixture.app.getPresentationHydration().required).toBe(false);
  }finally{view.unmount();fixture.disconnect();}
});
test('failed preparation of an initially withheld foreground visit settles to an explicit retry',async()=>{
  const ticket={epoch:1,id:1};const settle=jest.fn();
  const command=jest.fn(async()=>{throw new Error('Native visit unavailable');});
  const app={command,getSnapshot:()=>({snapshot:{security:{readRevision:1}}}),getPresentationHydration:()=>({epoch:1,required:true}),registerPresentationRead:()=>ticket,settlePresentationRead:settle};
  render(<ReviewContext.Provider value={{app,live:{security:{readRevision:1}}} as unknown as ReviewState}><ForegroundFlowScreen/></ReviewContext.Provider>);
  await act(async()=>{});
  expect(command.mock.calls).toEqual([[{type:'foreground.enter',id:'visit'}]]);
  expect(settle).toHaveBeenCalledWith(ticket);
  expect(screen.getByText('Native visit unavailable')).toBeTruthy();
  expect(screen.getByText('Unlock Lava')).toBeTruthy();
  await act(async()=>fireEvent.press(screen.getByText('Unlock Lava')));
  expect(command).toHaveBeenCalledTimes(2);
});
const readOnlyFlow=(kind:'automation'|'licenses'):ForegroundFlow=>({id:'visit',kind,name:'',emoji:'',dismissAttempt:0,canCreate:false,templates:[],notices:'Authorized license text'});
const enterRequests=(fixture:ReturnType<typeof foregroundStoreFixture>)=>fixture.native.command.mock.calls.map(([raw])=>JSON.parse(raw)).filter(action=>action.type==='foreground.enter');
test.each(['automation','licenses'] as const)('retained %s authorizes its exact current native projection beneath shared resume readiness',async kind=>{
  const emit=controlledLifecycle(),flow=readOnlyFlow(kind),fixture=foregroundStoreFixture(flow,true);
  const view=render(<StoreForeground app={fixture.app}/>);
  try{
    await act(async()=>{});measureForegroundViewport();
    const scroll=screen.UNSAFE_getByType(ScrollView),entry=deferred<string>();
    expect(fixture.native.command).not.toHaveBeenCalled();
    fixture.native.command.mockImplementationOnce(()=>entry.promise);
    await act(async()=>{emit('background');});
    expect(fixture.native.command).not.toHaveBeenCalled();
    await act(async()=>{fixture.state.flow=null;++fixture.state.authority;emit('active');fixture.publish();});
    await act(async()=>fixture.app.completePresentationLayout(fixture.app.getPresentationHydration().epoch));
    expect(enterRequests(fixture)).toEqual([{type:'foreground.enter',id:'visit'}]);
    expect(fixture.app.getPresentationHydration().required).toBe(true);
    expect(screen.getByTestId('foreground-flow-privacy-cover')).toBeTruthy();
    expect(screen.UNSAFE_getByType(ScrollView)).toBe(scroll);
    // An impatient retry cannot enqueue a second authorization while one is pending.
    await act(async()=>fireEvent.press(screen.getByText('Unlock Lava')));
    expect(enterRequests(fixture)).toHaveLength(1);
    fixture.state.flow={...flow,notices:'Current authorized license text'};
    await act(async()=>entry.resolve(JSON.stringify({snapshot:fixture.projection(),result:null})));
    expect(fixture.app.getPresentationHydration().required).toBe(false);
    expect(screen.queryByTestId('foreground-flow-privacy-cover')).toBeNull();
    expect(screen.UNSAFE_getByType(ScrollView)).toBe(scroll);
    if(kind==='licenses')expect(screen.getByText('Current authorized license text')).toBeTruthy();
    else expect(screen.getByText('Open Shortcuts')).toBeTruthy();
    expect(enterRequests(fixture)).toHaveLength(1);
  }finally{view.unmount();fixture.disconnect();Object.defineProperty(AppState,'currentState',{configurable:true,value:'active'});}
});
test.each(['automation','licenses'] as const)('retained %s preparation failure exposes a retry instead of releasing to an invisible sheet',async kind=>{
  const emit=controlledLifecycle(),flow=readOnlyFlow(kind),fixture=foregroundStoreFixture(flow,true);
  const view=render(<StoreForeground app={fixture.app}/>);
  try{
    await act(async()=>{});measureForegroundViewport();
    const scroll=screen.UNSAFE_getByType(ScrollView);
    fixture.native.command.mockImplementationOnce(async()=>{throw new Error('Native visit unavailable');});
    await act(async()=>{emit('background');fixture.state.flow=null;++fixture.state.authority;emit('active');fixture.publish();});
    await act(async()=>fixture.app.completePresentationLayout(fixture.app.getPresentationHydration().epoch));
    expect(enterRequests(fixture)).toEqual([{type:'foreground.enter',id:'visit'}]);
    expect(fixture.app.getPresentationHydration().required).toBe(false);
    expect(screen.getByTestId('foreground-flow-privacy-cover')).toBeTruthy();
    expect(screen.getByText('Native visit unavailable')).toBeTruthy();
    expect(screen.UNSAFE_getByType(ScrollView)).toBe(scroll);
    fixture.native.command.mockImplementationOnce(async()=>{fixture.state.flow=flow;return JSON.stringify({snapshot:fixture.projection(),result:null});});
    await act(async()=>fireEvent.press(screen.getByText('Unlock Lava')));
    expect(enterRequests(fixture)).toHaveLength(2);
    expect(screen.queryByTestId('foreground-flow-privacy-cover')).toBeNull();
    expect(screen.UNSAFE_getByType(ScrollView)).toBe(scroll);
  }finally{view.unmount();fixture.disconnect();Object.defineProperty(AppState,'currentState',{configurable:true,value:'active'});}
});
test.each(['automation','licenses'] as const)('a pending %s entry interrupted by another privacy turn prepares the current visit after the old reply settles',async kind=>{
  const emit=controlledLifecycle(),flow=readOnlyFlow(kind),fixture=foregroundStoreFixture(flow,true);
  const view=render(<StoreForeground app={fixture.app}/>);
  try{
    await act(async()=>{});measureForegroundViewport();
    const scroll=screen.UNSAFE_getByType(ScrollView),oldEntry=deferred<string>();
    fixture.native.command.mockImplementationOnce(()=>oldEntry.promise);
    await act(async()=>{emit('background');fixture.state.flow=null;++fixture.state.authority;emit('active');fixture.publish();});
    const oldReply=JSON.stringify({snapshot:fixture.projection(),result:null});
    expect(enterRequests(fixture)).toHaveLength(1);
    // JS read authority still retires if a batched pause restores the same
    // native grant. A render-only scope comparison would miss this turn.
    await act(async()=>{emit('background');emit('active');fixture.publish();});
    await act(async()=>fixture.app.completePresentationLayout(fixture.app.getPresentationHydration().epoch));
    expect(enterRequests(fixture)).toHaveLength(1);
    expect(fixture.app.getPresentationHydration().required).toBe(true);
    fixture.native.command.mockImplementationOnce(async()=>{fixture.state.flow=flow;return JSON.stringify({snapshot:fixture.projection(),result:null});});
    await act(async()=>oldEntry.resolve(oldReply));
    expect(enterRequests(fixture)).toEqual([{type:'foreground.enter',id:'visit'},{type:'foreground.enter',id:'visit'}]);
    expect(fixture.app.getSnapshot().snapshot?.foregroundFlow?.id).toBe('visit');
    expect(fixture.app.getPresentationHydration().required).toBe(false);
    expect(screen.queryByTestId('foreground-flow-privacy-cover')).toBeNull();
    expect(screen.UNSAFE_getByType(ScrollView)).toBe(scroll);
  }finally{view.unmount();fixture.disconnect();Object.defineProperty(AppState,'currentState',{configurable:true,value:'active'});}
});
test.each(['automation','licenses'] as const)('native-confirmed closing of %s does not reopen its outgoing visit',async kind=>{
  const fixture=foregroundStoreFixture(readOnlyFlow(kind),true),view=render(<StoreForeground app={fixture.app}/>);
  try{
    await act(async()=>{});const scroll=screen.UNSAFE_getByType(ScrollView);
    fixture.state.flow=null;fixture.state.closing=['visit'];await act(async()=>fixture.publish());
    expect(fixture.native.command).not.toHaveBeenCalled();
    expect(screen.queryByTestId('foreground-flow-privacy-cover')).toBeNull();
    expect(screen.UNSAFE_getByType(ScrollView)).toBe(scroll);
  }finally{view.unmount();fixture.disconnect();}
});
test('cold feedback prepares its current native report beneath initial hydration instead of leaving Submit permanently disabled',async()=>{
  const flow:ForegroundFlow={id:'visit',kind:'feedback',name:'',emoji:'',dismissAttempt:0,canCreate:false,templates:[],feedback:{...feedback,prepared:false}};
  const fixture=foregroundStoreFixture(flow,true,true),sampling=deferred<string>();
  fixture.native.command.mockImplementationOnce(()=>sampling.promise);
  const view=render(<StoreForeground app={fixture.app}/>);
  try{
    await act(async()=>{});
    expect(fixture.app.getPresentationHydration().required).toBe(true);
    expect(fixture.native.command.mock.calls.map(([raw])=>JSON.parse(raw))).toEqual([{type:'feedback.enter',id:'visit'}]);
    expect(screen.UNSAFE_getAllByType(LavaActionButton).find(button=>button.props.title==='Submit')?.props.disabled).toBe(true);
    await act(async()=>fixture.app.completePresentationLayout(fixture.app.getPresentationHydration().epoch));
    fixture.state.flow={...flow,feedback:{...feedback,prepared:true}};
    await act(async()=>sampling.resolve(JSON.stringify({snapshot:fixture.projection(),result:null})));
    expect(fixture.app.getPresentationHydration().required).toBe(true);
    expect(screen.UNSAFE_getAllByType(LavaActionButton).find(button=>button.props.title==='Submit')?.props.disabled).toBe(false);
    measureForegroundViewport();await act(async()=>{});
    expect(fixture.app.getPresentationHydration().required).toBe(false);
    expect(fixture.native.command).toHaveBeenCalledTimes(1);
  }finally{view.unmount();fixture.disconnect();}
});
test('successful WireGuard Save keeps the exact outgoing sheet inert without an Unlock flash',async()=>{
  const editor={...vpn,name:'Imported profile',canSave:true,hasContent:true,dirty:true};
  const fixture=foregroundStoreFixture({id:'visit',kind:'vpnConfiguration',name:'',emoji:'',dismissAttempt:0,canCreate:false,templates:[],vpnEditor:editor},true);
  const view=render(<StoreForeground app={fixture.app}/>);
  try{
    await act(async()=>{});const sheet=screen.UNSAFE_getByType(FlowSheet),name=screen.getByLabelText('Name');
    const file=screen.getByRole('button',{name:localized('Choose File')}).props.onPress as ()=>void;
    await act(async()=>fireEvent.press(screen.getByText('Save')));
    expect(fixture.state.flow).toBeNull();expect(fixture.state.closing).toEqual(['visit']);
    expect(screen.queryByTestId('vpn-editor-privacy-cover')).toBeNull();
    expect(screen.UNSAFE_getByType(FlowSheet)).toBe(sheet);
    expect(screen.getByLabelText('Name',{includeHiddenElements:true})).toBe(name);
    expect(formValue('Name')).toBe('Imported profile');
    expect(screen.getByLabelText('Name',{includeHiddenElements:true}).props.editable).toBe(false);
    fixture.native.command.mockClear();await act(async()=>file?.());
    expect(fixture.native.command).not.toHaveBeenCalled();
  }finally{view.unmount();fixture.disconnect();}
});
test('WireGuard reentry holds shared resume readiness until the current native editor is committed',async()=>{
  const emit=controlledLifecycle();
  const fixture=foregroundStoreFixture({id:'visit',kind:'vpnConfiguration',name:'',emoji:'',dismissAttempt:0,canCreate:false,templates:[],vpnEditor:{...vpn,name:'Retained name'}},true);
  const view=render(<StoreForeground app={fixture.app}/>);
  try{
    await act(async()=>{});measureForegroundViewport();const sheet=screen.UNSAFE_getByType(FlowSheet),entry=deferred<string>();
    fixture.native.command.mockImplementationOnce(()=>entry.promise);
    await act(async()=>{emit('inactive');emit('active');fixture.state.flow={...fixture.state.flow!,vpnEditor:null};++fixture.state.authority;fixture.publish();});
    const epoch=fixture.app.getPresentationHydration().epoch;
    await act(async()=>fixture.app.completePresentationLayout(epoch));
    expect(fixture.app.getPresentationHydration().required).toBe(true);
    expect(screen.getByTestId('vpn-editor-privacy-cover')).toBeTruthy();
    fixture.state.flow={...fixture.state.flow!,vpnEditor:{...vpn,name:'Retained name'}};
    await act(async()=>entry.resolve(JSON.stringify({snapshot:fixture.projection(),result:null})));
    expect(fixture.app.getPresentationHydration().required).toBe(false);
    expect(screen.queryByTestId('vpn-editor-privacy-cover')).toBeNull();
    expect(screen.UNSAFE_getByType(FlowSheet)).toBe(sheet);expect(formValue('Name')).toBe('Retained name');
  }finally{view.unmount();fixture.disconnect();Object.defineProperty(AppState,'currentState',{configurable:true,value:'active'});}
});
test.each(['authority','background'] as const)('a closing WireGuard frame conceals immediately on %s revocation',async boundary=>{
  const emit=controlledLifecycle();
  const fixture=foregroundStoreFixture({id:'visit',kind:'vpnConfiguration',name:'',emoji:'',dismissAttempt:0,canCreate:false,templates:[],vpnEditor:{...vpn,name:'Accepted frame'}},true);
  const view=render(<StoreForeground app={fixture.app}/>);
  try{
    await act(async()=>{});fixture.state.closing=['visit'];fixture.state.flow=null;
    await act(async()=>fixture.publish());expect(screen.queryByTestId('vpn-editor-privacy-cover')).toBeNull();
    await act(async()=>{if(boundary==='authority'){++fixture.state.authority;fixture.publish();}else emit('background');});
    expect(screen.getByTestId('vpn-editor-privacy-cover')).toBeTruthy();
    expect(screen.getByLabelText('Name',{includeHiddenElements:true}).props.editable).toBe(false);
  }finally{view.unmount();fixture.disconnect();Object.defineProperty(AppState,'currentState',{configurable:true,value:'active'});}
});
test('a late native name acknowledgement cannot replace newer typing in the WireGuard form',async()=>{
  const first=deferred<null>(),second=deferred<null>();
  const command=jest.fn(action=>action.type==='vpnEditor.name'?(action.name==='A'?first.promise:second.promise):Promise.resolve(null));
  const provider=(state:VPNEditorState)=><ReviewContext.Provider value={{app:{command}} as unknown as ReviewState}><VPNEditorFlow id="visit" state={state} dismissAttempt={0}/></ReviewContext.Provider>;
  const view=render(provider(vpn));await act(async()=>{});
  fireEvent.changeText(screen.getByLabelText('Name'),'A');fireEvent.changeText(screen.getByLabelText('Name'),'AB');
  view.rerender(provider({...vpn,name:'A',dirty:true}));
  expect(formValue('Name')).toBe('AB');
  await act(async()=>first.resolve(null));
  expect(formValue('Name')).toBe('AB');
  view.rerender(provider({...vpn,name:'AB',dirty:true}));await act(async()=>second.resolve(null));
  expect(formValue('Name')).toBe('AB');
  view.rerender(provider({...vpn,name:'imported profile',nameResetRevision:1,dirty:true}));
  expect(formValue('Name')).toBe('imported profile');
});
test('a delayed WireGuard typing projection cannot become an import reset after the command queue settles',async()=>{
  const command=jest.fn().mockResolvedValue(null);const app={command};
  const provider=(state:VPNEditorState)=><ReviewContext.Provider value={{app} as unknown as ReviewState}><VPNEditorFlow id="visit" state={state} dismissAttempt={0}/></ReviewContext.Provider>;
  const view=render(provider(vpn));await act(async()=>{});
  fireEvent.changeText(screen.getByLabelText('Name'),'A');
  fireEvent.changeText(screen.getByLabelText('Name'),'AB');await act(async()=>{});
  view.rerender(provider({...vpn,name:'A',dirty:true}));await act(async()=>{});
  expect(formValue('Name')).toBe('AB');
});
test('native-only WireGuard edits require confirmation while React still projects a clean draft',async()=>{
  const response=deferred<boolean>();let nativeConfiguration='Synthetic native-only comment';
  const command=jest.fn(async(action:AppCommand)=>{
    if(action.type!=='foreground.dismiss')return null;
    if(action.discardConfirmed){nativeConfiguration='';return null;}
    return response.promise;
  });
  const alert=jest.spyOn(NativeAlert,'alert').mockImplementation(()=>{});
  render(<ReviewContext.Provider value={{app:{command}} as unknown as ReviewState}><VPNEditorFlow id="visit" state={vpn} dismissAttempt={0}/></ReviewContext.Provider>);
  await act(async()=>{});command.mockClear();
  const close=()=>mockNavigation.setOptions.mock.calls.at(-1)![0].unstable_headerLeftItems()[0].onPress();
  act(()=>{close();close();});
  expect(command.mock.calls).toEqual([[{type:'foreground.dismiss',id:'visit'}]]);
  expect(alert).not.toHaveBeenCalled();
  await act(async()=>response.resolve(false));
  expect(alert).toHaveBeenCalledTimes(1);
  expect(alert).toHaveBeenCalledWith('Discard changes?','Your saved VPN settings will stay active.',expect.any(Array),expect.objectContaining({onDismiss:expect.any(Function)}));
  act(()=>close());expect(command).toHaveBeenCalledTimes(1);expect(alert).toHaveBeenCalledTimes(1);
  const cancelled=alert.mock.calls[0]![2]!;
  act(()=>cancelled.find(button=>button.style==='cancel')!.onPress?.());
  act(()=>cancelled.find(button=>button.style==='destructive')!.onPress?.());
  expect(nativeConfiguration).toBe('Synthetic native-only comment');expect(command).toHaveBeenCalledTimes(1);
  await act(async()=>close());expect(alert).toHaveBeenCalledTimes(2);
  const current=alert.mock.calls[1]![2]!;
  await act(async()=>current.find(button=>button.style==='destructive')!.onPress?.());
  expect(command.mock.calls.at(-1)).toEqual([{type:'foreground.dismiss',id:'visit',discardConfirmed:true}]);
  expect(nativeConfiguration).toBe('');
  expect(JSON.stringify(command.mock.calls)).not.toContain('Synthetic native-only comment');
});
test('an unacknowledged local WireGuard Name still prompts immediately and sends only explicit Discard',async()=>{
  const command=jest.fn(async(_action:AppCommand)=>null);const alert=jest.spyOn(NativeAlert,'alert').mockImplementation(()=>{});
  render(<ReviewContext.Provider value={{app:{command}} as unknown as ReviewState}><VPNEditorFlow id="visit" state={vpn} dismissAttempt={0}/></ReviewContext.Provider>);
  await act(async()=>{});
  fireEvent.changeText(screen.getByLabelText('Name'),'Unsaved Name');command.mockClear();
  act(()=>mockNavigation.setOptions.mock.calls.at(-1)![0].unstable_headerLeftItems()[0].onPress());
  expect(alert).toHaveBeenCalledTimes(1);expect(command).not.toHaveBeenCalled();
  await act(async()=>alert.mock.calls[0]![2]!.find(button=>button.style==='destructive')!.onPress?.());
  expect(command.mock.calls).toEqual([[{type:'foreground.dismiss',id:'visit',discardConfirmed:true}]]);
});
test.each([null,true])('a native-confirmed clean WireGuard close (%p) never shows Discard',async result=>{
  const command=jest.fn(async(action:AppCommand)=>action.type==='foreground.dismiss'?result:null);
  const alert=jest.spyOn(NativeAlert,'alert').mockImplementation(()=>{});
  render(<ReviewContext.Provider value={{app:{command}} as unknown as ReviewState}><VPNEditorFlow id="visit" state={vpn} dismissAttempt={0}/></ReviewContext.Provider>);
  await act(async()=>{});command.mockClear();
  await act(async()=>mockNavigation.setOptions.mock.calls.at(-1)![0].unstable_headerLeftItems()[0].onPress());
  expect(command.mock.calls).toEqual([[{type:'foreground.dismiss',id:'visit'}]]);expect(alert).not.toHaveBeenCalled();
});
test('a readable read-only WireGuard editor can still close its clean native visit',async()=>{
  const state={...vpn,canEdit:false};const command=jest.fn(async(_action:AppCommand)=>null);
  const app={command,getSnapshot:()=>({snapshot:{foregroundFlow:{id:'visit',kind:'vpnConfiguration',vpnEditor:state}}})};
  render(<ReviewContext.Provider value={{app} as unknown as ReviewState}><VPNEditorFlow id="visit" state={state} dismissAttempt={0}/></ReviewContext.Provider>);
  await act(async()=>{});command.mockClear();
  await act(async()=>mockNavigation.setOptions.mock.calls.at(-1)![0].unstable_headerLeftItems()[0].onPress());
  expect(command.mock.calls).toEqual([[{type:'foreground.dismiss',id:'visit'}]]);
});
test.each(['projection','owner','authority','unmount'] as const)('a delayed dirty WireGuard close reply cannot prompt after %s retirement',async retirement=>{
  const response=deferred<boolean>();let epoch=1;
  let flow:{id:string;kind:string;vpnEditor:VPNEditorState|null}={id:'visit',kind:'vpnConfiguration',vpnEditor:vpn};
  const command=jest.fn(async(action:AppCommand)=>action.type==='foreground.dismiss'?response.promise:null);
  const app={command,getReadEpoch:()=>epoch,getSnapshot:()=>({snapshot:{foregroundFlow:flow,security:{ownerRevision:'owner',readRevision:epoch}}})};
  const alert=jest.spyOn(NativeAlert,'alert').mockImplementation(()=>{});
  const view=render(<ReviewContext.Provider value={{app} as unknown as ReviewState}><VPNEditorFlow id="visit" state={vpn} dismissAttempt={0}/></ReviewContext.Provider>);
  await act(async()=>{});command.mockClear();
  act(()=>mockNavigation.setOptions.mock.calls.at(-1)![0].unstable_headerLeftItems()[0].onPress());
  if(retirement==='projection')flow={...flow,vpnEditor:null};
  else if(retirement==='owner')flow={...flow,id:'replacement'};
  else if(retirement==='authority')++epoch;
  else view.unmount();
  await act(async()=>response.resolve(false));
  expect(alert).not.toHaveBeenCalled();expect(command.mock.calls).toEqual([[{type:'foreground.dismiss',id:'visit'}]]);
});
test('an old WireGuard Discard callback is inert after a read pause and a fresh close uses the new epoch',async()=>{
  let epoch=1;let required=false;
  const command=jest.fn(async(action:AppCommand)=>action.type==='foreground.dismiss'?false:null);
  const app={command,getReadEpoch:()=>epoch,getSnapshot:()=>({snapshot:{foregroundFlow:{id:'visit',kind:'vpnConfiguration',vpnEditor:vpn},security:{ownerRevision:'owner',readRevision:epoch}}}),getPresentationHydration:()=>({required})};
  const alert=jest.spyOn(NativeAlert,'alert').mockImplementation(()=>{});
  const provider=()=> <ReviewContext.Provider value={{app} as unknown as ReviewState}><VPNEditorFlow id="visit" state={vpn} dismissAttempt={0}/></ReviewContext.Provider>;
  const view=render(provider());
  await act(async()=>{});command.mockClear();
  const close=()=>mockNavigation.setOptions.mock.calls.at(-1)![0].unstable_headerLeftItems()[0].onPress();
  await act(async()=>close());
  const old=alert.mock.calls[0]![2]!.find(button=>button.style==='destructive')!;
  ++epoch;required=true;command.mockClear();
  await act(async()=>old.onPress?.());expect(command).not.toHaveBeenCalled();
  required=false;view.rerender(provider());
  await act(async()=>close());expect(alert).toHaveBeenCalledTimes(2);
  const fresh=alert.mock.calls[1]![2]!.find(button=>button.style==='destructive')!;
  await act(async()=>old.onPress?.());
  expect(command.mock.calls).toEqual([[{type:'foreground.dismiss',id:'visit'}]]);
  await act(async()=>fresh.onPress?.());
  expect(command.mock.calls.at(-1)).toEqual([{type:'foreground.dismiss',id:'visit',discardConfirmed:true}]);
});
test('a real AppStore dirty-close ACK advances source/read epoch without cancelling current Discard consent',async()=>{
  const fixture=foregroundStoreFixture({id:'visit',kind:'vpnConfiguration',name:'',emoji:'',dismissAttempt:0,canCreate:false,templates:[],vpnEditor:vpn});
  const alert=jest.spyOn(NativeAlert,'alert').mockImplementation(()=>{});
  const view=render(<StoreForeground app={fixture.app}/>);
  try{
    await act(async()=>{});fixture.native.command.mockClear();fixture.state.dirty=true;
    const epoch=fixture.app.getReadEpoch();
    await act(async()=>mockNavigation.setOptions.mock.calls.at(-1)![0].unstable_headerLeftItems()[0].onPress());
    expect(fixture.app.getReadEpoch()).toBeGreaterThan(epoch);
    expect(alert).toHaveBeenCalledTimes(1);expect(fixture.state.flow?.id).toBe('visit');
    expect(fixture.native.command.mock.calls.map(([request])=>JSON.parse(request))).toEqual([{type:'foreground.dismiss',id:'visit'}]);
    await act(async()=>alert.mock.calls[0]![2]!.find(button=>button.style==='destructive')!.onPress?.());
    expect(fixture.native.command.mock.calls.map(([request])=>JSON.parse(request))).toEqual([
      {type:'foreground.dismiss',id:'visit'},{type:'foreground.dismiss',id:'visit',discardConfirmed:true}]);
    expect(fixture.state.flow).toBeNull();
  }finally{view.unmount();fixture.disconnect();}
});
test('WireGuard consent rejects a batched all-off lifecycle pause even with unchanged native authority',async()=>{
  const emit=controlledLifecycle();const fixture=foregroundStoreFixture({id:'visit',kind:'vpnConfiguration',name:'',emoji:'',dismissAttempt:0,canCreate:false,templates:[],vpnEditor:vpn});
  const alert=jest.spyOn(NativeAlert,'alert').mockImplementation(()=>{});const response=deferred<string>();
  const view=render(<StoreForeground app={fixture.app}/>);
  try{
    await act(async()=>{});fixture.native.command.mockClear();
    fixture.native.command.mockImplementationOnce(()=>response.promise);
    act(()=>mockNavigation.setOptions.mock.calls.at(-1)![0].unstable_headerLeftItems()[0].onPress());
    await act(async()=>{emit('inactive');emit('active');fixture.publish();});
    await act(async()=>response.resolve(JSON.stringify({snapshot:fixture.projection(),result:false})));
    expect(alert).not.toHaveBeenCalled();
  }finally{view.unmount();fixture.disconnect();Object.defineProperty(AppState,'currentState',{configurable:true,value:'active'});}
});
test('the real retained WireGuard form denies stale Name callbacks before its buffer changes across an all-off resume',async()=>{
  const lifecycle=new Set<(state:AppStateStatus)=>void>();
  jest.mocked(AppState.addEventListener).mockImplementation((_type,listener)=>{
    const callback=listener as (state:AppStateStatus)=>void;lifecycle.add(callback);return {remove:()=>{lifecycle.delete(callback);}};
  });
  const emitState=(state:AppStateStatus)=>act(()=>{Object.defineProperty(AppState,'currentState',{configurable:true,value:state});for(const listener of [...lifecycle])listener(state);});
  const projection=(revision:number):AppSnapshot=>({schema:1,fullApp:true,revision,backgroundPrivacyCoverRequired:false,
    foregroundFlow:{id:'visit',kind:'vpnConfiguration',name:'',emoji:'',dismissAttempt:0,canCreate:false,templates:[],vpnEditor:vpn}} as unknown as AppSnapshot);
  const reads:ReturnType<typeof deferred<string>>[]=[];
  const native={getSnapshot:jest.fn(()=>{const read=deferred<string>();reads.push(read);return read.promise;}),
    command:jest.fn(async(_request:string)=>JSON.stringify({snapshot:projection(2),result:null})),onSnapshot:()=>({remove:jest.fn()})};
  const app=new AppStore(native as unknown as Spec,projection(1));const disconnect=app.connect();
  const view=render(<ReviewContext.Provider value={{app} as unknown as ReviewState}><VPNEditorFlow id="visit" state={vpn} dismissAttempt={0}/></ReviewContext.Provider>);
  try{
    await act(async()=>{});
    const nameInput=screen.UNSAFE_getByProps({kind:'wireGuardName'}),configuration=screen.UNSAFE_getByProps({kind:'wireGuard'});
    expect(nameInput.props).toMatchObject({ownerID:'visit',editable:true,resetRevision:0});
    const staleChange=nameInput.props.onChange as (event:{nativeEvent:{text:string}})=>void;
    act(()=>staleChange({nativeEvent:{text:'Accepted Name buffer'}}));await act(async()=>{});
    expect(formValue('Name')).toBe('Accepted Name buffer');native.command.mockClear();
    const startup=reads[0]!;
    for(const state of ['inactive','background','active'] as const){
      emitState(state);
      expect(app.getSnapshot().snapshot).toBeNull();expect(app.getSnapshot().displaySnapshot?.foregroundFlow?.vpnEditor?.canEdit).toBe(true);
      expect(screen.UNSAFE_getByProps({kind:'wireGuardName'}).props.editable).toBe(false);
      act(()=>staleChange({nativeEvent:{text:`Unauthorized ${state}`}}));await act(async()=>{});
      expect(formValue('Name')).toBe('Accepted Name buffer');expect(native.command).not.toHaveBeenCalled();
      // Retention is observable here; Content's native touch/menu/delegate
      // admission is covered by WireGuardSetupSourceTests, not a JS editable prop.
      expect(screen.UNSAFE_getByProps({kind:'wireGuard'})).toBe(configuration);
    }
    await act(async()=>startup.resolve(JSON.stringify(projection(9))));
    expect(screen.UNSAFE_getByProps({kind:'wireGuardName'}).props.editable).toBe(false);
    await act(async()=>reads.at(-1)!.resolve(JSON.stringify(projection(10))));
    expect(screen.UNSAFE_getByProps({kind:'wireGuardName'}).props.editable).toBe(true);
    expect(formValue('Name')).toBe('Accepted Name buffer');expect(screen.UNSAFE_getByProps({kind:'wireGuard'})).toBe(configuration);
    native.command.mockClear();
    act(()=>screen.UNSAFE_getByProps({kind:'wireGuardName'}).props.onChange({nativeEvent:{text:'Authorized continued Name'}}));await act(async()=>{});
    expect(formValue('Name')).toBe('Authorized continued Name');
    expect(native.command.mock.calls.map(([request])=>JSON.parse(request))).toEqual([{type:'vpnEditor.name',id:'visit',name:'Authorized continued Name'}]);
    native.command.mockClear();
    act(()=>staleChange({nativeEvent:{text:'Old pre-background Name callback'}}));await act(async()=>{});
    expect(formValue('Name')).toBe('Authorized continued Name');expect(native.command).not.toHaveBeenCalled();
    view.unmount();native.command.mockClear();act(()=>staleChange({nativeEvent:{text:'Unmounted callback'}}));await act(async()=>{});
    expect(native.command).not.toHaveBeenCalled();
  }finally{view.unmount();disconnect();Object.defineProperty(AppState,'currentState',{configurable:true,value:'active'});}
});
test.each(['owner','kind','missing editor','read-only editor','hydration'] as const)('a stale WireGuard Name callback rejects current %s exclusion before local mutation',async exclusion=>{
  const listeners=new Set<()=>void>();let required=false;
  let flow:Record<string,unknown>={id:'visit',kind:'vpnConfiguration',vpnEditor:vpn};
  const command=jest.fn(async(_action:AppCommand)=>null);
  const app={command,subscribe:(listener:()=>void)=>{listeners.add(listener);return()=>{listeners.delete(listener);};},
    getSnapshot:()=>({snapshot:{foregroundFlow:flow}}),getPresentationHydration:()=>({required})};
  render(<ReviewContext.Provider value={{app} as unknown as ReviewState}><VPNEditorFlow id="visit" state={vpn} dismissAttempt={0}/></ReviewContext.Provider>);
  await act(async()=>{});
  const input=screen.UNSAFE_getByProps({kind:'wireGuardName'}),staleChange=input.props.onChange;
  act(()=>staleChange({nativeEvent:{text:'Accepted private Name'}}));await act(async()=>{});command.mockClear();
  // Change current authority without replacing the accepted projection or waiting
  // for React to rerender: an already queued native callback must still be inert.
  if(exclusion==='owner')flow={...flow,id:'replacement'};
  else if(exclusion==='kind')flow={...flow,kind:'feedback'};
  else if(exclusion==='missing editor')flow={...flow,vpnEditor:null};
  else if(exclusion==='read-only editor')flow={...flow,vpnEditor:{...vpn,canEdit:false}};
  else required=true;
  act(()=>staleChange({nativeEvent:{text:'Denied edit'}}));
  expect(formValue('Name')).toBe('Accepted private Name');expect(command).not.toHaveBeenCalled();
  act(()=>{for(const listener of listeners)listener();});
  expect(screen.UNSAFE_getByProps({kind:'wireGuardName'}).props.editable).toBe(false);
});
test('Submit consumes the reviewed revision once and refuses Cancel through preparation',async()=>{
  const sending=deferred<boolean>();
  const command=jest.fn(action=>action.type==='feedback.submit'?sending.promise:Promise.resolve(null));
  render(<ReviewContext.Provider value={{app:{command}} as unknown as ReviewState}><FeedbackFlow id="feedback-visit" state={feedback} dismissAttempt={0}/></ReviewContext.Provider>);
  await act(async()=>{});command.mockClear();
  fireEvent.press(screen.getByRole('button',{name:'Submit'}));
  const submit=command.mock.calls.filter(([action])=>action.type==='feedback.submit');
  expect(submit).toEqual([[{type:'feedback.submit',id:'feedback-visit',review:'7'}]]);
  const options=mockNavigation.setOptions.mock.calls.at(-1)![0];
  const cancel=options.unstable_headerLeftItems()[0];expect(cancel.disabled).toBe(true);cancel.onPress();
  const busySubmit=screen.getByRole('button',{name:/^Submitting/});
  expect(busySubmit.props.accessibilityState.disabled).toBe(true);fireEvent.press(busySubmit);
  expect(command.mock.calls.filter(([action])=>action.type==='feedback.submit')).toHaveLength(1);
  expect(command.mock.calls.some(([action])=>action.type==='foreground.dismiss')).toBe(false);
  await act(async()=>sending.resolve(true));
});
test('Cancel confirms the first keystroke before native dirty-state acknowledgement',async()=>{
  const change=deferred<FeedbackState>();const command=jest.fn(action=>action.type==='feedback.change'?change.promise:Promise.resolve(null));
  const alert=jest.spyOn(NativeAlert,'alert').mockImplementation(()=>{});
  const state={...feedback,details:'',dirty:false,step:1,prepared:false};
  render(<ReviewContext.Provider value={{app:{command}} as unknown as ReviewState}><FeedbackFlow id="visit" state={state} dismissAttempt={0}/></ReviewContext.Provider>);
  await act(async()=>{});command.mockClear();
  fireEvent.changeText(screen.getByLabelText('Details'),'A');
  act(()=>mockNavigation.setOptions.mock.calls.at(-1)![0].unstable_headerLeftItems()[0].onPress());
  expect(alert).toHaveBeenCalledWith('Discard feedback?','Your feedback draft will be removed.',expect.any(Array),undefined);
  expect(command.mock.calls.some(([action])=>action.type==='foreground.dismiss')).toBe(false);
});
test.each([['site',300],['details',5000],['email',320]] as const)('native %s truncation explicitly resets the visible buffer once',async(field,limit)=>{
  const correction=deferred<FeedbackState>();
  const command=jest.fn((action:AppCommand)=>action.type==='feedback.change'?correction.promise:Promise.resolve(null));
  const state={...feedback,topic:'websiteAccess',site:'',details:'',email:'',step:1};
  render(<ReviewContext.Provider value={{app:{command}} as unknown as ReviewState}><FeedbackFlow id="visit" state={state} dismissAttempt={0}/></ReviewContext.Provider>);
  await act(async()=>{});
  const title={site:'Site or domain',details:'Details',email:'Email for follow-up (optional)'}[field];
  const typed='👨‍👩‍👧‍👦'.repeat(limit+1),accepted='👨‍👩‍👧‍👦'.repeat(limit);
  fireEvent.changeText(screen.getByLabelText(localized(title)),typed);
  expect(screen.UNSAFE_getAllByType(FormField).find(input=>input.props.title===title)?.props.resetRevision??0).toBe(0);
  await act(async()=>correction.resolve({...state,[field]:accepted,count:field==='details'?limit:0}));
  const input=screen.UNSAFE_getAllByType(FormField).find(input=>input.props.title===title)!;
  expect(input.props.value).toBe(accepted);expect(input.props.resetRevision).toBe(1);
});
test('an older feedback truncation cannot replace a later native edit',async()=>{
  const first=deferred<FeedbackState>(),second=deferred<FeedbackState>();
  const command=jest.fn((action:AppCommand)=>action.type==='feedback.change'?(action.value==='Over limit'?first.promise:second.promise):Promise.resolve(null));
  const state={...feedback,details:'',step:1};
  render(<ReviewContext.Provider value={{app:{command}} as unknown as ReviewState}><FeedbackFlow id="visit" state={state} dismissAttempt={0}/></ReviewContext.Provider>);
  await act(async()=>{});
  fireEvent.changeText(screen.getByLabelText('Details'),'Over limit');fireEvent.changeText(screen.getByLabelText('Details'),'Later edit');
  await act(async()=>first.resolve({...state,details:'Old correction'}));
  expect(formValue('Details')).toBe('Later edit');
  expect(screen.UNSAFE_getAllByType(FormField).find(input=>input.props.title==='Details')?.props.resetRevision??0).toBe(0);
  await act(async()=>second.resolve({...state,details:'Later edit'}));
  expect(formValue('Details')).toBe('Later edit');
});
test('the first feedback edit immediately guards its UIKit owner during delayed diagnostics',async()=>{
  const entry=deferred<null>();
  const command=jest.fn((action:AppCommand)=>action.type==='feedback.enter'?entry.promise:new Promise(()=>{}));
  const state={...feedback,details:'',dirty:false,step:1};
  render(<ReviewContext.Provider value={{app:{command}} as unknown as ReviewState}><FeedbackFlow id="visit" state={state} dismissAttempt={0}/></ReviewContext.Provider>);
  fireEvent.changeText(screen.getByLabelText('Details'),'A');
  expect(command.mock.calls.map(([action])=>action.type)).toEqual(['feedback.enter','foreground.dirty','feedback.change']);
  expect(command).toHaveBeenCalledWith({type:'foreground.dirty',id:'visit',dirty:true});
  fireEvent.changeText(screen.getByLabelText('Details'),'AB');
  expect(command.mock.calls.filter(([action])=>action.type==='foreground.dirty')).toHaveLength(1);
});
test.each(['busy','sent'] as const)('lifecycle refresh does not replay editing fields after native becomes %s',async phase=>{
  const command=jest.fn(async(_action:AppCommand)=>null);const provider=(state:FeedbackState)=><ReviewContext.Provider value={{app:{command}} as unknown as ReviewState}><FeedbackFlow id="visit" state={state} dismissAttempt={0}/></ReviewContext.Provider>;
  const view=render(provider(feedback));await act(async()=>{});
  view.rerender(provider({...feedback,[phase]:true}));command.mockClear();
  const refresh=jest.mocked(AppState.addEventListener).mock.calls.at(-1)![1];
  await act(async()=>refresh('active'));
  expect(command).toHaveBeenCalledWith({type:'feedback.enter',id:'visit'});
  expect(command.mock.calls.some(([action])=>action.type==='feedback.change')).toBe(false);
});
test('catalog filtering receives every edit without echoing a stale controlled text value',()=>{
  jest.replaceProperty(Platform,'OS','android');
  const changes=jest.fn();const view=render(<Search value="" onChange={changes} label="Search DNS providers or transports"/>);
  const input=screen.getByLabelText('Search DNS providers or transports');
  expect(input.props.value).toBeUndefined();
  for(const value of ['C','Cl','Clo','Clou','Cloud','Cloudf','Cloudfl','Cloudfla','Cloudflar','Cloudflare'])fireEvent.changeText(input,value);
  view.rerender(<Search value="Cloudflare" onChange={changes} label="Search DNS providers or transports"/>);
  expect(changes.mock.calls.map(([value])=>value)).toEqual(['C','Cl','Clo','Clou','Cloud','Cloudf','Cloudfl','Cloudfla','Cloudflar','Cloudflare']);
  expect(input.props.value).toBeUndefined();
});
test('a delayed catalog search acknowledgement cannot replace newer native typing',()=>{
  jest.replaceProperty(Platform,'OS','android');
  const ref=createRef<ComponentRef<typeof TextInput>>();const changes=jest.fn();
  const field=(value:string,resetRevision=0)=><Search ref={ref} value={value} resetRevision={resetRevision} onChange={changes} label="Search DNS providers or transports"/>;
  const view=render(field(''));const write=jest.spyOn(ref.current!,'setNativeProps');write.mockClear();
  try{
    const input=screen.getByLabelText('Search DNS providers or transports');
    for(const value of ['C','Cl','Clo','Clou','Cloud','Cloudf','Cloudfl','Cloudfla','Cloudflar','Cloudflare'])fireEvent.changeText(input,value);
    view.rerender(field('Cl'));view.rerender(field('Cloudflare'));
    expect(write).not.toHaveBeenCalled();
    expect(changes.mock.calls.at(-1)).toEqual(['Cloudflare']);
    view.rerender(field('',1));view.rerender(field('',1));
    expect(write.mock.calls).toEqual([[{text:''}]]);
  }finally{write.mockRestore();}
});
test('native Save consumes the latest rename text and emoji after validity stays true',async()=>{
  const command=jest.fn(async(action:AppCommand)=>action.type==='foreground.identity'?{valid:true,dirty:true,message:''}:null);
  const flow={id:'visit',kind:'renameFilter',name:'Core',emoji:'🌱',dismissAttempt:0,canCreate:true,templates:[]};
  render(<ReviewContext.Provider value={{app:{command},live:{foregroundFlow:flow,security:{readRevision:1}}} as unknown as ReviewState}><ForegroundFlowScreen/></ReviewContext.Provider>);
  await act(async()=>{});
  fireEvent.changeText(screen.getByLabelText('Name'),'First edit');await act(async()=>{});
  fireEvent.changeText(screen.getByLabelText('Name'),'Final edit');
  fireEvent(screen.UNSAFE_getByProps({inputLabel:'Emoji'}),'change',{nativeEvent:{text:'🍐'}});await act(async()=>{});
  act(()=>mockNavigation.setOptions.mock.calls.at(-1)![0].unstable_headerRightItems()[0].onPress());await act(async()=>{});
  expect(command).toHaveBeenCalledWith({type:'foreground.submit',id:'visit',name:'Final edit',emoji:'🍐'});
});
test('a retained rename replays a rejected dirty hint only after real AppStore hydration settles, without an own-ACK loop',async()=>{
  const emit=controlledLifecycle();
  const fixture=foregroundStoreFixture({id:'visit',kind:'renameFilter',name:'Core',emoji:'🌱',dismissAttempt:0,canCreate:true,templates:[]},true);
  let rejected=false;const attempts:AppCommand[]=[];
  const adapter={...fixture.app,command:<T,>(action:AppCommand)=>{
    attempts.push(action);
    if(action.type==='foreground.dirty'&&action.dirty&&!rejected){rejected=true;emit('background');}
    return fixture.app.command<T>(action);
  }} as unknown as AppStore;
  const view=render(<StoreForeground app={adapter}/>);
  const hints=()=>fixture.native.command.mock.calls.map(([request])=>JSON.parse(request) as AppCommand).filter(action=>action.type==='foreground.dirty');
  try{
    await act(async()=>{});measureForegroundViewport();fixture.native.command.mockClear();attempts.length=0;
    fireEvent.changeText(screen.getByLabelText('Name'),'Retained private rename');await act(async()=>{});
    expect(attempts).toContainEqual({type:'foreground.dirty',id:'visit',dirty:true});
    expect(hints()).toEqual([]);expect(fixture.state.dirty).toBe(false);
    expect(fixture.app.getSnapshot().snapshot).toBeNull();
    act(()=>emit('active'));++fixture.state.authority;
    await act(async()=>fixture.reads.at(-1)!.resolve(JSON.stringify(fixture.projection())));
    expect(fixture.app.getPresentationHydration().required).toBe(true);expect(hints()).toEqual([]);
    const epoch=fixture.app.getReadEpoch();
    await act(async()=>fixture.app.completePresentationLayout(fixture.app.getPresentationHydration().epoch));
    expect(formValue('Name')).toBe('Retained private rename');
    expect(hints()).toEqual([{type:'foreground.dirty',id:'visit',dirty:true}]);expect(fixture.state.dirty).toBe(true);
    expect(fixture.app.getReadEpoch()).toBeGreaterThan(epoch);
    await act(async()=>{});expect(hints()).toHaveLength(1);
    fireEvent.changeText(screen.getByLabelText('Name'),'Core');await act(async()=>{});
    expect(hints().at(-1)).toEqual({type:'foreground.dirty',id:'visit',dirty:false});expect(fixture.state.dirty).toBe(false);
  }finally{view.unmount();fixture.disconnect();Object.defineProperty(AppState,'currentState',{configurable:true,value:'active'});}
});
test('a batched all-off pause replays unchanged rename dirty metadata with unchanged native authority',async()=>{
  const emit=controlledLifecycle();const fixture=foregroundStoreFixture({id:'visit',kind:'renameFilter',name:'Core',emoji:'🌱',dismissAttempt:0,canCreate:true,templates:[]});
  const view=render(<StoreForeground app={fixture.app}/>);
  try{
    await act(async()=>{});fireEvent.changeText(screen.getByLabelText('Name'),'Same retained rename');await act(async()=>{});
    fixture.native.command.mockClear();
    await act(async()=>{emit('inactive');emit('active');fixture.publish();});
    const hints=fixture.native.command.mock.calls.map(([request])=>JSON.parse(request) as AppCommand).filter(action=>action.type==='foreground.dirty');
    expect(hints).toEqual([{type:'foreground.dirty',id:'visit',dirty:true}]);expect(fixture.state.authority).toBe(1);
    expect(formValue('Name')).toBe('Same retained rename');
  }finally{view.unmount();fixture.disconnect();Object.defineProperty(AppState,'currentState',{configurable:true,value:'active'});}
});
test.each(['hydration','owner','projection','unmount'] as const)('retained rename dirty metadata cannot replay through %s exclusion',async exclusion=>{
  const listeners=new Set<()=>void>();let required=false;
  const flow:ForegroundFlow={id:'visit',kind:'renameFilter',name:'Core',emoji:'🌱',dismissAttempt:0,canCreate:true,templates:[]};
  let owner:ForegroundFlow|null=flow;
  const command=jest.fn(async(action:AppCommand)=>action.type==='foreground.identity'?{valid:true,dirty:false,message:''}:null);
  const app={command,subscribe:(listener:()=>void)=>{listeners.add(listener);return()=>{listeners.delete(listener);};},
    getSnapshot:()=>({snapshot:{foregroundFlow:owner,security:{ownerRevision:'owner',readRevision:1}}}),getPresentationHydration:()=>({required,epoch:1})};
  const view=render(<ReviewContext.Provider value={{app,live:{foregroundFlow:flow,security:{readRevision:1}}} as unknown as ReviewState}><ForegroundFlowScreen/></ReviewContext.Provider>);
  await act(async()=>{});command.mockClear();
  act(()=>{required=true;for(const listener of listeners)listener();fireEvent.changeText(screen.getByLabelText('Name'),'Retained dirty rename');});
  await act(async()=>{});expect(command.mock.calls.some(([action])=>action.type==='foreground.dirty')).toBe(false);
  if(exclusion==='owner')owner={...flow,id:'replacement'};
  else if(exclusion==='projection')owner=null;
  else if(exclusion==='unmount')view.unmount();
  act(()=>{if(exclusion!=='hydration')required=false;for(const listener of listeners)listener();});
  await act(async()=>{});expect(command.mock.calls.some(([action])=>action.type==='foreground.dirty')).toBe(false);
});
test('a null protected VPN projection conceals and retains the same editor until reauthorization',async()=>{
  const command=jest.fn(async(_action:AppCommand)=>null);
  const flow={id:'visit',kind:'vpnConfiguration',name:'',emoji:'',dismissAttempt:0,canCreate:false,templates:[],vpnEditor:vpn};
  const provider=(state:VPNEditorState|null,revision:number)=><ReviewContext.Provider value={{app:{command},live:{foregroundFlow:{...flow,vpnEditor:state},security:{readRevision:revision}}} as unknown as ReviewState}><ForegroundFlowScreen/></ReviewContext.Provider>;
  const view=render(provider(vpn,1));await act(async()=>{});
  fireEvent.changeText(screen.getByLabelText('Name'),'Unsaved name');await act(async()=>{});
  const privateInput=screen.UNSAFE_getByProps({kind:'wireGuard'});command.mockClear();
  view.rerender(provider(null,2));await act(async()=>{});
  expect(screen.getByTestId('vpn-editor-privacy-cover')).toBeTruthy();
  expect(screen.queryByLabelText('Name')).toBeNull();
  expect(screen.UNSAFE_getByProps({kind:'wireGuard'})).toBe(privateInput);
  expect(command).toHaveBeenCalledWith({type:'vpnEditor.enter',id:'visit'});
  view.rerender(provider(vpn,3));await act(async()=>{});
  expect(formValue('Name')).toBe('Unsaved name');
  expect(screen.queryByTestId('vpn-editor-privacy-cover')).toBeNull();
});

test('VPN editor reentry waits for current native authority and can authorize beneath the resume cover',async()=>{
  let authoritative=false;const listeners=new Set<()=>void>();const command=jest.fn(async(_action:AppCommand)=>null);
  const app={command,getSnapshot:()=>({snapshot:authoritative?{}:null}),getPresentationHydration:()=>({required:true}),subscribe:(listener:()=>void)=>{listeners.add(listener);return()=>{listeners.delete(listener);};}};
  const flow={id:'visit',kind:'vpnConfiguration',name:'',emoji:'',dismissAttempt:0,canCreate:false,templates:[],vpnEditor:null};
  render(<ReviewContext.Provider value={{app,live:{foregroundFlow:flow,security:{readRevision:2}}} as unknown as ReviewState}><ForegroundFlowScreen/></ReviewContext.Provider>);
  await act(async()=>{});expect(command).not.toHaveBeenCalled();
  expect(screen.getByTestId('vpn-editor-privacy-cover')).toBeTruthy();
  await act(async()=>{authoritative=true;for(const listener of listeners)listener();});
  expect(command.mock.calls).toEqual([[{type:'vpnEditor.enter',id:'visit'}]]);
});

test('retained library reentry authorizes its exact visit beneath the resume cover after native authority returns',async()=>{
  let authoritative=false;const listeners=new Set<()=>void>();const command=jest.fn(async(action:AppCommand)=>action.type==='foreground.identity'?{valid:true,dirty:false,message:''}:null);
  const app={command,getSnapshot:()=>({snapshot:authoritative?{}:null}),getPresentationHydration:()=>({required:true}),subscribe:(listener:()=>void)=>{listeners.add(listener);return()=>{listeners.delete(listener);};}};
  const flow={id:'visit',kind:'renameFilter',name:'Core',emoji:'🌱',dismissAttempt:0,canCreate:true,templates:[]};
  render(<ReviewContext.Provider value={{app,live:{foregroundFlow:flow,security:{readRevision:2}}} as unknown as ReviewState}><ForegroundFlowScreen/></ReviewContext.Provider>);
  await act(async()=>{});expect(command.mock.calls.some(([action])=>action.type==='foreground.enter')).toBe(false);
  await act(async()=>{authoritative=true;for(const listener of listeners)listener();});
  expect(command.mock.calls.filter(([action])=>action.type==='foreground.enter')).toEqual([[{type:'foreground.enter',id:'visit'}]]);
});

test.each(['createFilter','renameFilter','deleteFilters'] as const)('revoked %s has an explicit retry after cancelled authorization without replacing its draft',async kind=>{
  const command=jest.fn(async(action:AppCommand)=>{
    if(action.type==='foreground.enter')throw new Error('Authentication cancelled.');
    return action.type==='foreground.identity'?{valid:true,dirty:false,message:''}:null;
  });
  const app={command};
  const flow={id:'visit',kind,name:'Core',emoji:'🌱',dismissAttempt:0,canCreate:true,templates:[]};
  const provider=(authorized:boolean,revision:number)=><ReviewContext.Provider value={{app,live:{foregroundFlow:authorized?flow:null,security:{readRevision:revision}}} as unknown as ReviewState}><ForegroundFlowScreen/></ReviewContext.Provider>;
  const view=render(provider(true,1));await act(async()=>{});
  if(kind==='renameFilter')fireEvent.changeText(screen.getByLabelText('Name'),'Retained private rename');
  await act(async()=>{});command.mockClear();
  view.rerender(provider(false,2));await act(async()=>{});
  expect(screen.getByTestId('foreground-flow-privacy-cover')).toBeTruthy();
  expect(screen.queryByLabelText('Name')).toBeNull();
  expect(command.mock.calls.filter(([action])=>action.type==='foreground.enter')).toEqual([[{type:'foreground.enter',id:'visit'}]]);
  fireEvent.press(screen.getByText('Unlock Lava'));await act(async()=>{});
  expect(command.mock.calls.filter(([action])=>action.type==='foreground.enter')).toHaveLength(2);
  expect(screen.getByTestId('foreground-flow-privacy-cover')).toBeTruthy();
  expect(command.mock.calls.some(([action])=>['foreground.submit','foreground.dismiss'].includes(action.type))).toBe(false);
  view.rerender(provider(true,3));await act(async()=>{});
  expect(screen.queryByTestId('foreground-flow-privacy-cover')).toBeNull();
  if(kind==='renameFilter')expect(formValue('Name')).toBe('Retained private rename');
});

test('form typing never echoes text into the native buffer and an external import resets it once',()=>{
  jest.replaceProperty(Platform,'OS','android');
  const ref=createRef<ComponentRef<typeof TextInput>>();const changes=jest.fn();
  const field=(value:string,resetRevision=0)=><FormField ref={ref} title="Name" value={value} resetRevision={resetRevision} onChangeText={changes}/>;
  const view=render(field(''));const write=jest.spyOn(ref.current!,'setNativeProps');write.mockClear();
  try{
    const input=screen.getByLabelText('Name');
    const text='Retained protected DNS draft';
    for(let length=1;length<=text.length;length++){
      const value=text.slice(0,length);fireEvent.changeText(input,value);view.rerender(field(value));
    }
    // An older render can acknowledge a prefix after newer native edits arrive.
    view.rerender(field('Reta'));view.rerender(field(text));
    expect(changes.mock.calls.map(([value])=>value)).toEqual(Array.from({length:text.length},(_,i)=>text.slice(0,i+1)));
    expect(input.props.value).toBeUndefined();expect(input.props.defaultValue).toBe('');expect(write).not.toHaveBeenCalled();
    view.rerender(field('Imported configuration',1));
    expect(write.mock.calls).toEqual([[{text:'Imported configuration'}]]);
    view.rerender(field('Imported configuration',1));expect(write).toHaveBeenCalledTimes(1);
  }finally{write.mockRestore();}
});

test('the iOS form adapter forwards native committed edits and uses the app text override',()=>{
  const changed=jest.fn();
  render(<PresentationContext.Provider value={{locale:'en',textScales:{body:2}}}>
    <FormField title="Details" value="Initial draft" resetRevision={2} characterLimit={5000} multiline grows minHeight={96} onChangeText={changed}/>
  </PresentationContext.Provider>);
  const input=()=>screen.UNSAFE_getAllByType(View).find(view=>view.props.inputLabel==='Details')!;
  expect(input().props).toMatchObject({kind:'prose',value:'Initial draft',resetRevision:2,characterLimit:5000,editable:true,fontPointSize:34,lineHeight:44,autoCorrect:true,autoCapitalize:'sentences',spellCheck:true,smartInsertDelete:true});
  fireEvent(input(),'change',{nativeEvent:{text:'Committed newer draft'}});
  expect(changed.mock.calls).toEqual([['Committed newer draft']]);
  act(()=>input().props.onSizeChange({nativeEvent:{height:238}}));
  expect(input().props.style).toEqual(expect.arrayContaining([{height:238}]));
});

test('feedback counter matches native caption digits and the localized accessible count',()=>{
  render(<CharacterCounter count={5000} limit={5000}/>);
  const counter=screen.getByLabelText('5,000 of 5,000 characters used');
  expect(counter.props.children).toBe('5,000/5,000');
  expect(counter.props.dynamicTypeRamp).toBe('caption2');
  expect(counter.props.style).toMatchObject({fontSize:11,fontVariant:['tabular-nums']});
});

test('feedback coalesces a typing burst and Review waits for the final native draft',async()=>{
  const entry=deferred<null>(),first=deferred<FeedbackState>(),last=deferred<FeedbackState>();
  let edits=0;
  const state={...feedback,details:'',count:0,step:1,prepared:false};
  const command=jest.fn((action:AppCommand)=>action.type==='feedback.enter'?entry.promise:
    action.type==='feedback.change'&&action.field==='details'?(++edits===1?first.promise:last.promise):Promise.resolve(null));
  render(<ReviewContext.Provider value={{app:{command}} as unknown as ReviewState}><FeedbackFlow id="visit" state={state} dismissAttempt={0}/></ReviewContext.Provider>);
  for(let count=1;count<=100;count++)fireEvent.changeText(screen.getByLabelText('Details'),'a'.repeat(count));
  expect(command.mock.calls.filter(([action])=>action.type==='feedback.change')).toHaveLength(1);
  fireEvent.press(screen.getByRole('button',{name:'Review'}));
  fireEvent.press(screen.getByRole('button',{name:'Review'}));
  expect(command.mock.calls.some(([action])=>action.type==='feedback.step')).toBe(false);
  await act(async()=>first.resolve({...state,details:'a',count:1}));
  expect(command.mock.calls.filter(([action])=>action.type==='feedback.change').map(([action])=>(action as {value:string}).value)).toEqual(['a','a'.repeat(100)]);
  expect(command.mock.calls.some(([action])=>action.type==='feedback.step')).toBe(false);
  await act(async()=>last.resolve({...state,details:'a'.repeat(100),count:100}));
  expect(command.mock.calls.at(-1)).toEqual([{type:'feedback.step',id:'visit',next:true}]);
  expect(command.mock.calls.filter(([action])=>action.type==='feedback.step')).toHaveLength(1);
});

test('retiring feedback cannot replay a coalesced edit when its old acknowledgement arrives',async()=>{
  const entry=deferred<null>(),write=deferred<FeedbackState>();const state={...feedback,details:'',step:1};
  const command=jest.fn((action:AppCommand)=>action.type==='feedback.enter'?entry.promise:action.type==='feedback.change'?write.promise:Promise.resolve(null));
  const view=render(<ReviewContext.Provider value={{app:{command}} as unknown as ReviewState}><FeedbackFlow id="visit" state={state} dismissAttempt={0}/></ReviewContext.Provider>);
  fireEvent.changeText(screen.getByLabelText('Details'),'A');fireEvent.changeText(screen.getByLabelText('Details'),'AB');
  view.unmount();await act(async()=>write.resolve({...state,details:'A'}));
  expect(command.mock.calls.filter(([action])=>action.type==='feedback.change')).toHaveLength(1);
});

test('a failed feedback write retains the draft and retries its latest value before Review',async()=>{
  const entry=deferred<null>();const state={...feedback,details:'',step:1};let fail=true;
  const command=jest.fn(async(action:AppCommand)=>{
    if(action.type==='feedback.enter')return entry.promise;
    if(action.type==='feedback.change'){if(fail)throw new Error('Read access changed.');return {...state,[action.field]:action.value};}
    return null;
  });
  render(<ReviewContext.Provider value={{app:{command}} as unknown as ReviewState}><FeedbackFlow id="visit" state={state} dismissAttempt={0}/></ReviewContext.Provider>);
  fireEvent.changeText(screen.getByLabelText('Details'),'Retained suggestion');await act(async()=>{});
  expect(formValue('Details')).toBe('Retained suggestion');
  fireEvent.press(screen.getByRole('button',{name:'Review'}));await act(async()=>{});
  expect(command.mock.calls.some(([action])=>action.type==='feedback.step')).toBe(false);
  fail=false;fireEvent.press(screen.getByRole('button',{name:'Review'}));await act(async()=>{});
  expect(command.mock.calls.at(-2)).toEqual([{type:'feedback.change',id:'visit',field:'details',value:'Retained suggestion'}]);
  expect(command.mock.calls.at(-1)).toEqual([{type:'feedback.step',id:'visit',next:true}]);
});

test('retiring feedback during Review cannot advance after its native field drain finishes',async()=>{
  const entry=deferred<null>(),write=deferred<FeedbackState>();const state={...feedback,details:'',step:1};
  const command=jest.fn((action:AppCommand)=>action.type==='feedback.enter'?entry.promise:action.type==='feedback.change'?write.promise:Promise.resolve(null));
  const view=render(<ReviewContext.Provider value={{app:{command}} as unknown as ReviewState}><FeedbackFlow id="visit" state={state} dismissAttempt={0}/></ReviewContext.Provider>);
  fireEvent.changeText(screen.getByLabelText('Details'),'Final suggestion');
  fireEvent.press(screen.getByRole('button',{name:'Review'}));view.unmount();
  await act(async()=>write.resolve({...state,details:'Final suggestion'}));
  expect(command.mock.calls.some(([action])=>action.type==='feedback.step')).toBe(false);
});

test('Review waits for the editor to commit composition before draining its final text',async()=>{
  const entry=deferred<null>();const state={...feedback,details:'',step:1};
  const command=jest.fn(async(action:AppCommand)=>action.type==='feedback.enter'?entry.promise:
    action.type==='feedback.change'?{...state,[action.field]:action.value}:null);
  render(<ReviewContext.Provider value={{app:{command}} as unknown as ReviewState}><FeedbackFlow id="visit" state={state} dismissAttempt={0}/></ReviewContext.Provider>);
  const input=screen.UNSAFE_getByProps({inputLabel:'Details'});
  fireEvent(input,'focusChange',{nativeEvent:{focused:true}});
  fireEvent(input,'change',{nativeEvent:{text:'Earlier committed text'}});await act(async()=>{});
  fireEvent.press(screen.getByRole('button',{name:'Review'}));await act(async()=>{});
  expect(command.mock.calls.some(([action])=>action.type==='feedback.step')).toBe(false);
  expect(screen.UNSAFE_getByProps({inputLabel:'Details'}).props.editable).toBe(false);
  // UIKit ends marked composition and reports final text before the blur event.
  fireEvent(input,'change',{nativeEvent:{text:'Earlier committed text 日本語'}});
  fireEvent(input,'focusChange',{nativeEvent:{focused:false}});await act(async()=>{});
  expect(command.mock.calls.at(-2)).toEqual([{type:'feedback.change',id:'visit',field:'details',value:'Earlier committed text 日本語'}]);
  expect(command.mock.calls.at(-1)).toEqual([{type:'feedback.step',id:'visit',next:true}]);
});

test('retiring a focused feedback editor releases its wait without advancing Review',async()=>{
  const entry=deferred<null>();const state={...feedback,details:'',step:1};
  const command=jest.fn(async(action:AppCommand)=>action.type==='feedback.enter'?entry.promise:null);
  const view=render(<ReviewContext.Provider value={{app:{command}} as unknown as ReviewState}><FeedbackFlow id="visit" state={state} dismissAttempt={0}/></ReviewContext.Provider>);
  fireEvent(screen.UNSAFE_getByProps({inputLabel:'Details'}),'focusChange',{nativeEvent:{focused:true}});
  fireEvent.press(screen.getByRole('button',{name:'Review'}));view.unmount();await act(async()=>{});
  expect(command.mock.calls.some(([action])=>action.type==='feedback.step')).toBe(false);
});

test('preview commits focused composition before removing the editor and Back can still Review',async()=>{
  const entry=deferred<null>();const state={...feedback,details:'',step:1};
  const command=jest.fn(async(action:AppCommand)=>action.type==='feedback.enter'?entry.promise:
    action.type==='feedback.change'?{...state,[action.field]:action.value}:
      action.type==='feedback.preview'?[{id:'sample',title:'Technical summary',purpose:'Example',items:[]}]:null);
  render(<ReviewContext.Provider value={{app:{command}} as unknown as ReviewState}><FeedbackFlow id="visit" state={state} dismissAttempt={0}/></ReviewContext.Provider>);
  const input=screen.UNSAFE_getByProps({inputLabel:'Details'});
  fireEvent(input,'focusChange',{nativeEvent:{focused:true}});
  fireEvent(input,'change',{nativeEvent:{text:'Earlier text'}});await act(async()=>{});
  fireEvent.press(screen.getByRole('link',{name:'See what information is sent'}));
  fireEvent.press(screen.getByRole('link',{name:'See what information is sent'}));await act(async()=>{});
  expect(command.mock.calls.some(([action])=>action.type==='feedback.preview')).toBe(false);
  expect(screen.UNSAFE_getByProps({inputLabel:'Details'}).props.editable).toBe(false);
  fireEvent(input,'change',{nativeEvent:{text:'Earlier text 日本語'}});
  fireEvent(input,'focusChange',{nativeEvent:{focused:false}});await act(async()=>{});
  expect(command.mock.calls.at(-2)).toEqual([{type:'feedback.change',id:'visit',field:'details',value:'Earlier text 日本語'}]);
  expect(command.mock.calls.at(-1)).toEqual([{type:'feedback.preview',id:'visit'}]);
  expect(command.mock.calls.filter(([action])=>action.type==='feedback.preview')).toHaveLength(1);
  expect(screen.queryByLabelText('Details')).toBeNull();
  act(()=>mockNavigation.setOptions.mock.calls.at(-1)![0].unstable_headerLeftItems()[0].onPress());
  expect(formValue('Details')).toBe('Earlier text 日本語');
  fireEvent.press(screen.getByRole('button',{name:'Review'}));await act(async()=>{});
  expect(command.mock.calls.at(-1)).toEqual([{type:'feedback.step',id:'visit',next:true}]);
  expect(screen.getByRole('button',{name:'Review'}).props.accessibilityState.disabled).toBe(false);
});

test('retiring feedback during its focused preview transition cannot request diagnostic examples',async()=>{
  const entry=deferred<null>();const state={...feedback,details:'',step:1};
  const command=jest.fn(async(action:AppCommand)=>action.type==='feedback.enter'?entry.promise:null);
  const view=render(<ReviewContext.Provider value={{app:{command}} as unknown as ReviewState}><FeedbackFlow id="visit" state={state} dismissAttempt={0}/></ReviewContext.Provider>);
  fireEvent(screen.UNSAFE_getByProps({inputLabel:'Details'}),'focusChange',{nativeEvent:{focused:true}});
  fireEvent.press(screen.getByRole('link',{name:'See what information is sent'}));view.unmount();await act(async()=>{});
  expect(command.mock.calls.some(([action])=>action.type==='feedback.preview')).toBe(false);
});

test('feedback diagnostics switch uses the native headline text ramp without changing ordinary row typography',()=>{
  const command=jest.fn(async(_action:AppCommand)=>null);
  render(<PresentationContext.Provider value={{locale:'en',textScales:{headline:1.8,subheadline:1.2}}}><ReviewContext.Provider value={{app:{command}} as unknown as ReviewState}><FeedbackFlow id="visit" state={{...feedback,step:1}} dismissAttempt={0}/></ReviewContext.Provider></PresentationContext.Provider>);
  expect(screen.getByText('Include optional diagnostics')).toHaveStyle({fontSize:30.6,fontWeight:'600'});
});

test.each([false,true])('diagnostics preview retains native explanations and lifecycle examples (empty=%s)',async empty=>{
  const previews=empty?[]:[{id:'app',title:'App & Device',purpose:'This helps reproduce bugs tied to a specific app build, iOS version, or device family.',items:[{label:'App version',value:'2.0.2'},{label:'Locale',value:'en_US'}]}];
  const command=jest.fn(async(action:AppCommand)=>action.type==='feedback.preview'?previews:null);
  render(<ReviewContext.Provider value={{app:{command}} as unknown as ReviewState}><FeedbackFlow id="visit" state={{...feedback,step:1}} dismissAttempt={0}/></ReviewContext.Provider>);
  fireEvent.press(screen.getByRole('link',{name:'See what information is sent'}));await act(async()=>{});
  expect(screen.getByRole('header',{name:'Information sent'})).toBeOnTheScreen();
  expect(screen.getByRole('header',{name:'Lifecycle log examples'})).toBeOnTheScreen();
  expect(screen.getByText('enable-begin, enable-finished, reconnect-requested')).toBeOnTheScreen();
  expect(screen.getByText('startTunnel-ready, network-path-changed, resolver-reset')).toBeOnTheScreen();
  expect(screen.getByText('Lifecycle entries use safe event names and counters. Recent DNS and domain events are not included.')).toBeOnTheScreen();
  expect(screen.queryByLabelText('Details')).toBeNull();
  if(empty)expect(screen.getByText(localized('Lava will show App & Device, VPN Status, Tunnel Lifecycle, Network & Resolver Health, Filter Snapshot, and Local Activity Summary when a local summary is ready.'))).toBeOnTheScreen();
  else{
    expect(screen.getByLabelText('App version, 2.0.2')).toBeOnTheScreen();
    expect(screen.getByLabelText('Locale, en_US')).toBeOnTheScreen();
  }
});

test('localized action widths switch the entire footer group without clipping a long label',()=>{
  const actions=<FormActions titles={['Choose File','Save']} children={[<View testID="file-action"/>,<View testID="save-action"/>]}/>;
  render(actions);
  const root=screen.UNSAFE_getByType(FormActions).findByType(View);
  fireEvent(root,'layout',{nativeEvent:{layout:{width:320,height:44}}});
  fireEvent(screen.getByText('Choose file',{includeHiddenElements:true}),'textLayout',{nativeEvent:{lines:[{width:210}]}});
  fireEvent(screen.getByText('Save',{includeHiddenElements:true}),'textLayout',{nativeEvent:{lines:[{width:90}]}});
  const direction=(id:string)=>{let parent=screen.getByTestId(id).parent;while(parent&&parent.props.style?.flexDirection===undefined)parent=parent.parent;return parent?.props.style.flexDirection;};
  expect(direction('file-action')).toBe('column');
  expect(direction('save-action')).toBe('column');
  fireEvent(root,'layout',{nativeEvent:{layout:{width:600,height:44}}});
  expect(direction('file-action')).toBe('row');
  expect(direction('save-action')).toBe('row');
});
