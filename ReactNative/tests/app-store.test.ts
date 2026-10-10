import {AppState, type AppStateStatus} from 'react-native';
import {appReadCache} from '../app/read-cache';
import {AppStore} from '../app/store';
import type {Spec} from '../specs/NativeLavaApp';
const originalState=AppState.currentState;
beforeAll(()=>Object.defineProperty(AppState,'currentState',{configurable:true,value:'active'}));
afterAll(()=>Object.defineProperty(AppState,'currentState',{configurable:true,value:originalState}));
const deferred = <T,>() => {let resolve!: (value:T)=>void; let reject!:(error:Error)=>void; const promise=new Promise<T>((yes,no)=>{resolve=yes;reject=no;});return {promise,resolve,reject};};
const snapshot=(revision:number)=>JSON.stringify({schema:1,fullApp:true,revision});
const response=(revision:number,result:unknown=null)=>JSON.stringify({snapshot:JSON.parse(snapshot(revision)),result});
test('the initial native snapshot is available synchronously and a late startup query cannot replace it',async()=>{
  const pending=deferred<string>();
  const native={getSnapshot:()=>pending.promise,onSnapshot:()=>({remove(){}})} as unknown as Spec;
  const store=new AppStore(native,JSON.parse(snapshot(8)));
  expect(store.getSnapshot().snapshot?.revision).toBe(8);
  const disconnect=store.connect();
  pending.resolve(snapshot(2));await pending.promise;await Promise.resolve();
  expect(store.getSnapshot().snapshot?.revision).toBe(8);
  disconnect();
});
test.each<AppStateStatus|null>(['inactive','background','unknown',null])('all-off bootstrap fields paint before JS activation without read or action authority: %p',async state=>{
  const events=lifecycle();
  Object.defineProperty(AppState,'currentState',{configurable:true,value:state});
  const native={getSnapshot:jest.fn(()=>new Promise<string>(()=>{})),command:jest.fn(),onSnapshot:()=>({remove(){}})} as unknown as Spec;
  const initial=JSON.parse(snapshot(8));initial.backgroundPrivacyCoverRequired=false;
  const store=new AppStore(native,initial),disconnect=store.connect();
  try {
    expect(store.getSnapshot().snapshot).toBeNull();
    expect(store.getSnapshot().displaySnapshot).toBe(initial);
    expect(store.getSnapshot().privacyCoverRequired).toBe(false);
    await expect(store.command({type:'stats.query'})).rejects.toThrow('Read access changed.');
    await expect(store.command({type:'settings.set',key:'look',value:'original'})).rejects.toThrow('Read access changed.');
    expect(native.command).not.toHaveBeenCalled();
    events.emit('unknown');expect(store.getSnapshot().displaySnapshot).toBe(initial);
  } finally {disconnect();events.restore();}
});
test('a suspended catalog refresh cannot delay opening or editing a filter and its late reply cannot roll back the draft',async()=>{
  const {store,native}=setup();const refresh=deferred<string>();
  native.command.mockImplementation(async request=>JSON.parse(request).type==='filter.refresh'?refresh.promise:response(10));
  const pending=store.command({type:'filter.refresh',id:'active'});
  await store.command({type:'filter.open',id:'active'});
  await store.command({type:'filter.edit',id:'active'});
  expect(native.command.mock.calls.map(([request])=>JSON.parse(request).type)).toEqual(['filter.refresh','filter.open','filter.edit']);
  refresh.resolve(response(2));await pending;
  expect(store.getSnapshot().snapshot?.revision).toBe(10);
});
function setup() {
  let event!:(value:string)=>void;
  const native={getSnapshot:jest.fn(async()=>snapshot(1)),command:jest.fn(async(_request:string)=>response(2)),onSnapshot:(callback:(value:string)=>void)=>{event=callback;return {remove:jest.fn()};}};
  const store=new AppStore(native as Spec,JSON.parse(snapshot(1))); const disconnect=store.connect();
  return {store,native,disconnect,emit:(value:string)=>event(value)};
}
test('a delayed initial refresh cannot replace a newer native event',async()=>{
  const {store,native,emit}=setup(); const pending=deferred<string>();native.getSnapshot.mockReturnValueOnce(pending.promise);
  const refresh=store.refresh();emit(snapshot(8));pending.resolve(snapshot(2));await refresh;
  expect(store.getSnapshot().snapshot?.revision).toBe(8);
});

test('an all-off pre-lock marker revokes active read and action authority without retiring the displayed frame',async()=>{
  const {store,native,emit,disconnect}=setup();
  try {
    await store.refresh();
    const off=(revision:number)=>JSON.stringify({...JSON.parse(snapshot(revision)),backgroundPrivacyCoverRequired:false});
    emit(off(2));
    const accepted=store.getSnapshot().snapshot,epoch=store.getReadEpoch(),pending=deferred<string>();
    native.command.mockReturnValueOnce(pending.promise);
    const oldRead=store.command({type:'stats.query'});
    const revoked=expect(oldRead).rejects.toThrow('Read access changed.');
    expect(AppState.currentState).toBe('active');
    emit(JSON.stringify({schema:1,fullApp:true,revision:3,presentationBlocked:true,backgroundPrivacyCoverRequired:false}));
    expect(store.getSnapshot().snapshot).toBeNull();
    expect(store.getSnapshot().displaySnapshot).toBe(accepted);
    expect(store.getReadEpoch()).toBeGreaterThan(epoch);
    expect(store.getPresentationHydration().required).toBe(false);
    await expect(store.command({type:'stats.query'})).rejects.toThrow('Read access changed.');
    await expect(store.command({type:'settings.set',key:'look',value:'original'})).rejects.toThrow('Read access changed.');
    await expect(store.command({type:'navigation.authorize',surface:'appSettings'})).rejects.toThrow('Read access changed.');
    await expect(store.command({type:'haptic',kind:'selection',controlID:'wake'})).rejects.toThrow('Read access changed.');
    expect(native.command).toHaveBeenCalledTimes(1);
    emit(JSON.stringify({schema:1,fullApp:true,revision:4,presentationBlocked:true,backgroundPrivacyCoverRequired:false}));
    pending.resolve(JSON.stringify({snapshot:JSON.parse(off(1000)),result:['stale private data']}));
    await revoked;
    expect(store.getSnapshot().snapshot).toBeNull();
    expect(store.getSnapshot().displaySnapshot).toBe(accepted);
    emit(off(5));
    expect(store.getSnapshot().snapshot?.revision).toBe(5);
    expect(store.getSnapshot().displaySnapshot).toBeNull();
    expect(store.getPresentationHydration().required).toBe(false);
  } finally {disconnect();}
});
test('protection Stop reaches native while a filter compile is in flight',async()=>{
  const {store,native}=setup();const compile=deferred<string>();native.command.mockReturnValueOnce(compile.promise);
  const apply=store.command({type:'filter.apply',id:'active',review:'accepted-review'});
  await store.command({type:'protection.toggle'});
  expect(native.command).toHaveBeenCalledTimes(2);expect(JSON.parse(native.command.mock.calls[1]![0]).type).toBe('protection.toggle');
  compile.resolve(response(3));await apply;
});
test('a foreground dismissal guard reaches UIKit before queued feedback sampling finishes',async()=>{
  const {store,native,disconnect}=setup();const sampling=deferred<string>();
  native.command.mockImplementation(async request=>JSON.parse(request).type==='feedback.enter'?sampling.promise:response(10));
  try{
    const pending=store.command({type:'feedback.enter',id:'visit'});await Promise.resolve();
    const queued=store.command({type:'feedback.change',id:'visit',field:'details',value:'A'});
    const guard=store.command({type:'foreground.dirty',id:'visit',dirty:true});
    await Promise.resolve();await Promise.resolve();
    expect(native.command.mock.calls.map(([request])=>JSON.parse(request).type)).toEqual(['feedback.enter','foreground.dirty']);
    sampling.resolve(response(2));await Promise.all([pending,guard,queued]);
    expect(store.getSnapshot().snapshot?.revision).toBe(10);
  }finally{sampling.resolve(response(2));disconnect();}
});
test('failed writes never invent a successful settings snapshot',async()=>{
  const {store,native}=setup();await store.refresh();native.command.mockRejectedValueOnce(new Error('Authentication cancelled.'));
  await expect(store.command({type:'settings.set',key:'deviceDNS',value:true})).rejects.toThrow('Authentication cancelled');
  expect(store.getSnapshot().snapshot?.revision).toBe(1);
});
test('disconnect discards late replies and prevents queued mutations from starting',async()=>{
  const {store,native,disconnect}=setup();const pending=deferred<string>();native.command.mockReturnValueOnce(pending.promise);
  const first=store.command({type:'settings.set',key:'haptics',value:false});
  const queued=store.command({type:'settings.set',key:'deviceDNS',value:true});
  const rejection1=expect(first).rejects.toThrow('closed');const rejection2=expect(queued).rejects.toThrow('closed');
  await Promise.resolve();disconnect();pending.resolve(response(9));await Promise.all([rejection1,rejection2]);
  expect(native.command).toHaveBeenCalledTimes(1);expect(store.getSnapshot().snapshot?.revision).not.toBe(9);
});
test.each([null,{schema:1,fullApp:false,revision:2},{schema:1,fullApp:true,revision:'bad'}])('rejects an incompatible or malformed native snapshot: %p',async invalid=>{
  const {store,emit}=setup();await store.refresh();emit(JSON.stringify(invalid));expect(store.getSnapshot().error).toContain('full Lava runtime');expect(store.getSnapshot().snapshot?.revision).toBe(1);
});

test('clearing native logs revokes cached reads before and after the native mutation',async()=>{
  const {store,native,disconnect}=setup();await store.refresh();
  const key=['domains'];await appReadCache(store).read(key,async()=>['private.example']);
  const request=deferred<string>();native.command.mockReturnValueOnce(request.promise);
  const clearing=store.command({type:'logs.clear',kind:'Clear domain history'});
  await Promise.resolve();
  expect(appReadCache(store).peek(key)).toBeUndefined();
  const epoch=store.getReadEpoch();
  request.resolve(response(4));await clearing;
  expect(store.getReadEpoch()).toBeGreaterThan(epoch);
  expect(appReadCache(store).peek(key)).toBeUndefined();
  disconnect();
});


test('scrub haptics acknowledge without repainting app state while real native observations remain live',async()=>{
  const {store,native,emit,disconnect}=setup();await store.refresh();
  const before=store.getSnapshot(),epoch=store.getInvalidation();const listener=jest.fn();store.subscribe(listener);
  native.command.mockResolvedValue(JSON.stringify({result:null}));
  await Promise.all(Array.from({length:40},()=>store.command({type:'haptic',kind:'changed'})));
  expect(listener).not.toHaveBeenCalled();expect(store.getSnapshot()).toBe(before);expect(store.getInvalidation()).toBe(epoch);
  emit(snapshot(9));expect(listener).toHaveBeenCalledTimes(1);expect(store.getSnapshot().snapshot?.revision).toBe(9);
  native.command.mockRejectedValueOnce(new Error('Invalid haptic.'));
  await expect(store.command({type:'haptic',kind:'changed'})).rejects.toThrow('Invalid haptic.');
  expect(listener).toHaveBeenCalledTimes(1);disconnect();
});
test('state-changing commands still reject an effect-only response',async()=>{
  const {store,native,disconnect}=setup();await store.refresh();const before=store.getSnapshot();
  native.command.mockResolvedValue(JSON.stringify({result:null}));
  await expect(store.command({type:'settings.set',key:'haptics',value:false})).rejects.toThrow('updated state');
  expect(store.getSnapshot()).toBe(before);disconnect();
});

function lifecycle() {
  const listeners=new Set<(state:AppStateStatus)=>void>();
  const originalListener=AppState.addEventListener;
  AppState.addEventListener=(_event,listener)=>{
    const callback=listener as (state:AppStateStatus)=>void;
    listeners.add(callback);return {remove:()=>{listeners.delete(callback);}};
  };
  return {
    emit(state:AppStateStatus) {
      Object.defineProperty(AppState,'currentState',{configurable:true,value:state});
      for(const callback of listeners)callback(state);
    },
    restore() {AppState.addEventListener=originalListener;Object.defineProperty(AppState,'currentState',{configurable:true,value:'active'});},
  };
}

test('inactivity drops the private snapshot and background observations cannot refill it',async()=>{
  const events=lifecycle();const {store,native,emit,disconnect}=setup();
  try {
    await store.refresh();expect(store.getSnapshot().snapshot?.revision).toBe(1);
    const epoch=store.getReadEpoch();
    events.emit('inactive');expect(store.getSnapshot().snapshot).toBeNull();
    expect(store.getReadEpoch()).toBeGreaterThan(epoch);
    events.emit('background');emit(snapshot(8));
    expect(store.getSnapshot().snapshot).toBeNull();
    const fresh=deferred<string>();native.getSnapshot.mockReturnValueOnce(fresh.promise);
    const reads=native.getSnapshot.mock.calls.length;
    events.emit('active');
    expect(native.getSnapshot).toHaveBeenCalledTimes(reads+1);
    expect(store.getSnapshot().snapshot).toBeNull();
    fresh.resolve(snapshot(9));await fresh.promise;await Promise.resolve();
    expect(store.getSnapshot().snapshot?.revision).toBe(9);
  } finally {disconnect();events.restore();}
});

test('a snapshot read started before interruption cannot replay after returning active',async()=>{
  const events=lifecycle();const {store,native,disconnect}=setup();
  try {
    await store.refresh();
    const old=deferred<string>(),fresh=deferred<string>();
    native.getSnapshot.mockReturnValueOnce(old.promise).mockReturnValueOnce(fresh.promise);
    const oldRead=store.refresh();
    events.emit('inactive');events.emit('active');
    old.resolve(snapshot(8));await oldRead;
    expect(store.getSnapshot().snapshot).toBeNull();
    fresh.resolve(snapshot(9));await fresh.promise;await Promise.resolve();
    expect(store.getSnapshot().snapshot?.revision).toBe(9);
  } finally {disconnect();events.restore();}
});

test('a query reply started before interruption cannot restore its attached private snapshot',async()=>{
  const events=lifecycle();const {store,native,disconnect}=setup();
  try {
    await store.refresh();
    const old=deferred<string>(),fresh=deferred<string>();
    native.command.mockReturnValueOnce(old.promise);
    native.getSnapshot.mockReturnValueOnce(fresh.promise);
    const oldRead=store.command({type:'share.query',id:'same-filter'});
    events.emit('inactive');events.emit('active');
    old.resolve(response(8,{code:'private-code'}));await expect(oldRead).rejects.toThrow('Read access changed.');
    expect(store.getSnapshot().snapshot).toBeNull();
    fresh.resolve(snapshot(9));await fresh.promise;await Promise.resolve();
    expect(store.getSnapshot().snapshot?.revision).toBe(9);
  } finally {disconnect();events.restore();}
});

test('the JS read adapter never stores or replays identical-key private values',async()=>{
  const {store,disconnect}=setup();
  try {
    const read=jest.fn().mockResolvedValueOnce(['old-private-value']).mockResolvedValueOnce(['fresh-private-value']);
    const cache=appReadCache(store),key=['share.query','same-filter'];
    expect(await cache.read(key,read)).toEqual(['old-private-value']);
    expect(cache.peek(key)).toBeUndefined();
    expect(await cache.read(key,read)).toEqual(['fresh-private-value']);
    expect(read).toHaveBeenCalledTimes(2);
    expect(cache.peek(key)).toBeUndefined();
  } finally {disconnect();}
});


test('serialized command sequencing retains completion without its private payload',async()=>{
  const {store,native,disconnect}=setup();
  try {
    await store.refresh();native.command.mockResolvedValueOnce(response(2,{secret:'private-review'}));
    const result=await store.command({type:'domains.stage',domain:'example.com',decision:'blocked'});
    expect(result).toEqual({secret:'private-review'});
    expect(await (store as unknown as {tail:Promise<unknown>}).tail).toBeUndefined();
  } finally {disconnect();}
});

test.each(['allowed','blocked'] as const)('a %s domain review survives its own snapshot arriving before its token',async decision=>{
  const {store,native,emit,disconnect}=setup();
  try {
    await store.refresh();
    const before={...JSON.parse(snapshot(3)),security:{sourceRevision:'1:0',ownerRevision:'owner',readRevision:1}};
    emit(JSON.stringify(before));
    const after={...before,revision:4,security:{...before.security,sourceRevision:'2:0'}};
    const result={id:'active',standaloneReview:'owned-review'};
    const epoch=store.getReadEpoch();
    native.command.mockImplementationOnce(async()=>{emit(JSON.stringify(after));return JSON.stringify({snapshot:after,result});});
    await expect(store.command({type:'domains.stage',domain:'example.com',decision})).resolves.toEqual(result);
    expect(store.getReadEpoch()).toBeGreaterThan(epoch);
    expect(store.getSnapshot().snapshot?.revision).toBe(4);
    expect(native.command).toHaveBeenCalledTimes(1);
  } finally {disconnect();}
});

test('a domain capacity rejection survives its own snapshot so the upsell can open',async()=>{
  const {store,native,emit,disconnect}=setup();
  try {
    await store.refresh();
    emit(JSON.stringify({...JSON.parse(snapshot(3)),security:{sourceRevision:'1:0',ownerRevision:'owner'}}));
    const after={...JSON.parse(snapshot(4)),security:{sourceRevision:'2:0',ownerRevision:'owner'}};
    const result={rejection:{title:'Blocked domain limit reached',message:'Upgrade or remove entries',limitReached:true}};
    native.command.mockImplementationOnce(async()=>{emit(JSON.stringify(after));return JSON.stringify({snapshot:after,result});});
    await expect(store.command({type:'domains.stage',domain:'example.com',decision:'blocked'})).resolves.toEqual(result);
  } finally {disconnect();}
});

test('a domain source change without a native owner identity retains the strict read fence',async()=>{
  const {store,native,emit,disconnect}=setup();
  try {
    await store.refresh();
    emit(JSON.stringify({...JSON.parse(snapshot(3)),security:{sourceRevision:'1:0'}}));
    const after={...JSON.parse(snapshot(4)),security:{sourceRevision:'2:0'}};
    native.command.mockImplementationOnce(async()=>{
      emit(JSON.stringify(after));
      return JSON.stringify({snapshot:after,result:{id:'active',standaloneReview:'unknown-owner'}});
    });
    await expect(store.command({type:'domains.stage',domain:'example.com',decision:'blocked'})).rejects.toThrow('Read access changed.');
    expect(native.command).toHaveBeenLastCalledWith(JSON.stringify({type:'domains.cancel',token:'unknown-owner'}));
  } finally {disconnect();}
});

test.each(['ownerRevision','readRevision','displayClearRevision'] as const)('a %s change discards a domain token even if authority returns before delivery',async key=>{
  const {store,native,emit,disconnect}=setup();
  try {
    await store.refresh();
    const initial={...JSON.parse(snapshot(3)),security:{sourceRevision:'1:0',ownerRevision:'owner',readRevision:1,displayClearRevision:'clear'}};
    emit(JSON.stringify(initial));
    const pending=deferred<string>();native.command.mockReturnValueOnce(pending.promise);
    const staged=store.command({type:'domains.stage',domain:'example.com',decision:'allowed'});
    const rejected=expect(staged).rejects.toThrow('Read access changed.');
    await Promise.resolve();
    emit(JSON.stringify({...initial,revision:4,security:{...initial.security,[key]:key==='readRevision'?2:'changed'}}));
    emit(JSON.stringify({...initial,revision:5}));
    pending.resolve(JSON.stringify({snapshot:{...initial,revision:6},result:{id:'active',standaloneReview:'stale-review'}}));
    await rejected;
    expect(native.command).toHaveBeenLastCalledWith(JSON.stringify({type:'domains.cancel',token:'stale-review'}));
    expect(store.getSnapshot().snapshot?.revision).toBe(5);
  } finally {disconnect();}
});

test('a domain review interrupted by inactivity is discarded without publishing its stale draft',async()=>{
  const events=lifecycle();const {store,native,disconnect}=setup();
  try {
    await store.refresh();
    const pending=deferred<string>();native.command.mockReturnValueOnce(pending.promise);
    const staged=store.command({type:'domains.stage',domain:'example.com',decision:'blocked'});
    const rejected=expect(staged).rejects.toThrow('Read access changed.');
    await Promise.resolve();events.emit('inactive');
    pending.resolve(response(4,{id:'active',standaloneReview:'inactive-review'}));
    await rejected;
    expect(native.command).toHaveBeenLastCalledWith(JSON.stringify({type:'domains.cancel',token:'inactive-review'}));
    expect(store.getSnapshot().snapshot).toBeNull();
  } finally {disconnect();events.restore();}
});

test('a domain token delivered after its store disconnects is discarded',async()=>{
  const {store,native,disconnect}=setup();
  await store.refresh();
  const pending=deferred<string>();native.command.mockReturnValueOnce(pending.promise);
  const staged=store.command({type:'domains.stage',domain:'example.com',decision:'allowed'});
  const rejected=expect(staged).rejects.toThrow('The app screen closed while this action completed.');
  await Promise.resolve();disconnect();
  pending.resolve(response(4,{id:'active',standaloneReview:'detached-review'}));
  await rejected;
  expect(native.command).toHaveBeenLastCalledWith(JSON.stringify({type:'domains.cancel',token:'detached-review'}));
  expect(store.getSnapshot().snapshot).toBeNull();
});

test('an interrupted mutation cannot repopulate the new foreground snapshot',async()=>{
  const events=lifecycle();const {store,native,disconnect}=setup();
  try {
    await store.refresh();const old=deferred<string>(),fresh=deferred<string>();
    native.command.mockReturnValueOnce(old.promise);native.getSnapshot.mockReturnValueOnce(fresh.promise);
    const mutation=store.command({type:'settings.set',key:'haptics',value:false});
    await Promise.resolve();events.emit('inactive');events.emit('active');
    old.resolve(response(8,null));await mutation;
    expect(store.getSnapshot().snapshot).toBeNull();
    fresh.resolve(snapshot(9));await fresh.promise;await Promise.resolve();
    expect(store.getSnapshot().snapshot?.revision).toBe(9);
  } finally {disconnect();events.restore();}
});


test('native privacy-only projections retire the rendered snapshot until a fresh authorized one arrives',async()=>{
  const {store,emit,disconnect}=setup();
  try {
    await store.refresh();const epoch=store.getReadEpoch();
    emit(JSON.stringify({schema:1,fullApp:true,revision:3,presentationBlocked:true}));
    expect(store.getSnapshot().snapshot).toBeNull();expect(store.getReadEpoch()).toBeGreaterThan(epoch);
    emit(snapshot(4));expect(store.getSnapshot().snapshot?.revision).toBe(4);
  } finally {disconnect();}
});

test('a native owner revision rejects a delayed prior-account query even when account labels are identical',async()=>{
  const {store,native,emit,disconnect}=setup();
  try {
    await store.refresh();
    const ownerSnapshot=(revision:number,sourceRevision:string)=>JSON.stringify({...JSON.parse(snapshot(revision)),
      account:{signedIn:true,status:'Connected',detail:''},security:{sourceRevision}});
    emit(ownerSnapshot(3,'owner-generation-1'));
    const epoch=store.getReadEpoch(),old=deferred<string>();
    native.command.mockReturnValueOnce(old.promise);
    const query=store.command({type:'share.query',id:'same-filter'});
    emit(ownerSnapshot(4,'owner-generation-2'));
    expect(store.getReadEpoch()).toBeGreaterThan(epoch);
    old.resolve(JSON.stringify({snapshot:JSON.parse(ownerSnapshot(5,'owner-generation-1')),result:{code:'prior-account'}}));
    await expect(query).rejects.toThrow('Read access changed.');
    expect(store.getSnapshot().snapshot?.revision).toBe(4);
  } finally {disconnect();}
});

const policySnapshot=(revision:number,backgroundPrivacyCoverRequired?:boolean)=>JSON.stringify({
  ...JSON.parse(snapshot(revision)),backgroundPrivacyCoverRequired,
});

const authenticationSnapshot=(revision:number,options:{blocked?:boolean;authenticating?:boolean;revoked?:boolean;owner?:string;policy?:boolean}={})=>JSON.stringify({
  ...JSON.parse(policySnapshot(revision,options.policy??true)),presentationBlocked:options.blocked,
  authenticationInProgress:options.authenticating,presentationRevoked:options.revoked,
  security:{ownerRevision:options.owner??'current-owner',unavailable:false},
});

test('a native-owned prompt preserves only its inert same-owner frame until the current active projection arrives',async()=>{
  const events=lifecycle();const {store,native,emit,disconnect}=setup();
  try {
    await store.refresh();emit(authenticationSnapshot(2,{authenticating:true}));
    const frame=store.getSnapshot().snapshot,epoch=store.getReadEpoch();
    events.emit('inactive');
    expect(store.getSnapshot().snapshot).toBeNull();expect(store.getSnapshot().displaySnapshot).toBe(frame);
    expect(store.getReadEpoch()).toBeGreaterThan(epoch);
    expect(store.getSnapshot().privacyCoverRequired).toBe(true);
    expect(store.getPresentationHydration().required).toBe(false);
    await expect(store.command({type:'settings.set',key:'haptics',value:false})).rejects.toThrow('Read access changed.');
    emit(authenticationSnapshot(3,{blocked:true,authenticating:false,policy:false}));
    expect(store.getSnapshot().displaySnapshot).toBe(frame);
    const pending=deferred<string>();native.getSnapshot.mockReturnValueOnce(pending.promise);
    events.emit('active');expect(store.getSnapshot().snapshot).toBeNull();
    expect(store.getSnapshot().displaySnapshot).toBe(frame);
    pending.resolve(authenticationSnapshot(4,{policy:false}));await pending.promise;await Promise.resolve();
    expect(store.getSnapshot().snapshot?.revision).toBe(4);expect(store.getSnapshot().displaySnapshot).toBeNull();
    expect(store.getPresentationHydration().required).toBe(false);
  } finally {disconnect();events.restore();}
});

test('a queued native prompt marker may pause before JS inactivity without replacing the delivered frame',async()=>{
  const events=lifecycle();const {store,emit,disconnect}=setup();
  try {
    await store.refresh();emit(authenticationSnapshot(2,{authenticating:true}));
    const frame=store.getSnapshot().snapshot;
    emit(authenticationSnapshot(3,{blocked:true,authenticating:true}));
    expect(store.getSnapshot().snapshot).toBeNull();expect(store.getSnapshot().displaySnapshot).toBe(frame);
    events.emit('inactive');emit(authenticationSnapshot(4,{blocked:true,authenticating:false}));
    expect(store.getSnapshot().displaySnapshot).toBe(frame);
    events.emit('active');emit(authenticationSnapshot(5));
    expect(store.getPresentationHydration().required).toBe(false);
  } finally {disconnect();events.restore();}
});

test.each(['background','protected-data','owner-change'] as const)('a %s boundary retires authentication continuity and later prompt metadata cannot revive it',async boundary=>{
  const events=lifecycle();const {store,emit,disconnect}=setup();
  try {
    await store.refresh();emit(authenticationSnapshot(2,{authenticating:true}));events.emit('inactive');
    if(boundary==='background')events.emit('background');
    else emit(authenticationSnapshot(3,{blocked:true,authenticating:true,
      revoked:boundary==='protected-data',owner:boundary==='owner-change'?'replacement-owner':'current-owner'}));
    expect(store.getSnapshot().snapshot).toBeNull();expect(store.getSnapshot().displaySnapshot).toBeNull();
    expect(store.getPresentationHydration().required).toBe(true);
    emit(authenticationSnapshot(4,{blocked:true,authenticating:true}));
    expect(store.getSnapshot().displaySnapshot).toBeNull();
  } finally {disconnect();events.restore();}
});

test('authentication metadata cannot seed a protected cold-start display frame or revive a discarded frame',async()=>{
  const events=lifecycle();events.emit('inactive');
  const native={getSnapshot:jest.fn(()=>new Promise<string>(()=>{})),onSnapshot:()=>({remove(){}})} as unknown as Spec;
  const store=new AppStore(native,JSON.parse(authenticationSnapshot(2,{authenticating:true}))),disconnect=store.connect();
  try {expect(store.getSnapshot().snapshot).toBeNull();expect(store.getSnapshot().displaySnapshot).toBeNull();}
  finally {disconnect();events.restore();}
});

test('a changed native owner retires an all-off authentication frame instead of falling back to opt-out continuity',async()=>{
  const events=lifecycle();const {store,emit,disconnect}=setup();
  try {
    await store.refresh();emit(authenticationSnapshot(2,{authenticating:true,policy:false}));events.emit('inactive');
    expect(store.getSnapshot().displaySnapshot?.revision).toBe(2);
    emit(authenticationSnapshot(3,{blocked:true,owner:'replacement-owner',policy:false}));
    expect(store.getSnapshot().displaySnapshot).toBeNull();
    emit(authenticationSnapshot(4,{blocked:true,authenticating:true,policy:false}));
    expect(store.getSnapshot().displaySnapshot).toBeNull();
  } finally {disconnect();events.restore();}
});

test('same-revision coarse owner replacement revokes active fields before the all-off marker shortcut',async()=>{
  const {store,emit,disconnect}=setup();
  try {
    await store.refresh();emit(authenticationSnapshot(2,{authenticating:true,policy:false}));
    emit(authenticationSnapshot(2,{blocked:true,owner:'replacement-owner',policy:false}));
    expect(store.getSnapshot().snapshot).toBeNull();expect(store.getSnapshot().displaySnapshot).toBeNull();
  } finally {disconnect();}
});

test.each(['active','background','disconnect'] as const)('an interrupted settings response stays pending without read authority until its authentication display reaches %s',async ending=>{
  const events=lifecycle();const {store,native,emit,disconnect}=setup();
  try {
    await store.refresh();emit(authenticationSnapshot(2,{authenticating:true}));
    const pending=deferred<string>();native.command.mockReturnValueOnce(pending.promise);
    const command=store.command({type:'settings.set',key:'protectedActions.App Unlock',value:false});
    const completed=jest.fn();void command.then(completed);
    await Promise.resolve();events.emit('inactive');
    pending.resolve(JSON.stringify({snapshot:JSON.parse(authenticationSnapshot(8,{policy:false})),result:null}));
    await pending.promise;await Promise.resolve();
    expect(completed).not.toHaveBeenCalled();expect(store.getSnapshot().snapshot).toBeNull();
    expect(store.getSnapshot().displaySnapshot?.revision).toBe(2);
    if(ending==='active'){events.emit('active');emit(authenticationSnapshot(9,{policy:false}));}
    else if(ending==='background')events.emit('background');else disconnect();
    await command;expect(completed).toHaveBeenCalledTimes(1);
    expect(store.getSnapshot().snapshot?.revision).toBe(ending==='active'?9:undefined);
  } finally {disconnect();events.restore();}
});

test('activation before a settings reply refreshes current native fields before acknowledging the successful toggle',async()=>{
  const events=lifecycle();const {store,native,emit,disconnect}=setup();
  try {
    await store.refresh();emit(authenticationSnapshot(2,{authenticating:true}));
    const pending=deferred<string>();native.command.mockReturnValueOnce(pending.promise);
    const command=store.command({type:'settings.set',key:'protectedActions.App Unlock',value:false});
    await Promise.resolve();events.emit('inactive');events.emit('active');emit(authenticationSnapshot(3));
    native.getSnapshot.mockResolvedValueOnce(authenticationSnapshot(9,{policy:false}));
    pending.resolve(JSON.stringify({snapshot:JSON.parse(authenticationSnapshot(8,{policy:false})),result:null}));
    await command;expect(store.getSnapshot().snapshot?.revision).toBe(9);
    expect(store.getSnapshot().privacyCoverRequired).toBe(false);
  } finally {disconnect();events.restore();}
});

test('a failed activation refresh retires the authentication frame, settles the settings queue, and permits an explicit retry',async()=>{
  const events=lifecycle();const {store,native,emit,disconnect}=setup();
  try {
    await store.refresh();emit(authenticationSnapshot(2,{authenticating:true}));
    const pending=deferred<string>();native.command.mockReturnValueOnce(pending.promise);
    const mutation=store.command({type:'settings.set',key:'protectedActions.App Unlock',value:false});
    await Promise.resolve();events.emit('inactive');
    pending.resolve(JSON.stringify({snapshot:JSON.parse(authenticationSnapshot(8,{policy:false})),result:null}));
    await pending.promise;await Promise.resolve();
    native.getSnapshot.mockRejectedValueOnce(new Error('Refresh failed.'));events.emit('active');
    await mutation;
    expect(store.getSnapshot()).toMatchObject({snapshot:null,displaySnapshot:null,error:'Refresh failed.'});
    expect(store.getPresentationHydration().required).toBe(true);
    await expect(store.command({type:'settings.set',key:'haptics',value:false})).rejects.toThrow('Read access changed.');
    native.getSnapshot.mockResolvedValueOnce(authenticationSnapshot(9,{policy:false}));await store.refresh();
    await expect(store.command({type:'settings.set',key:'haptics',value:false})).resolves.toBeNull();
    expect(store.getSnapshot().snapshot?.revision).toBe(9);expect(store.getSnapshot().error).toBeNull();
  } finally {disconnect();events.restore();}
});

test('confirmed all-off keeps only the last displayed frame while revoking authoritative snapshots and reads',async()=>{
  const events=lifecycle();const {store,emit,disconnect}=setup();
  try {
    await store.refresh();emit(policySnapshot(2,false));const epoch=store.getReadEpoch();
    events.emit('inactive');
    expect(store.getSnapshot().snapshot).toBeNull();
    expect(store.getSnapshot().displaySnapshot?.revision).toBe(2);
    expect(store.getReadEpoch()).toBeGreaterThan(epoch);
    events.emit('background');emit(policySnapshot(8,false));
    expect(store.getSnapshot().snapshot).toBeNull();
    expect(store.getSnapshot().displaySnapshot?.revision).toBe(2);
    emit(JSON.stringify({schema:1,fullApp:true,revision:9,presentationBlocked:true,backgroundPrivacyCoverRequired:false}));
    expect(store.getSnapshot().displaySnapshot?.revision).toBe(2);
  } finally {disconnect();events.restore();}
});

test.each([true,undefined])('opt-in or unknown native policy conceals the last frame: %p',async policy=>{
  const events=lifecycle();const {store,emit,disconnect}=setup();
  try {
    await store.refresh();emit(policySnapshot(2,policy));events.emit('inactive');
    expect(store.getSnapshot().snapshot).toBeNull();expect(store.getSnapshot().displaySnapshot).toBeNull();
  } finally {disconnect();events.restore();}
});

test('an all-off resume keeps only its trusted display frame through a delayed inactive marker',async()=>{
  const events=lifecycle();const {store,native,emit,disconnect}=setup();
  try {
    await store.refresh();emit(policySnapshot(2,false));events.emit('inactive');
    const fresh=deferred<string>();native.getSnapshot.mockReturnValueOnce(fresh.promise);
    events.emit('active');
    expect(store.getSnapshot().snapshot).toBeNull();expect(store.getSnapshot().displaySnapshot?.revision).toBe(2);
    emit(JSON.stringify({schema:1,fullApp:true,revision:3,presentationBlocked:true,backgroundPrivacyCoverRequired:false}));
    expect(store.getSnapshot().snapshot).toBeNull();expect(store.getSnapshot().displaySnapshot?.revision).toBe(2);
    fresh.resolve(policySnapshot(4,false));await fresh.promise;await Promise.resolve();
    expect(store.getSnapshot().snapshot?.revision).toBe(4);expect(store.getSnapshot().displaySnapshot).toBeNull();
  } finally {disconnect();events.restore();}
});

test.each([true,undefined])('a resumed concealment marker drops the trusted frame and a late off marker cannot revive it: %p',async policy=>{
  const events=lifecycle();const {store,native,emit,disconnect}=setup();
  try {
    await store.refresh();emit(policySnapshot(2,false));events.emit('background');
    const fresh=deferred<string>();native.getSnapshot.mockReturnValueOnce(fresh.promise);events.emit('active');
    expect(store.getSnapshot().displaySnapshot?.revision).toBe(2);
    emit(JSON.stringify({schema:1,fullApp:true,revision:3,presentationBlocked:true,backgroundPrivacyCoverRequired:policy}));
    expect(store.getSnapshot().snapshot).toBeNull();expect(store.getSnapshot().displaySnapshot).toBeNull();
    emit(JSON.stringify({schema:1,fullApp:true,revision:4,presentationBlocked:true,backgroundPrivacyCoverRequired:false}));
    expect(store.getSnapshot().snapshot).toBeNull();expect(store.getSnapshot().displaySnapshot).toBeNull();
    fresh.resolve(policySnapshot(5,false));await fresh.promise;await Promise.resolve();
    expect(store.getSnapshot().snapshot).toBeNull();
    emit(policySnapshot(6,false));expect(store.getSnapshot().snapshot?.revision).toBe(6);
  } finally {disconnect();events.restore();}
});

test('a delayed same-revision inactive marker cannot revoke an already restored active projection',async()=>{
  const events=lifecycle();const {store,native,emit,disconnect}=setup();
  try {
    await store.refresh();emit(policySnapshot(2,false));events.emit('inactive');
    const fresh=deferred<string>();native.getSnapshot.mockReturnValueOnce(fresh.promise);events.emit('active');
    fresh.resolve(policySnapshot(3,false));await fresh.promise;await Promise.resolve();
    const epoch=store.getReadEpoch();
    emit(JSON.stringify({schema:1,fullApp:true,revision:3,presentationBlocked:true,backgroundPrivacyCoverRequired:false}));
    expect(store.getSnapshot().snapshot?.revision).toBe(3);expect(store.getSnapshot().displaySnapshot).toBeNull();
    expect(store.getReadEpoch()).toBe(epoch);
    emit(JSON.stringify({schema:1,fullApp:true,revision:3,presentationBlocked:true,backgroundPrivacyCoverRequired:true}));
    expect(store.getSnapshot().snapshot).toBeNull();expect(store.getSnapshot().displaySnapshot).toBeNull();
  } finally {disconnect();events.restore();}
});

test('a display-only resumed frame cannot dispatch reads, mutations, navigation or effects',async()=>{
  const events=lifecycle();const {store,native,emit,disconnect}=setup();
  try {
    await store.refresh();emit(policySnapshot(2,false));events.emit('inactive');
    const fresh=deferred<string>();native.getSnapshot.mockReturnValueOnce(fresh.promise);events.emit('active');
    for(const command of [{type:'share.query',id:'balanced'},{type:'settings.set',key:'haptics',value:false},
      {type:'navigation.endTurn'},{type:'haptic',kind:'changed'}] as import('../app/contract').AppCommand[]) {
      await expect(store.command(command)).rejects.toThrow('Read access changed.');
    }
    expect(native.command).not.toHaveBeenCalled();expect(store.getSnapshot().displaySnapshot?.revision).toBe(2);
    fresh.resolve(policySnapshot(3,false));await fresh.promise;await Promise.resolve();
    await store.command({type:'share.query',id:'balanced'});expect(native.command).toHaveBeenCalledTimes(1);
  } finally {disconnect();events.restore();}
});

test.each(['customEntry.enter','vpnEditor.enter','foreground.enter'] as const)('%s can authorize its native visit beneath hydration without admitting mutations or stale authority',async type=>{
  const events=lifecycle();const {store,native,emit,disconnect}=setup();
  try {
    await store.refresh();emit(policySnapshot(2,true));events.emit('inactive');
    await expect(store.command({type,id:'retained-visit'})).rejects.toThrow('Read access changed.');
    expect(native.command).not.toHaveBeenCalled();
    native.getSnapshot.mockReturnValueOnce(new Promise<string>(()=>{}));events.emit('active');emit(policySnapshot(3,true));
    expect(store.getPresentationHydration().required).toBe(true);
    const ticket=store.registerPresentationRead();
    native.command.mockResolvedValue(JSON.stringify({snapshot:JSON.parse(policySnapshot(4,true)),result:null}));
    await store.command({type,id:'retained-visit'});
    expect(native.command).toHaveBeenCalledWith(JSON.stringify({type,id:'retained-visit'}));
    expect(store.getPresentationHydration().required).toBe(true);
    for(const mutation of [{type:'customEntry.save',id:'retained-visit',name:'draft',primary:'1.1.1.1'},
      {type:'vpnEditor.save',id:'retained-visit'},{type:'foreground.submit',id:'retained-visit'}] as import('../app/contract').AppCommand[]) {
      await expect(store.command(mutation)).rejects.toThrow('Read access changed.');
    }
    expect(native.command).toHaveBeenCalledTimes(1);
    store.completePresentationLayout(store.getPresentationHydration().epoch);await Promise.resolve();
    expect(store.getPresentationHydration().required).toBe(true);
    store.settlePresentationRead(ticket);await Promise.resolve();
    expect(store.getPresentationHydration().required).toBe(false);
  } finally {disconnect();events.restore();}
});

test('VPN route admission beneath hydration never admits its saved-settings mutations or a display-only frame',async()=>{
  const events=lifecycle();const {store,native,emit,disconnect}=setup();
  try {
    await store.refresh();emit(policySnapshot(2,true));events.emit('inactive');
    await expect(store.command({type:'vpn.enter'})).rejects.toThrow('Read access changed.');
    expect(native.command).not.toHaveBeenCalled();
    native.getSnapshot.mockReturnValueOnce(new Promise<string>(()=>{}));events.emit('active');emit(policySnapshot(3,true));
    expect(store.getPresentationHydration().required).toBe(true);
    const ticket=store.registerPresentationRead();
    native.command.mockResolvedValue(JSON.stringify({snapshot:JSON.parse(policySnapshot(4,true)),result:null}));
    await store.command({type:'vpn.enter'});
    expect(native.command.mock.calls).toEqual([[JSON.stringify({type:'vpn.enter'})]]);
    expect(store.getPresentationHydration().required).toBe(true);
    for(const command of [{type:'vpn.toggle',key:'setup',value:true},{type:'vpn.begin',id:'new-draft',generation:''},
      {type:'vpn.commit',id:'old-draft'},{type:'vpn.rowToggle',generation:'',index:0,value:true}] as import('../app/contract').AppCommand[]){
      await expect(store.command(command)).rejects.toThrow('Read access changed.');
    }
    expect(native.command).toHaveBeenCalledTimes(1);
    store.completePresentationLayout(store.getPresentationHydration().epoch);store.settlePresentationRead(ticket);await Promise.resolve();
    expect(store.getPresentationHydration().required).toBe(false);
  }finally{disconnect();events.restore();}
});

test('concealed owner retirement reaches native without admitting new reads or mutations',async()=>{
  const events=lifecycle();const {store,native,emit,disconnect}=setup();
  try {
    await store.refresh();emit(policySnapshot(2,true));events.emit('inactive');
    const retiring:import('../app/contract').AppCommand[]=[{type:'vpn.cancel',id:'old-draft'},{type:'customEntry.dismiss',id:'old-form'},
      {type:'domains.cancel',token:'old-domain-page'},{type:'activity.visibility',token:'old-period',visible:false}];
    for(const command of retiring)await store.command(command);
    expect(native.command).toHaveBeenCalledTimes(4);
    expect(store.getSnapshot().snapshot).toBeNull();expect(store.getSnapshot().displaySnapshot).toBeNull();
    await expect(store.command({type:'activity.visibility',token:'new-period',visible:true})).rejects.toThrow('Read access changed.');
    await expect(store.command({type:'vpn.rowToggle',generation:'draft',index:0,value:true})).rejects.toThrow('Read access changed.');
    await expect(store.command({type:'share.query',id:'private'})).rejects.toThrow('Read access changed.');
    expect(native.command).toHaveBeenCalledTimes(4);
  } finally {disconnect();events.restore();}
});

test.each(['inactive','blocked'])('a %s boundary publishes revoked fields atomically with its new hydration epoch',async boundary=>{
  const events=lifecycle();const {store,emit,disconnect}=setup();
  try {
    await store.refresh();emit(policySnapshot(2,true));
    const observations:{revision?:number;display?:number;required:boolean;epoch:number}[]=[];
    store.subscribe(()=>{const state=store.getSnapshot(),gate=store.getPresentationHydration();
      observations.push({revision:state.snapshot?.revision,display:state.displaySnapshot?.revision,...gate});});
    if(boundary==='inactive')events.emit('inactive');
    else emit(JSON.stringify({schema:1,fullApp:true,revision:3,presentationBlocked:true,backgroundPrivacyCoverRequired:true}));
    expect(observations).toEqual([{revision:undefined,display:undefined,epoch:1,required:true}]);
  } finally {disconnect();events.restore();}
});

test('an active opt-out frame replaced by opted-in fields publishes only the new projection under its cover epoch',async()=>{
  const events=lifecycle();const {store,native,emit,disconnect}=setup();
  try {
    await store.refresh();emit(policySnapshot(2,false));events.emit('inactive');
    native.getSnapshot.mockReturnValueOnce(new Promise<string>(()=>{}));events.emit('active');
    const observations:{revision?:number;display?:number;required:boolean;epoch:number}[]=[];
    store.subscribe(()=>{const state=store.getSnapshot(),gate=store.getPresentationHydration();
      observations.push({revision:state.snapshot?.revision,display:state.displaySnapshot?.revision,...gate});});
    emit(policySnapshot(3,true));
    expect(observations).toEqual([{revision:3,display:undefined,epoch:1,required:true}]);
  } finally {disconnect();events.restore();}
});

test('the current last-setting policy controls the next inactive frame, without reusing an earlier off choice',async()=>{
  const events=lifecycle();const {store,emit,disconnect}=setup();
  try {
    await store.refresh();emit(policySnapshot(2,true));emit(policySnapshot(3,false));events.emit('inactive');
    expect(store.getSnapshot().displaySnapshot?.revision).toBe(3);
    events.emit('active');emit(policySnapshot(4,false));emit(policySnapshot(5,true));events.emit('inactive');
    expect(store.getSnapshot().displaySnapshot).toBeNull();
  } finally {disconnect();events.restore();}
});

test.each([true,undefined])('native inactive concealment metadata drops an all-off frame and cannot be undone by background fields: %p',async policy=>{
  const events=lifecycle();const {store,emit,disconnect}=setup();
  try {
    await store.refresh();emit(policySnapshot(2,false));events.emit('inactive');
    expect(store.getSnapshot().displaySnapshot?.revision).toBe(2);
    emit(JSON.stringify({schema:1,fullApp:true,revision:3,presentationBlocked:true,backgroundPrivacyCoverRequired:policy}));
    expect(store.getSnapshot().displaySnapshot).toBeNull();
    emit(policySnapshot(4,false));expect(store.getSnapshot().displaySnapshot).toBeNull();
    expect(store.getSnapshot().snapshot).toBeNull();
  } finally {disconnect();events.restore();}
});

test('normal background metadata can require concealment without admitting its private fields',async()=>{
  const events=lifecycle();const {store,emit,disconnect}=setup();
  try {
    await store.refresh();emit(policySnapshot(2,false));events.emit('background');
    expect(store.getSnapshot().displaySnapshot?.revision).toBe(2);
    emit(policySnapshot(3,true));
    expect(store.getSnapshot().snapshot).toBeNull();expect(store.getSnapshot().displaySnapshot).toBeNull();
  } finally {disconnect();events.restore();}
});

test('an all-off frame cannot replay old query fields on resume and disconnect destroys it',async()=>{
  const events=lifecycle();const {store,native,emit,disconnect}=setup();
  try {
    await store.refresh();emit(policySnapshot(2,false));
    const old=deferred<string>(),fresh=deferred<string>();native.command.mockReturnValueOnce(old.promise);
    const query=store.command({type:'share.query',id:'same-filter'});
    events.emit('inactive');expect(store.getSnapshot().displaySnapshot?.revision).toBe(2);
    native.getSnapshot.mockReturnValueOnce(fresh.promise);events.emit('active');
    expect(store.getSnapshot().snapshot).toBeNull();expect(store.getSnapshot().displaySnapshot?.revision).toBe(2);
    old.resolve(JSON.stringify({snapshot:JSON.parse(policySnapshot(8,false)),result:{code:'stale-private-code'}}));
    await expect(query).rejects.toThrow('Read access changed.');
    expect(store.getSnapshot().snapshot).toBeNull();
    fresh.resolve(policySnapshot(9,false));await fresh.promise;await Promise.resolve();
    expect(store.getSnapshot().snapshot?.revision).toBe(9);
    events.emit('inactive');expect(store.getSnapshot().displaySnapshot?.revision).toBe(9);
    disconnect();expect(store.getSnapshot().displaySnapshot).toBeNull();
  } finally {disconnect();events.restore();}
});

test.each(['ownerRevision','displayClearRevision'])('opaque %s changes revoke readers even when other native scope fields are unchanged',async field=>{
  const {store,emit,disconnect}=setup();
  try{
    await store.refresh();emit(JSON.stringify({...JSON.parse(policySnapshot(2,false)),security:{[field]:'scope-1'}}));const epoch=store.getReadEpoch();
    emit(JSON.stringify({...JSON.parse(policySnapshot(3,false)),security:{[field]:'scope-2'}}));expect(store.getReadEpoch()).toBe(epoch+1);
  }finally{disconnect();}
});
test('fresh authorized mount preparation runs beneath the warm cover while interactive mutations remain fenced',async()=>{
  const events=lifecycle();const {store,native,emit,disconnect}=setup();
  try{
    await store.refresh();emit(policySnapshot(2,true));events.emit('inactive');events.emit('active');emit(policySnapshot(3,true));
    expect(store.getPresentationHydration().required).toBe(true);
    native.command.mockImplementation(async()=>JSON.stringify({snapshot:JSON.parse(policySnapshot(3,true)),result:null}));
    const preparing:import('../app/contract').AppCommand[]=[{type:'filter.review',id:'one'},{type:'filter.open',id:'one'},
      {type:'backup.refresh'},{type:'purchase.refresh'},{type:'discovery.seen',target:'ios27Patch.page'},{type:'sudoku.new'}];
    for(const command of preparing)await store.command(command);
    expect(native.command).toHaveBeenCalledTimes(preparing.length);
    await expect(store.command({type:'settings.set',key:'haptics',value:false})).rejects.toThrow('Read access changed.');
    expect(native.command).toHaveBeenCalledTimes(preparing.length);
  }finally{disconnect();events.restore();}
});


test('native reveal accepts only a current, active, committed frame and preserves its projection',async()=>{
  const events=lifecycle();
  const {store,native,emit,disconnect}=setup();
  try {
    const current={...JSON.parse(snapshot(4)),presentationToken:'frame-4',backgroundPrivacyCoverRequired:true};
    emit(JSON.stringify(current));
    store.acknowledgePresentation('root','old');expect(native.command).not.toHaveBeenCalled();
    store.acknowledgePresentation('root','frame-4');
    expect(JSON.parse(native.command.mock.calls.at(-1)![0])).toEqual({type:'presentation.ready',id:'root',token:'frame-4'});
    await Promise.resolve();expect(store.getSnapshot().snapshot).toEqual(current);
    events.emit('background');
    store.acknowledgePresentation('root','frame-4');expect(native.command).toHaveBeenCalledTimes(1);
    events.emit('active');
    emit(JSON.stringify({...current,revision:5,presentationToken:'frame-5'}));
    store.acknowledgePresentation('root','frame-5');expect(native.command).toHaveBeenCalledTimes(1);
    store.completePresentationLayout(store.getPresentationHydration().epoch);await Promise.resolve();
    store.acknowledgePresentation('root','frame-5');expect(native.command).toHaveBeenCalledTimes(2);
    disconnect();store.acknowledgePresentation('root','frame-5');expect(native.command).toHaveBeenCalledTimes(2);
  }finally{disconnect();events.restore();}
});

test('a failed first projection can reveal its safe retry frame without authorizing private content',async()=>{
  const native={getSnapshot:jest.fn(async()=>{throw new Error('Retry available');}),command:jest.fn(async()=>'{"result":null}'),onSnapshot:()=>({remove(){}})} as unknown as Spec;
  const store=new AppStore(native,{...JSON.parse(snapshot(1)),presentationBlocked:true,presentationToken:'cold',backgroundPrivacyCoverRequired:true},{initial:true});
  const disconnect=store.connect();
  try {
    await store.refresh();
    expect(store.getSnapshot().snapshot).toBeNull();expect(store.getPresentationHydration().required).toBe(true);
    store.acknowledgePresentation('root','cold');
    expect(native.command).toHaveBeenCalledWith(JSON.stringify({type:'presentation.ready',id:'root',token:'cold'}));
    await expect(store.command({type:'stats.query'})).rejects.toThrow('Read access changed.');
  }finally{disconnect();}
});


test('overlapping refreshes share native work only within the same read epoch',async()=>{
  const events=lifecycle();const {store,native,disconnect}=setup();
  try {
    await store.refresh();native.getSnapshot.mockClear();
    const old=deferred<string>(),fresh=deferred<string>();
    native.getSnapshot.mockReturnValueOnce(old.promise).mockReturnValueOnce(fresh.promise);
    const a=store.refresh(),b=store.refresh();
    expect(native.getSnapshot).toHaveBeenCalledTimes(1);
    events.emit('inactive');events.emit('active');
    expect(native.getSnapshot).toHaveBeenCalledTimes(2);
    old.resolve(snapshot(8));await Promise.all([a,b]);
    expect(store.getSnapshot().snapshot).toBeNull();
    fresh.resolve(snapshot(9));await store.refresh();
    expect(store.getSnapshot().snapshot?.revision).toBe(9);
  } finally {disconnect();events.restore();}
});

test.each(['navigation.authorize','activity.query'] as const)('an event and its matching %s reply update the accepted presentation once',async type=>{
  const {store,native,emit,disconnect}=setup();await store.refresh();
  const pending=deferred<string>();native.command.mockReturnValueOnce(pending.promise);
  const listener=jest.fn();store.subscribe(listener);
  try {
    const command=store.command(type==='activity.query'?{type,start:0,end:1}:{type,surface:'appSettings'});
    emit(snapshot(3));const accepted=store.getSnapshot();
    pending.resolve(response(3));await command;
    expect(store.getSnapshot()).toBe(accepted);expect(listener).toHaveBeenCalledTimes(1);
  } finally {disconnect();}
});


test('a failed old refresh cannot replace a newer authorized foreground with an error',async()=>{
  const events=lifecycle();const {store,native,emit,disconnect}=setup();
  try {
    await store.refresh();const old=deferred<string>();native.getSnapshot.mockReturnValueOnce(old.promise);
    const pending=store.refresh();events.emit('inactive');
    native.getSnapshot.mockResolvedValueOnce(snapshot(9));events.emit('active');await store.refresh();
    emit(snapshot(10));old.reject(new Error('Old refresh failed.'));await pending;
    expect(store.getSnapshot().error).toBeNull();expect(store.getSnapshot().snapshot?.revision).toBe(10);
  } finally {disconnect();events.restore();}
});


test('read-only replies deliver data without snapshot construction, app notification or mutation invalidation',async()=>{
  const {store,native,emit,disconnect}=setup();await store.refresh();
  const before=store.getSnapshot(),epoch=store.getInvalidation(),listener=jest.fn();store.subscribe(listener);
  native.command.mockResolvedValue(JSON.stringify({result:{allowed:12,blocked:3}}));
  await expect(store.command({type:'activity.query',start:1,end:2})).resolves.toEqual({allowed:12,blocked:3});
  expect(store.getSnapshot()).toBe(before);expect(listener).not.toHaveBeenCalled();expect(store.getInvalidation()).toBe(epoch);
  emit(snapshot(9));expect(listener).toHaveBeenCalledTimes(1);
  native.command.mockResolvedValue('{}');
  await expect(store.command({type:'stats.query'})).rejects.toThrow('updated state');disconnect();
});

test('navigation preparation and mounted Activity join one pending read, without retaining a completed JS result',async()=>{
  const {store,native,disconnect}=setup();await store.refresh();const pending=deferred<string>();
  native.command.mockReturnValueOnce(pending.promise);
  const input={type:'activity.query' as const,start:1,end:2,hourly:true};
  const first=store.command(input),second=store.command(input);
  expect(first).toBe(second);expect(native.command).toHaveBeenCalledTimes(1);
  pending.resolve(JSON.stringify({result:{allowed:5}}));
  await expect(first).resolves.toEqual({allowed:5});await expect(second).resolves.toEqual({allowed:5});
  native.command.mockResolvedValueOnce(JSON.stringify({result:{allowed:6}}));
  await expect(store.command(input)).resolves.toEqual({allowed:6});expect(native.command).toHaveBeenCalledTimes(2);disconnect();
});

test.each(['inactive','background','owner','policy','clear'] as const)('a shared query cannot deliver private data or join a new read after %s',async boundary=>{
  const events=lifecycle();const {store,native,emit,disconnect}=setup();await store.refresh();
  const input={type:'activity.query' as const,start:1,end:2,hourly:true},pending=deferred<string>();
  native.command.mockReturnValueOnce(pending.promise);
  const first=store.command(input),second=store.command(input);
  const rejected=expect(first).rejects.toThrow('Read access changed.');
  if(boundary==='inactive'||boundary==='background')events.emit(boundary);
  else if(boundary==='clear'){await store.command({type:'logs.clear',kind:'Clear filtering counts'});}
  else emit(JSON.stringify({...JSON.parse(snapshot(5)),security:{ownerRevision:boundary==='owner'?'changed':'owner',readRevision:2},session:{protectedActions:{'View Activities':true}}}));
  pending.resolve(JSON.stringify({result:{allowed:999}}));await rejected;
  await expect(second).rejects.toThrow('Read access changed.');
  if(boundary==='inactive'||boundary==='background')events.emit('active');
  await store.refresh();native.command.mockResolvedValueOnce(JSON.stringify({result:{allowed:1}}));
  await expect(store.command(input)).resolves.toEqual({allowed:1});
  disconnect();events.restore();
});
