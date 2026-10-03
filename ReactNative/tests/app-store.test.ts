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

test('onboarding geometry is presentation-only and does not invalidate reads or replace snapshots',async()=>{
  const {store,native,disconnect}=setup();await store.refresh();
  const before=store.getSnapshot(),epoch=store.getReadEpoch(),invalidation=store.getInvalidation();
  native.command.mockResolvedValueOnce(JSON.stringify({result:true}));
  const frame={x:20,y:180,width:96,height:96};
  await expect(store.command<boolean>({type:'onboarding.geometry',session:'rehearsal',phase:'arriving',layoutRevision:1,frames:{panel:frame,mascot:frame,action:frame}})).resolves.toBe(true);
  expect(store.getSnapshot()).toBe(before);
  expect(store.getReadEpoch()).toBe(epoch);
  expect(store.getInvalidation()).toBe(invalidation);
  disconnect();
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
