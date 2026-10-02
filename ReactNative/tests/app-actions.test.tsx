import type {PropsWithChildren} from 'react';
import {AccessibilityInfo, Alert, AppState, type AppStateStatus} from 'react-native';
import {act, renderHook} from '@testing-library/react-native';
import {useAppAction} from '../app/actions';
import {ReviewContext, type ReviewState} from '../review/ReviewContext';
import {AppStore} from '../app/store';
import {Alert as PresentationAlert} from '../app/presentation';
import type {AppSnapshot} from '../app/contract';
import type {Spec} from '../specs/NativeLavaApp';
jest.mock('@react-navigation/native',()=>({useNavigation:jest.fn()}));

function setup(){
  let resolve!:(value:string)=>void;let reject!:(error:Error)=>void;
  const command=jest.fn(()=>new Promise<string>((yes,no)=>{resolve=yes;reject=no;}));
  const app={command} as unknown as AppStore;
  const wrapper=({children}:PropsWithChildren)=><ReviewContext.Provider value={{app} as ReviewState}>{children}</ReviewContext.Provider>;
  return {...renderHook(()=>useAppAction(),{wrapper}),resolve:(value:string)=>resolve(value),reject:(error:Error)=>reject(error)};
}
test.each(['Clear filtering counts','Clear domain history','Clear network activity','Clear Lava Guard progress','Clear all logs'])('announces %s only after native success, using the native localized confirmation',async kind=>{
  const announce=jest.spyOn(AccessibilityInfo,'announceForAccessibility').mockImplementation(()=>{});
  const {result,resolve}=setup();
  act(()=>{void result.current({type:'logs.clear',kind});});
  expect(announce).not.toHaveBeenCalled();
  await act(async()=>resolve('Native localized completion'));
  expect(announce).toHaveBeenCalledTimes(1);expect(announce).toHaveBeenCalledWith('Native localized completion');
  announce.mockRestore();
});
test('a failed clear never announces completion',async()=>{
  const announce=jest.spyOn(AccessibilityInfo,'announceForAccessibility').mockImplementation(()=>{});
  const alert=jest.spyOn(Alert,'alert').mockImplementation(()=>{});
  const {result,reject}=setup();
  act(()=>{void result.current({type:'logs.clear',kind:'Clear all logs'});});
  await act(async()=>reject(new Error('Could not persist this change.')));
  expect(announce).not.toHaveBeenCalled();
  expect(alert).toHaveBeenCalled();
  announce.mockRestore();alert.mockRestore();
});

const deferred=<T,>()=>{let resolve!:(value:T)=>void;const promise=new Promise<T>(yes=>{resolve=yes;});return {promise,resolve};};
function runtimeSetup(){
  const originalState=AppState.currentState;AppState.currentState='active';
  let lifecycle!:(state:AppStateStatus)=>void;
  const listen=jest.spyOn(AppState,'addEventListener').mockImplementation((_event,listener)=>{lifecycle=listener;return {remove(){}};});
  const snapshot=(revision:number)=>({schema:1,fullApp:true,revision,backgroundPrivacyCoverRequired:false} as AppSnapshot);
  let fresh=snapshot(1);
  const native={getSnapshot:jest.fn(async()=>JSON.stringify(fresh)),onSnapshot:()=>({remove(){}}),
    command:jest.fn(async(_request:string)=>JSON.stringify({snapshot:fresh,result:null}))};
  const app=new AppStore(native as Spec,fresh);const disconnect=app.connect();
  const wrapper=({children}:PropsWithChildren)=><ReviewContext.Provider value={{app} as ReviewState}>{children}</ReviewContext.Provider>;
  const hook=renderHook(()=>useAppAction(),{wrapper});
  return {app,native,...hook,snapshot,move:(state:AppStateStatus)=>{AppState.currentState=state;lifecycle(state);},
    setFresh:(value:AppSnapshot)=>{fresh=value;},finish:()=>{hook.unmount();disconnect();listen.mockRestore();AppState.currentState=originalState;}};
}
test('a queued mutation revoked by backgrounding is cancelled without a custom-title error alert',async()=>{
  const harness=runtimeSetup();const alert=jest.spyOn(Alert,'alert').mockImplementation(()=>{});
  try{
    await act(async()=>{});
    const firstReply=deferred<string>();harness.native.command.mockReturnValueOnce(firstReply.promise);
    const first=harness.app.command({type:'settings.set',key:'haptics',value:false});
    let cancellation:Error|undefined;
    const queued=harness.app.command({type:'settings.set',key:'deviceDNS',value:true}).catch(error=>{
      cancellation=error;PresentationAlert.alert("Couldn't save",error.message);
    });
    await act(async()=>{});expect(harness.native.command).toHaveBeenCalledTimes(1);
    act(()=>harness.move('inactive'));
    await act(async()=>{firstReply.resolve(JSON.stringify({snapshot:harness.snapshot(2),result:null}));await Promise.all([first,queued]);});
    expect(cancellation?.message).toBe('Read access changed.');
    expect(harness.native.command).toHaveBeenCalledTimes(1);
    expect(alert).not.toHaveBeenCalled();
  }finally{harness.finish();alert.mockRestore();}
});
test('an overtaken native read is quietly cancelled even after fresh foreground authority is restored',async()=>{
  const harness=runtimeSetup();const alert=jest.spyOn(Alert,'alert').mockImplementation(()=>{});
  try{
    await act(async()=>{});
    const reply=deferred<string>();harness.native.command.mockReturnValueOnce(reply.promise);
    let reading:ReturnType<ReturnType<typeof useAppAction>>;
    act(()=>{reading=harness.result.current({type:'share.query',id:'one'});});
    const oldEpoch=harness.app.getReadEpoch();
    act(()=>harness.move('inactive'));harness.setFresh(harness.snapshot(3));
    await act(async()=>harness.move('active'));
    act(()=>harness.app.completePresentationLayout(harness.app.getPresentationHydration().epoch));
    expect(harness.app.getReadEpoch()).toBeGreaterThan(oldEpoch);
    expect(harness.app.getSnapshot().snapshot?.revision).toBe(3);
    expect(harness.app.getPresentationHydration().required).toBe(false);
    await act(async()=>{reply.resolve(JSON.stringify({snapshot:harness.snapshot(2),result:{code:'old-private-code'}}));await reading;});
    expect(harness.app.getSnapshot().snapshot?.revision).toBe(3);
    expect(alert).not.toHaveBeenCalled();
    harness.native.command.mockRejectedValueOnce(new Error('Could not persist this change.'));
    await act(async()=>{await harness.result.current({type:'settings.set',key:'haptics',value:false});});
    expect(alert).toHaveBeenCalledWith('Lava','Could not persist this change.',undefined,undefined);
  }finally{harness.finish();alert.mockRestore();}
});
