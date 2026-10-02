import {useSyncExternalStore, type PropsWithChildren} from 'react';
import {AppState} from 'react-native';
import {act, renderHook} from '@testing-library/react-native';
import {useAppQuery} from '../app/queries';
import {ReviewContext, type ReviewState} from '../review/ReviewContext';
import {AppStore} from '../app/store';
import type {AppCommand, AppSnapshot} from '../app/contract';
import type {Spec} from '../specs/NativeLavaApp';
import {clearAppReadCache, mayCacheRead} from '../app/read-cache';
import {initialSession} from '../review/session';

let mockFocused=true;
jest.mock('@react-navigation/native',()=>({useIsFocused:()=>mockFocused}));
const originalState=AppState.currentState;
beforeAll(()=>Object.defineProperty(AppState,'currentState',{configurable:true,value:'active'}));
afterAll(()=>Object.defineProperty(AppState,'currentState',{configurable:true,value:originalState}));
const deferred=<T,>()=>{let resolve!:(value:T)=>void;let reject!:(error:Error)=>void;const promise=new Promise<T>((yes,no)=>{resolve=yes;reject=no;});return {resolve,reject,promise};};
const blocked:AppCommand={type:'domains.query',history:true,decision:'Blocked',search:'',limit:31};
function setup(retainThroughInactivity=false,cacheable=false,initialCommand:AppCommand=blocked,optOut=false){
  const requests:ReturnType<typeof deferred<string[]>>[]=[];
  const command=jest.fn(()=>{const request=deferred<string[]>();requests.push(request);return request.promise;});
  const app={command,subscribe:()=>()=>{},getInvalidation:()=>0} as unknown as AppStore;
  const live=cacheable?{backgroundPrivacyCoverRequired:optOut?false:undefined,session:initialSession(),security:{unavailable:false,sourceRevision:'owner-and-clear-1'},account:{signedIn:false,status:'',detail:''}}:undefined;
  const wrapper=({children}:PropsWithChildren)=><ReviewContext.Provider value={{app,live} as ReviewState}>{children}</ReviewContext.Provider>;
  const hook=renderHook(({command,scope}:{command:AppCommand|null;scope:string})=>useAppQuery<string[]>(command,scope,retainThroughInactivity),{wrapper,initialProps:{command:initialCommand as AppCommand|null,scope:'blocked'}});
  return {...hook,requests,command,app,wrapper,live,unmountScreen:hook.unmount,unmount:()=>{hook.unmount();clearAppReadCache(app);}};
}
test('pagination retains rows and late older pages cannot replace the newest reply',async()=>{
  const {result,rerender,requests}=setup();
  await act(async()=>requests[0]!.resolve(['one']));
  rerender({command:{...blocked,limit:61},scope:'blocked'});
  expect(result.current.value).toEqual(['one']);expect(result.current.refreshing).toBe(true);
  rerender({command:{...blocked,limit:91},scope:'blocked'});
  await act(async()=>requests[2]!.resolve(['one','two','three']));
  await act(async()=>requests[1]!.resolve(['one','two']));
  expect(result.current.value).toEqual(['one','two','three']);expect(result.current.refreshing).toBe(false);
});
test('changing the data scope or disabling logs clears retained rows immediately',async()=>{
  const {result,rerender,requests}=setup();
  await act(async()=>requests[0]!.resolve(['blocked.example']));
  rerender({command:{...blocked,decision:'Allowed'},scope:'allowed'});
  expect(result.current.value).toBeUndefined();
  await act(async()=>requests[1]!.resolve(['allowed.example']));
  expect(result.current.value).toEqual(['allowed.example']);
  rerender({command:null,scope:'allowed'});
  expect(result.current.value).toBeUndefined();
});
test('changing the retained identity clears rows even when the command is identical',async()=>{
  const {result,rerender,requests}=setup();
  await act(async()=>requests[0]!.resolve(['old-filter.example']));
  rerender({command:blocked,scope:'another-filter'});
  expect(result.current.value).toBeUndefined();
  await act(async()=>requests[1]!.resolve(['new-filter.example']));
  expect(result.current.value).toEqual(['new-filter.example']);
});
test('an authentication rejection clears retained values instead of masking the error',async()=>{
  const {result,rerender,requests}=setup();
  await act(async()=>requests[0]!.resolve(['one']));
  rerender({command:{...blocked,limit:61},scope:'blocked'});
  await act(async()=>requests[1]!.reject(new Error('Authentication cancelled.')));
  expect(result.current.value).toBeUndefined();expect(result.current.error).toBe('Authentication cancelled.');
});
test('cancelling authentication stops timed prompts until the query scope changes',async()=>{
  jest.useFakeTimers();
  try {
    const {result,rerender,requests,command,unmount}=setup();
    await act(async()=>requests[0]!.reject(new Error('Authentication cancelled.')));
    await act(async()=>jest.advanceTimersByTime(30000));
    expect(command).toHaveBeenCalledTimes(1);
    expect(result.current.error).toBe('Authentication cancelled.');
    rerender({command:{...blocked,decision:'Allowed'},scope:'allowed'});
    expect(command).toHaveBeenCalledTimes(2);
    await act(async()=>requests[1]!.resolve(['allowed.example']));
    expect(result.current.value).toEqual(['allowed.example']);
    unmount();
  } finally {jest.useRealTimers();}
});
test('ordinary transient query failures retain the periodic retry',async()=>{
  jest.useFakeTimers();
  try {
    const {requests,command,unmount}=setup();
    await act(async()=>requests[0]!.reject(new Error('Temporary read failure.')));
    await act(async()=>jest.advanceTimersByTime(5000));
    expect(command).toHaveBeenCalledTimes(2);
    unmount();
  } finally {jest.useRealTimers();}
});

test('explicit refresh can retry cancelled authentication without overlapping a pending request',async()=>{
  const {result,requests,command,unmount}=setup();
  await act(async()=>requests[0]!.reject(new Error('Authentication cancelled.')));
  let retry!:Promise<void>;
  act(()=>{retry=result.current.refresh();void result.current.refresh();});
  expect(command).toHaveBeenCalledTimes(2);
  await act(async()=>{requests[1]!.resolve(['fresh.example']);await retry;});
  expect(result.current.value).toEqual(['fresh.example']);
  expect(result.current.error).toBeUndefined();
  unmount();
  await act(async()=>result.current.refresh());
  expect(command).toHaveBeenCalledTimes(2);
});

function lifecycle() {
  const listeners=new Set<(state:import('react-native').AppStateStatus)=>void>();
  const originalListener=AppState.addEventListener;
  AppState.addEventListener=(_event,listener)=>{
    const callback=listener as (state:import('react-native').AppStateStatus)=>void;
    listeners.add(callback);return {remove:()=>{listeners.delete(callback);}};
  };
  return {
    emit(state:import('react-native').AppStateStatus) {
      act(()=>{Object.defineProperty(AppState,'currentState',{configurable:true,value:state});for(const listener of listeners)listener(state);});
    },
    restore(){AppState.addEventListener=originalListener;Object.defineProperty(AppState,'currentState',{configurable:true,value:'active'});},
  };
}

const activity:AppCommand={type:'activity.query',start:100,end:200};
const network:AppCommand={type:'network.query'};
const stats:AppCommand={type:'stats.query'};
const catalog:AppCommand={type:'catalog.query',ids:['balanced']};
const retainedReads=[activity,network,stats,blocked,{...blocked,history:false},catalog];
test.each(retainedReads)('$type drops private render data on every app interruption and reads native on return',async(query)=>{
  const events=lifecycle();jest.useFakeTimers();
  try {
    const {result,requests,command,unmount}=setup(false,true,query);
    await act(async()=>requests[0]!.resolve(['2,124']));
    for (let i=1;i<=2;i++) {
      events.emit('inactive');expect(result.current.value).toBeUndefined();
      events.emit('background');expect(result.current.value).toBeUndefined();
      await act(async()=>jest.advanceTimersByTime(10000));
      expect(command).toHaveBeenCalledTimes(i);
      events.emit('active');expect(result.current.value).toBeUndefined();
      expect(command).toHaveBeenCalledTimes(i+1);
      await act(async()=>requests[i]!.resolve(['2,124']));
    }
    unmount();
  } finally {events.restore();jest.useRealTimers();}
});
test.each(retainedReads)('$type discards both prior content and an interrupted late refresh',async(query)=>{
  const events=lifecycle();
  try {
    const {result,requests,command,unmount}=setup(false,true,query);
    await act(async()=>requests[0]!.resolve(['2,124']));
    act(()=>{void result.current.refresh();});
    events.emit('inactive');events.emit('active');
    expect(command).toHaveBeenCalledTimes(2);
    await act(async()=>requests[1]!.resolve(['interrupted']));
    expect(result.current.value).toBeUndefined();
    expect(command).toHaveBeenCalledTimes(3);
    await act(async()=>requests[2]!.resolve(['2,130']));
    expect(result.current.value).toEqual(['2,130']);
    unmount();
  } finally {events.restore();}
});
test.each(retainedReads)('$type ignores an interrupted refresh error and waits for a newly authorized result',async(query)=>{
  const events=lifecycle();
  try {
    const {result,requests,command,unmount}=setup(false,true,query);
    await act(async()=>requests[0]!.resolve(['accepted']));
    act(()=>{void result.current.refresh();});
    events.emit('inactive');events.emit('active');
    await act(async()=>requests[1]!.reject(new Error('Interrupted native read')));
    expect(result.current.value).toBeUndefined();
    expect(result.current.error).toBeUndefined();
    expect(command).toHaveBeenCalledTimes(3);
    await act(async()=>requests[2]!.resolve(['fresh']));
    expect(result.current.value).toEqual(['fresh']);
    unmount();
  } finally {events.restore();}
});
test('Activity cannot retain a summary after its date range or privacy scope changes while inactive',async()=>{
  const events=lifecycle();
  try {
    const {result,rerender,requests,live,unmount}=setup(false,true,activity);
    await act(async()=>requests[0]!.resolve(['2,124']));
    events.emit('inactive');
    rerender({command:{...activity,start:200,end:300},scope:'next-day'});
    expect(result.current.value).toBeUndefined();
    events.emit('active');
    await act(async()=>requests[1]!.resolve(['3,000']));
    events.emit('inactive');
    live!.session.protectedActions['View Activities']=true;
    rerender({command:{...activity,start:200,end:300},scope:'next-day'});
    expect(result.current.value).toBeUndefined();
    events.emit('active');
    expect(result.current.value).toBeUndefined();
    await act(async()=>requests[2]!.reject(new Error('Authentication cancelled.')));
    expect(result.current.value).toBeUndefined();
    unmount();
  } finally {events.restore();}
});
test.each(retainedReads)('$type with unknown authorization still clears on inactivity',async(query)=>{
  const events=lifecycle();
  try {
    const {result,requests,unmount}=setup(true,false,query);
    await act(async()=>requests[0]!.resolve(['private-summary']));
    events.emit('inactive');expect(result.current.value).toBeUndefined();
    events.emit('active');expect(result.current.value).toBeUndefined();
    await act(async()=>requests[1]!.resolve(['fresh-summary']));
    expect(result.current.value).toEqual(['fresh-summary']);
    unmount();
  } finally {events.restore();}
});
test.each(retainedReads.flatMap(query=>['account','logs','locked-storage','revoked-read','protected'].map(change=>({query,change}))))('$query.type cannot replay after $change changes during an interruption',async({query,change})=>{
  const events=lifecycle();
  try {
    const {result,rerender,requests,live,app,unmount}=setup(false,true,query);
    await act(async()=>requests[0]!.resolve(['accepted']));
    events.emit('inactive');
    expect(result.current.value).toBeUndefined();
    if(change==='account')live!.account.signedIn=true;
    if(change==='logs')live!.session.logs['Network activity']=!live!.session.logs['Network activity'];
    if(change==='locked-storage')live!.security.unavailable=true;
    if(change==='revoked-read')app.getReadEpoch=()=>1;
    if(change==='protected')live!.session.protectedActions[query.type==='catalog.query'?'Update domains and lists':'View Activities']=true;
    rerender({command:query,scope:'blocked'});
    expect(result.current.value).toBeUndefined();
    events.emit('active');
    expect(result.current.value).toBeUndefined();
    await act(async()=>requests[1]!.reject(new Error('Authentication cancelled.')));
    expect(result.current.value).toBeUndefined();
    unmount();
  } finally {events.restore();}
});
test('no private read or action qualifies for JS caching, including share payloads',()=>{
  const snapshot={session:initialSession(),security:{unavailable:false}} as unknown as import('../app/contract').AppSnapshot;
  expect(mayCacheRead(null,snapshot)).toBe(false);
  for(const command of [...retainedReads,{type:'share.query',id:'one'},{type:'refresh'},{type:'filter.review',id:'one'},{type:'sudoku.new'}] as AppCommand[]) {
    expect(mayCacheRead(command,snapshot)).toBe(false);
  }
});
test('the share retention hint cannot preserve a QR payload across interruption, filter change or rejected refresh',async()=>{
  const events=lifecycle();
  try {
    const {result,rerender,requests,unmount}=setup(true);
    rerender({command:{type:'share.query',id:'one'},scope:'one'});
    await act(async()=>requests[1]!.resolve(['first-code']));
    events.emit('inactive');expect(result.current.value).toBeUndefined();
    events.emit('active');expect(result.current.value).toBeUndefined();
    await act(async()=>requests[2]!.resolve(['updated-code']));
    expect(result.current.value).toEqual(['updated-code']);
    rerender({command:{type:'share.query',id:'two'},scope:'two'});
    expect(result.current.value).toBeUndefined();
    await act(async()=>requests[3]!.resolve(['second-code']));
    events.emit('inactive');events.emit('active');
    await act(async()=>requests[4]!.reject(new Error('This filter cannot be shared.')));
    expect(result.current.value).toBeUndefined();
    expect(result.current.error).toBe('This filter cannot be shared.');
    unmount();
  } finally {events.restore();}
});
test('inactivity clears retained diagnostics and rejects a late page until a fresh foreground query succeeds',async()=>{
  const events=lifecycle();
  try {
    const {result,rerender,requests,command,unmount}=setup();
    await act(async()=>requests[0]!.resolve(['private.example']));
    rerender({command:{...blocked,limit:61},scope:'blocked'});
    expect(result.current.value).toEqual(['private.example']);
    events.emit('inactive');
    expect(result.current.value).toBeUndefined();
    events.emit('background');
    await act(async()=>requests[1]!.resolve(['late.private.example']));
    expect(result.current.value).toBeUndefined();
    events.emit('active');
    expect(command).toHaveBeenCalledTimes(3);
    expect(result.current.value).toBeUndefined();
    await act(async()=>requests[2]!.resolve(['fresh.example']));
    expect(result.current.value).toEqual(['fresh.example']);
    unmount();
  } finally {events.restore();}
});
test.each(['cancel','cancel-before-active','authorize'])('a credential prompt lifecycle does not overlap requests or re-prompt after %s',async(outcome)=>{
  jest.useFakeTimers();const events=lifecycle();
  try {
    const {result,requests,command,unmount}=setup();
    events.emit('inactive');
    if(outcome!=='cancel-before-active')events.emit('active');
    expect(command).toHaveBeenCalledTimes(1);
    if(outcome!=='authorize') {
      await act(async()=>requests[0]!.reject(new Error('Authentication cancelled.')));
      if(outcome==='cancel-before-active')events.emit('active');
      await act(async()=>jest.advanceTimersByTime(30000));
      expect(command).toHaveBeenCalledTimes(1);
      expect(result.current.error).toBe('Authentication cancelled.');
      expect(result.current.value).toBeUndefined();
    } else {
      await act(async()=>requests[0]!.resolve(['from-before-inactive']));
      expect(command).toHaveBeenCalledTimes(2);
      expect(result.current.value).toBeUndefined();
      await act(async()=>requests[1]!.resolve(['authorized-after-resume']));
      expect(result.current.value).toEqual(['authorized-after-resume']);
    }
    unmount();
  } finally {events.restore();jest.useRealTimers();}
});

test('leaving a protected tab clears its cached value before focus returns',async()=>{
  try {
    const {result,rerender,requests,unmount}=setup();
    await act(async()=>requests[0]!.resolve(['private.example']));
    mockFocused=false;rerender({command:blocked,scope:'blocked'});
    expect(result.current.value).toBeUndefined();
    mockFocused=true;rerender({command:blocked,scope:'blocked'});
    expect(result.current.value).toBeUndefined();
    await act(async()=>requests[1]!.resolve(['authorized.example']));
    expect(result.current.value).toEqual(['authorized.example']);
    unmount();
  } finally {mockFocused=true;}
});

// Authorization-sensitive reuse is native-owned even when protection is currently off.
test('Activity-family reads clear on navigation and return through a fresh native query',async()=>{
  try {
    const {result,rerender,requests,command,unmount}=setup(false,true);
    await act(async()=>requests[0]!.resolve(['retained.example']));
    mockFocused=false;rerender({command:blocked,scope:'blocked'});
    expect(result.current.value).toBeUndefined();
    mockFocused=true;rerender({command:blocked,scope:'blocked'});
    expect(result.current.value).toBeUndefined();
    expect(command).toHaveBeenCalledTimes(2);
    await act(async()=>requests[1]!.resolve(['fresh.example']));
    expect(result.current.value).toEqual(['fresh.example']);
    unmount();
  } finally {mockFocused=true;}
});
test('returning to the exact previously loaded decision cannot replay an earlier result',async()=>{
  const {result,rerender,requests,unmount}=setup(false,true);
  await act(async()=>requests[0]!.resolve(['blocked.example']));
  rerender({command:{...blocked,decision:'Allowed'},scope:'allowed'});
  expect(result.current.value).toBeUndefined();
  await act(async()=>requests[1]!.resolve(['allowed.example']));
  rerender({command:blocked,scope:'blocked'});
  expect(result.current.value).toBeUndefined();
  await act(async()=>requests[2]!.resolve(['new-blocked.example']));
  expect(result.current.value).toEqual(['new-blocked.example']);
  unmount();
});
test('a transient active refresh failure retains only the current authorized render value',async()=>{
  const {result,requests,unmount}=setup(false,true);
  await act(async()=>requests[0]!.resolve(['last-good.example']));
  let refresh!:Promise<void>;
  act(()=>{refresh=result.current.refresh();});
  await act(async()=>{requests[1]!.reject(new Error('Temporary read failure.'));await refresh;});
  expect(result.current.value).toEqual(['last-good.example']);
  expect(result.current.error).toBe('Temporary read failure.');
  unmount();
});

test.each([...retainedReads,{type:'share.query',id:'one'} as AppCommand])('$type cannot replay an identical key across a screen remount',async(query)=>{
  const {requests,command,wrapper,app,unmountScreen}=setup(true,true,query);
  await act(async()=>requests[0]!.resolve(['cached.example']));
  unmountScreen();
  const second=renderHook(()=>useAppQuery<string[]>(query,'blocked',true),{wrapper});
  expect(second.result.current.value).toBeUndefined();
  expect(command).toHaveBeenCalledTimes(2);
  await act(async()=>requests[1]!.resolve(['new.example']));
  expect(second.result.current.value).toEqual(['new.example']);
  second.unmount();clearAppReadCache(app);
});
test('enabling Activity protection immediately hides an unprotected cached result',async()=>{
  const {result,rerender,requests,live,unmount}=setup(false,true);
  await act(async()=>requests[0]!.resolve(['private.example']));
  live!.session.protectedActions['View Activities']=true;
  rerender({command:blocked,scope:'blocked'});
  expect(result.current.value).toBeUndefined();
  await act(async()=>requests[1]!.reject(new Error('Authentication cancelled.')));
  expect(result.current.value).toBeUndefined();
  unmount();
});
test('cache revocation during an outstanding native request waits for it before retrying',async()=>{
  const events=lifecycle();
  try {
    const {result,requests,command,unmount}=setup(false,true);
    events.emit('inactive');events.emit('active');
    await act(async()=>Promise.resolve());
    expect(command).toHaveBeenCalledTimes(1);
    await act(async()=>requests[0]!.resolve(['late.example']));
    expect(result.current.value).toBeUndefined();
    expect(command).toHaveBeenCalledTimes(2);
    await act(async()=>requests[1]!.resolve(['foreground.example']));
    expect(result.current.value).toEqual(['foreground.example']);
    unmount();
  } finally {events.restore();}
});

test.each(['search','decision'])('a failed %s change reports its attempted identity and retains only its current active scope',async(change)=>{
  const {result,rerender,requests,unmount}=setup(false,true);
  try {
  await act(async()=>requests[0]!.resolve(['blocked.example']));
  const sameScope=change==='search';
  rerender({command:sameScope?{...blocked,search:'missing'}:{...blocked,decision:'Allowed'},scope:sameScope?'blocked':'allowed'});
  await act(async()=>requests[1]!.reject(new Error('The current read failed.')));
  expect(result.current.error).toBe('The current read failed.');
  expect(result.current.refreshing).toBe(false);
  expect(result.current.value).toEqual(sameScope?['blocked.example']:undefined);
  } finally {unmount();}
});

test('manual stats refresh joins the active sample and stays pending until it settles',async()=>{
  const {result,requests,command,unmount}=setup(false,false,{type:'stats.query'});
  let finished=false;
  const manual=result.current.refresh().then(()=>{finished=true;});
  await act(async()=>{});
  expect(command).toHaveBeenCalledTimes(1);expect(finished).toBe(false);
  await act(async()=>{requests[0]!.resolve(['current sample']);await manual;});
  expect(finished).toBe(true);expect(result.current.value).toEqual(['current sample']);
  unmount();
});

const displaySnapshot=(revision:number,readRevision=0):AppSnapshot=>({schema:1,fullApp:true,revision,backgroundPrivacyCoverRequired:false,
  session:initialSession(),security:{unavailable:false,readRevision,sourceRevision:'owner-and-clear-1'},
  account:{signedIn:false,status:'Not connected',detail:''}} as unknown as AppSnapshot);

test.each([stats,activity,{type:'share.query',id:'balanced'} as AppCommand])('$type keeps already-painted all-off values through deferred resume projection and query reads',async query=>{
  const events=lifecycle();let publish!:(value:string)=>void;
  const projections:ReturnType<typeof deferred<string>>[]=[],reads:ReturnType<typeof deferred<string>>[]=[];
  const native={getSnapshot:jest.fn(()=>{const pending=deferred<string>();projections.push(pending);return pending.promise;}),
    command:jest.fn(()=>{const pending=deferred<string>();reads.push(pending);return pending.promise;}),
    onSnapshot:(callback:(value:string)=>void)=>{publish=callback;return {remove:jest.fn()};}};
  const app=new AppStore(native as Spec,displaySnapshot(1));const disconnect=app.connect();
  const wrapper=({children}:PropsWithChildren)=>{
    const state=useSyncExternalStore(app.subscribe,app.getSnapshot);
    return <ReviewContext.Provider value={{app,live:state.snapshot??state.displaySnapshot??undefined} as ReviewState}>{children}</ReviewContext.Provider>;
  };
  const hook=renderHook(()=>useAppQuery<string[]>(query),{wrapper});
  try {
    await act(async()=>reads[0]!.resolve(JSON.stringify({snapshot:displaySnapshot(2),result:['3704']})));
    expect(hook.result.current.value).toEqual(['3704']);
    events.emit('inactive');expect(hook.result.current.value).toEqual(['3704']);
    events.emit('background');expect(hook.result.current.value).toEqual(['3704']);
    events.emit('active');expect(hook.result.current.value).toEqual(['3704']);
    expect(native.command).toHaveBeenCalledTimes(1);expect(hook.result.current.error).toBeUndefined();
    await act(async()=>publish(JSON.stringify({schema:1,fullApp:true,revision:3,presentationBlocked:true,backgroundPrivacyCoverRequired:false})));
    expect(hook.result.current.value).toEqual(['3704']);expect(native.command).toHaveBeenCalledTimes(1);
    await act(async()=>projections[0]!.resolve(JSON.stringify(displaySnapshot(3))));
    expect(app.getSnapshot().snapshot).toBeNull();expect(hook.result.current.value).toEqual(['3704']);
    await act(async()=>projections.at(-1)!.resolve(JSON.stringify(displaySnapshot(4,1))));
    expect(native.command).toHaveBeenCalledTimes(2);expect(hook.result.current.value).toEqual(['3704']);
    await act(async()=>reads[1]!.resolve(JSON.stringify({snapshot:displaySnapshot(5,1),result:['3709']})));
    expect(hook.result.current.value).toEqual(['3709']);expect(hook.result.current.error).toBeUndefined();
  } finally {hook.unmount();disconnect();events.restore();}
});

test.each([true,undefined])('a native privacy boundary discards displayed query values and off metadata cannot revive them: %p',async policy=>{
  const events=lifecycle();let publish!:(value:string)=>void;
  const native={getSnapshot:()=>new Promise<string>(()=>{}),
    command:jest.fn(async()=>JSON.stringify({snapshot:displaySnapshot(2),result:['3704']})),
    onSnapshot:(callback:(value:string)=>void)=>{publish=callback;return {remove:jest.fn()};}};
  const app=new AppStore(native as Spec,displaySnapshot(1));const disconnect=app.connect();
  const wrapper=({children}:PropsWithChildren)=>{
    const state=useSyncExternalStore(app.subscribe,app.getSnapshot);
    return <ReviewContext.Provider value={{app,live:state.snapshot??state.displaySnapshot??undefined} as ReviewState}>{children}</ReviewContext.Provider>;
  };
  const hook=renderHook(()=>useAppQuery<string[]>(stats),{wrapper});
  try {
    await act(async()=>{});expect(hook.result.current.value).toEqual(['3704']);
    events.emit('inactive');events.emit('active');expect(hook.result.current.value).toEqual(['3704']);
    await act(async()=>publish(JSON.stringify({schema:1,fullApp:true,revision:3,presentationBlocked:true,backgroundPrivacyCoverRequired:policy})));
    expect(hook.result.current.value).toBeUndefined();
    await act(async()=>publish(JSON.stringify({schema:1,fullApp:true,revision:4,presentationBlocked:true,backgroundPrivacyCoverRequired:false})));
    expect(hook.result.current.value).toBeUndefined();expect(native.command).toHaveBeenCalledTimes(1);
  } finally {hook.unmount();disconnect();events.restore();}
});

test('an all-off mounted route retains its painted value through blur and deferred refocus while reads pause',async()=>{
  jest.useFakeTimers();
  const {result,rerender,requests,command,unmount}=setup(false,true,stats,true);
  try {
    await act(async()=>requests[0]!.resolve(['3704']));
    act(()=>{void result.current.refresh();});expect(command).toHaveBeenCalledTimes(2);
    mockFocused=false;rerender({command:stats,scope:'blocked'});
    expect(result.current.value).toEqual(['3704']);expect(result.current.refreshing).toBe(false);
    await act(async()=>jest.advanceTimersByTime(10000));expect(command).toHaveBeenCalledTimes(2);
    await act(async()=>requests[1]!.resolve(['late-while-blurred']));
    expect(result.current.value).toEqual(['3704']);
    mockFocused=true;rerender({command:stats,scope:'blocked'});
    expect(result.current.value).toEqual(['3704']);expect(command).toHaveBeenCalledTimes(3);
    await act(async()=>requests[2]!.resolve(['3709']));expect(result.current.value).toEqual(['3709']);
  } finally {unmount();mockFocused=true;jest.useRealTimers();}
});

test.each(['source','account','logs','protected','passcode','command','retention-key'])('an all-off displayed query cannot survive or revive after its %s scope changes',async change=>{
  const events=lifecycle();const {result,rerender,requests,live,unmount}=setup(false,true,stats,true);
  try {
    await act(async()=>requests[0]!.resolve(['3704']));events.emit('inactive');
    expect(result.current.value).toEqual(['3704']);
    const original=JSON.stringify(live);
    if(change==='source')live!.security.sourceRevision='owner-and-clear-2';
    if(change==='account')live!.account.signedIn=true;
    if(change==='logs')live!.session.logs['Network activity']=!live!.session.logs['Network activity'];
    if(change==='protected')live!.session.protectedActions['View Activities']=true;
    if(change==='passcode')live!.session.passcode=!live!.session.passcode;
    rerender({command:change==='command'?activity:stats,scope:change==='retention-key'?'another-scope':'blocked'});
    expect(result.current.value).toBeUndefined();
    Object.assign(live!,JSON.parse(original));rerender({command:stats,scope:'blocked'});
    expect(result.current.value).toBeUndefined();
    events.emit('active');expect(result.current.value).toBeUndefined();
    await act(async()=>requests.at(-1)!.resolve(['fresh-for-current-scope']));
    expect(result.current.value).toEqual(['fresh-for-current-scope']);
  } finally {unmount();events.restore();}
});

test.each([true,undefined])('an all-off displayed query cannot revive after concealment is required: %p',async policy=>{
  const events=lifecycle();const {result,rerender,requests,live,unmount}=setup(false,true,stats,true);
  try {
    await act(async()=>requests[0]!.resolve(['3704']));events.emit('inactive');
    live!.backgroundPrivacyCoverRequired=policy;rerender({command:stats,scope:'blocked'});
    expect(result.current.value).toBeUndefined();
    live!.backgroundPrivacyCoverRequired=false;rerender({command:stats,scope:'blocked'});
    expect(result.current.value).toBeUndefined();
  } finally {unmount();events.restore();}
});

test('an already-painted empty all-off result does not become a loading placeholder on interruption',async()=>{
  const events=lifecycle();const {result,requests,unmount}=setup(false,true,stats,true);
  try {
    await act(async()=>requests[0]!.resolve([]));events.emit('inactive');
    expect(result.current.value).toEqual([]);expect(result.current.refreshing).toBe(false);
    events.emit('active');expect(result.current.value).toEqual([]);expect(result.current.refreshing).toBe(false);
  } finally {unmount();events.restore();}
});

test('a generic transient refresh error keeps the same all-off painted share scope without caching it',async()=>{
  const {result,requests,unmount}=setup(false,true,{type:'share.query',id:'balanced'},true);
  try {
    await act(async()=>requests[0]!.resolve(['already-painted-code']));
    let refresh!:Promise<void>;act(()=>{refresh=result.current.refresh();});
    await act(async()=>{requests[1]!.reject(new Error('Temporary read failure.'));await refresh;});
    expect(result.current.value).toEqual(['already-painted-code']);expect(result.current.error).toBe('Temporary read failure.');
  } finally {unmount();}
});

test('explicit native display identity preserves painted values through benign source, grant, account status and credential churn',async()=>{
  const events=lifecycle();const {result,rerender,requests,live,unmount}=setup(false,true,stats,true);
  Object.assign(live!.security,{ownerRevision:'owner-1',displayClearRevision:'clear-1'});rerender({command:stats,scope:'blocked'});
  try{
    await act(async()=>requests.at(-1)!.resolve(['3704']));events.emit('inactive');
    live!.account.status='Refreshing';live!.account.detail='Checking connection';live!.session.passcode=!live!.session.passcode;
    Object.assign(live!.security,{sourceRevision:'source-2',readRevision:9});rerender({command:stats,scope:'blocked'});
    expect(result.current.value).toEqual(['3704']);events.emit('active');expect(result.current.value).toEqual(['3704']);
    await act(async()=>requests.at(-1)!.resolve(['3709']));expect(result.current.value).toEqual(['3709']);
  }finally{unmount();events.restore();}
});
test.each(['owner','resource-clear','logs','selected-protection'])('native %s retires a painted same-ID sharing frame and cannot revive it',async change=>{
  const events=lifecycle();const request:AppCommand={type:'share.query',id:'same-filter-id'};
  const {result,rerender,requests,live,unmount}=setup(false,true,request,true);
  Object.assign(live!.security,{ownerRevision:'owner-1',displayClearRevision:'clear-1'});rerender({command:request,scope:'blocked'});
  try{
    await act(async()=>requests.at(-1)!.resolve(['old-private-code']));events.emit('inactive');const original=JSON.stringify(live);
    if(change==='owner')Object.assign(live!.security,{ownerRevision:'owner-2'});
    if(change==='resource-clear')Object.assign(live!.security,{displayClearRevision:'clear-2'});
    if(change==='logs')live!.session.logs['Network activity']=!live!.session.logs['Network activity'];
    if(change==='selected-protection')live!.session.protectedActions['View Activities']=true;
    rerender({command:request,scope:'blocked'});expect(result.current.value).toBeUndefined();
    Object.assign(live!,JSON.parse(original));rerender({command:request,scope:'blocked'});expect(result.current.value).toBeUndefined();
  }finally{unmount();events.restore();}
});
