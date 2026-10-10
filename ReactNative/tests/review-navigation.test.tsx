import {useSyncExternalStore,type PropsWithChildren} from 'react';
import {AppState,type AppStateStatus} from 'react-native';
import {act,renderHook} from '@testing-library/react-native';
import {useReviewNavigation} from '../review/navigation';
import {initialSession} from '../review/session';
import type {NavigationAction} from '@react-navigation/native';
import {ReviewContext,type ReviewState} from '../review/ReviewContext';
import {usePlusEntry} from '../review/plus-entry';
import {PlusIntentProvider,PlusIntents,usePlusIntents} from '../review/plus-intents';
import {AppStore} from '../app/store';
import type {AppSnapshot} from '../app/contract';
import type {Spec} from '../specs/NativeLavaApp';
let mockFocused=true;
const mockNavigate=jest.fn();
const mockDispatch=jest.fn();
const mockGetState=jest.fn();
let mockRemoval:((event:{data:{action:NavigationAction}})=>void)|undefined;
const mockNavigation={navigate:mockNavigate,dispatch:mockDispatch,getState:mockGetState};
jest.mock('@react-navigation/native',()=>({useIsFocused:()=>mockFocused,useNavigation:()=>mockNavigation,usePreventRemove:(enabled:boolean,callback:(event:{data:{action:NavigationAction}})=>void)=>{mockRemoval=enabled?callback:undefined;}}));
beforeEach(()=>{mockFocused=true;mockNavigate.mockClear();mockDispatch.mockClear();mockGetState.mockReset();mockRemoval=undefined;jest.spyOn(AppState,'addEventListener').mockReturnValue({remove:jest.fn()});});
afterEach(()=>jest.restoreAllMocks());
test.each(['inactive','background'] as const)('a contextual Plus return survives same-owner %s without running under the privacy cover',async phase=>{
  const previous=AppState.currentState;AppState.currentState='active';
  const listeners=new Set<(state:AppStateStatus)=>void>();
  jest.spyOn(AppState,'addEventListener').mockImplementation((_event,listener)=>{
    listeners.add(listener);return {remove:()=>listeners.delete(listener)};
  });
  const full=(revision:number):AppSnapshot=>({schema:1,fullApp:true,revision,
    backgroundPrivacyCoverRequired:true,session:initialSession(),
    security:{ownerRevision:'purchase-owner',unavailable:false}} as unknown as AppSnapshot);
  let snapshot=full(1);
  const native={onSnapshot:()=>({remove(){}}),getSnapshot:jest.fn(async()=>JSON.stringify(snapshot)),
    command:jest.fn(async()=>JSON.stringify({snapshot:full(2),result:null}))} as unknown as Spec;
  const app=new AppStore(native);const disconnect=app.connect();
  const wrapper=({children}:PropsWithChildren)=>{
    const state=useSyncExternalStore(app.subscribe,app.getSnapshot);
    return <ReviewContext.Provider value={{app,live:state.snapshot??undefined,session:initialSession()} as ReviewState}>{children}</ReviewContext.Provider>;
  };
  const hook=renderHook(()=>({upgrade:usePlusEntry(),intents:usePlusIntents()}),{wrapper});
  const resume=jest.fn(async()=>undefined);
  try{
    await act(async()=>{});
    await act(async()=>hook.result.current.upgrade('customDNS',resume));
    const id=mockNavigate.mock.calls[0][1].intent;
    act(()=>{AppState.currentState=phase;listeners.forEach(listener=>listener(phase));});
    expect(app.getSnapshot().snapshot).toBeNull();expect(resume).not.toHaveBeenCalled();
    snapshot=full(3);
    await act(async()=>{AppState.currentState='active';listeners.forEach(listener=>listener('active'));});
    await act(async()=>app.completePresentationLayout(app.getPresentationHydration().epoch));
    const continuation=hook.result.current.intents.take(id);
    expect(continuation).toBe(resume);
    await continuation?.();expect(resume).toHaveBeenCalledTimes(1);
    expect(hook.result.current.intents.take(id)).toBeUndefined();
  }finally{hook.unmount();disconnect();AppState.currentState=previous;}
});
test.each(['owner','policy','app'] as const)('a contextual Plus return is discarded on actual %s retirement',async boundary=>{
  const initial={session:initialSession(),security:{ownerRevision:'purchase-owner',unavailable:false}} as unknown as AppSnapshot;
  let live=initial;let app={command:jest.fn(async()=>undefined)} as unknown as AppStore;
  const wrapper=({children}:PropsWithChildren)=><ReviewContext.Provider value={{app,live,session:initialSession()} as ReviewState}>{children}</ReviewContext.Provider>;
  const hook=renderHook(()=>({upgrade:usePlusEntry(),intents:usePlusIntents()}),{wrapper});
  const resume=jest.fn(async()=>undefined);
  await act(async()=>hook.result.current.upgrade('customDNS',resume));
  const id=mockNavigate.mock.calls[0][1].intent;
  if(boundary==='owner')live={...initial,security:{...initial.security,ownerRevision:'replacement-owner'}};
  if(boundary==='policy')live={...initial,session:{...initial.session,protectedActions:{...initial.session.protectedActions,'Update App Settings':true}}};
  if(boundary==='app')app={command:jest.fn(async()=>undefined)} as unknown as AppStore;
  hook.rerender(undefined);
  expect(hook.result.current.intents.take(id)).toBeUndefined();expect(resume).not.toHaveBeenCalled();
  hook.unmount();
});
test.each(['cancel','blur','background','success'])('contextual Plus registers return work only on an authorized push after %s',async event=>{
  const previousState=AppState.currentState;AppState.currentState='active';
  let resolve!:()=>void;let reject!:(error:Error)=>void;
  const command=jest.fn(()=>new Promise<void>((yes,no)=>{resolve=yes;reject=no;}));
  const listeners=new Set<(state:string)=>void>();
  jest.spyOn(AppState,'addEventListener').mockImplementation((_event,listener)=>{
    const callback=listener as (state:string)=>void;listeners.add(callback);return {remove:()=>listeners.delete(callback)};
  });
  const add=jest.spyOn(PlusIntents.prototype,'add');const remove=jest.spyOn(PlusIntents.prototype,'remove');
  const wrapper=({children}:PropsWithChildren)=><ReviewContext.Provider value={{app:{command}} as unknown as ReviewState}><PlusIntentProvider>{children}</PlusIntentProvider></ReviewContext.Provider>;
  try{
    const resume=jest.fn(async()=>undefined);
    const {result,rerender,unmount}=renderHook(()=>usePlusEntry(),{wrapper});
    act(()=>{result.current('customDNS',resume);result.current('customDNS',resume);});
    expect(command).toHaveBeenCalledTimes(1);expect(add).not.toHaveBeenCalled();
    if(event==='blur'){mockFocused=false;rerender(undefined);}
    if(event==='background')act(()=>listeners.forEach(listener=>listener('background')));
    await act(async()=>event==='cancel'?reject(new Error('Authentication cancelled.')):resolve());
    if(event==='success'){
      expect(add).toHaveBeenCalledTimes(1);expect(add).toHaveBeenCalledWith(resume);
      const params=mockNavigate.mock.calls[0][1];
      expect(params).toEqual({reason:'customDNS',intent:expect.any(String)});
      unmount();expect(remove).toHaveBeenCalledWith(params.intent);
    }else{
      expect(add).not.toHaveBeenCalled();expect(mockNavigate).not.toHaveBeenCalled();unmount();
    }
    expect(resume).not.toHaveBeenCalled();
  }finally{AppState.currentState=previousState;}
});
test.each(['inactive','background','pop','cancel'])('protected navigation handles %s while authentication is pending',async event=>{
  let resolve!:()=>void;let reject!:(error:Error)=>void;
  const command=jest.fn(()=>new Promise<void>((yes,no)=>{resolve=yes;reject=no;}));
  const app={command};const listeners=new Set<(state:string)=>void>();
  const subscription=jest.spyOn(AppState,'addEventListener').mockImplementation((_event,listener)=>{
    const callback=listener as (state:string)=>void;listeners.add(callback);return {remove:()=>{listeners.delete(callback);}};
  });
  try {
    const wrapper=({children}:PropsWithChildren)=><ReviewContext.Provider value={{app} as unknown as ReviewState}>{children}</ReviewContext.Provider>;
    const {result,rerender,unmount}=renderHook(()=>useReviewNavigation(),{wrapper});
    act(()=>{result.current.navigate('Account');result.current.navigate('Privacy');});
    expect(command).toHaveBeenCalledTimes(1);
    if(event==='pop'){mockFocused=false;rerender(undefined);}
    else if(event!=='cancel')act(()=>{for(const listener of listeners)listener(event);for(const listener of listeners)listener('active');});
    await act(async()=>event==='cancel'?reject(new Error('Authentication cancelled.')):resolve());
    if(event==='inactive')expect(mockNavigate).toHaveBeenCalledWith('Account');
    else expect(mockNavigate).not.toHaveBeenCalled();
    unmount();
  }finally{subscription.mockRestore();}
});


test.each(['GO_BACK','POP'].flatMap(type=>['Explore','VPNChaining'].map(origin=>[type,origin])))('protected contextual return intercepts native %s from %s and awaits authorization',async(type,origin)=>{
  let resolve!:()=>void;
  const command=jest.fn(()=>new Promise<void>(yes=>{resolve=yes;}));
  const session=initialSession();session.protectedActions['Update App Settings']=true;
  const wrapper=({children}:PropsWithChildren)=><ReviewContext.Provider value={{app:{command},session} as unknown as ReviewState}>{children}</ReviewContext.Provider>;
  mockGetState.mockReturnValue({index:1,routes:[{name:'DNS',key:'editor'},{name:origin,key:'child'}]});
  renderHook(()=>useReviewNavigation({returnTo:'DNS',returnKey:'editor'}),{wrapper});
  const action={type};
  act(()=>{mockRemoval!({data:{action}});mockRemoval!({data:{action}});});
  expect(command).toHaveBeenCalledTimes(1);
  expect(command).toHaveBeenCalledWith({type:'navigation.authorize',surface:'appSettings'});
  expect(mockDispatch).not.toHaveBeenCalled();
  await act(async()=>resolve());
  expect(mockDispatch).toHaveBeenCalledWith(action);
});

test.each(['cancel','background','blur','replaced'])('contextual authorization cannot pop after %s',async event=>{
  let resolve!:()=>void;let reject!:(error:Error)=>void;
  const command=jest.fn(()=>new Promise<void>((yes,no)=>{resolve=yes;reject=no;}));
  const session=initialSession();session.protectedActions['Update App Settings']=true;
  const listeners=new Set<(state:string)=>void>();
  const subscription=jest.spyOn(AppState,'addEventListener').mockImplementation((_event,listener)=>{
    const callback=listener as (state:string)=>void;listeners.add(callback);return {remove:()=>{listeners.delete(callback);}};
  });
  try{
    const wrapper=({children}:PropsWithChildren)=><ReviewContext.Provider value={{app:{command},session} as unknown as ReviewState}>{children}</ReviewContext.Provider>;
    mockGetState.mockReturnValue({index:1,routes:[{name:'DNS',key:'editor'},{name:'Explore',key:'explore'}]});
    const {rerender}=renderHook(()=>useReviewNavigation({returnTo:'DNS',returnKey:'editor'}),{wrapper});
    // Reentry after background is a new native authorization, never an inherited grant.
    act(()=>{listeners.forEach(listener=>listener('background'));listeners.forEach(listener=>listener('active'));mockRemoval!({data:{action:{type:'POP'}}});});
    expect(command).toHaveBeenCalledWith({type:'navigation.authorize',surface:'appSettings'});
    if(event==='background')act(()=>listeners.forEach(listener=>listener('background')));
    if(event==='blur'){mockFocused=false;rerender(undefined);}
    if(event==='replaced')mockGetState.mockReturnValue({index:1,routes:[{name:'DNS',key:'new-editor'},{name:'Explore',key:'explore'}]});
    await act(async()=>event==='cancel'?reject(new Error('Authentication cancelled.')):resolve());
    expect(mockDispatch).not.toHaveBeenCalled();
  }finally{subscription.mockRestore();}
});

test('unprotected contextual returns keep the native transition without interception',()=>{
  const command=jest.fn();const session=initialSession();
  const wrapper=({children}:PropsWithChildren)=><ReviewContext.Provider value={{app:{command},session} as unknown as ReviewState}>{children}</ReviewContext.Provider>;
  renderHook(()=>useReviewNavigation({returnTo:'DNS',returnKey:'editor'}),{wrapper});
  expect(mockRemoval).toBeUndefined();expect(command).not.toHaveBeenCalled();
});

// Exercise the real store/readiness fence. An app stub with only `command`
// bypasses mayInteractWithPresentation and cannot expose the Face ID race.
function authenticatedNavigation() {
  const previousState=AppState.currentState;
  const listeners=new Set<(state:AppStateStatus)=>void>();
  jest.spyOn(AppState,'addEventListener').mockImplementation((_event,listener)=>{
    listeners.add(listener);return {remove:()=>listeners.delete(listener)};
  });
  const emitState=(state:AppStateStatus)=>{AppState.currentState=state;listeners.forEach(listener=>listener(state));};
  emitState('active');
  const full=(revision:number,authenticating=false):AppSnapshot=>({schema:1,fullApp:true,revision,
    backgroundPrivacyCoverRequired:true,authenticationInProgress:authenticating,
    session:initialSession(),security:{ownerRevision:'original-owner',unavailable:false}} as unknown as AppSnapshot);
  const blocked=(revision:number)=>({schema:1,fullApp:true,revision,presentationBlocked:true,
    backgroundPrivacyCoverRequired:true,authenticationInProgress:false,presentationRevoked:false,
    security:{ownerRevision:'original-owner'}});
  let emit!:(value:string)=>void,authorize!:(value:string)=>void,refresh!:(value:string)=>void;
  const read=new Promise<string>(resolve=>{refresh=resolve;});
  const native={onSnapshot:(callback:typeof emit)=>{emit=callback;return {remove(){}};},
    getSnapshot:jest.fn(async()=>JSON.stringify(full(1))),
    command:jest.fn(()=>new Promise<string>(resolve=>{authorize=resolve;}))};
  const store=new AppStore(native as Spec,full(1),{initial:false});
  const disconnect=store.connect();
  const wrapper=({children}:PropsWithChildren)=><ReviewContext.Provider value={{app:store,session:initialSession()} as ReviewState}>{children}</ReviewContext.Provider>;
  const hook=renderHook(()=>useReviewNavigation(),{wrapper});
  return {store,native,hook,emitState,full,blocked,
    emit:(value:unknown)=>emit(JSON.stringify(value)),
    authenticate:()=>authorize(JSON.stringify({snapshot:blocked(3),result:null})),
    deferRefresh:()=>native.getSnapshot.mockImplementation(()=>read),
    refresh:()=>refresh(JSON.stringify(full(4))),
    close:()=>{hook.unmount();disconnect();AppState.currentState=previousState;}};
}

test.each(['Security','Activity','Account'] as const)('%s opens once from the first tap for every authentication/resume ordering',async target=>{
  for(const ordering of ['auth-before-active','active-before-fields','fields-before-auth']){
    mockNavigate.mockClear();const t=authenticatedNavigation();
    try{
      await act(async()=>{});
      act(()=>{t.hook.result.current.navigate(target);t.hook.result.current.navigate(target);t.emit(t.full(2,true));t.emitState('inactive');t.deferRefresh();});
      expect(t.native.command).toHaveBeenCalledTimes(1);
      if(ordering!=='auth-before-active')act(()=>t.emitState('active'));
      if(ordering==='fields-before-auth')await act(async()=>t.refresh());
      await act(async()=>t.authenticate());
      if(ordering!=='fields-before-auth'){
        expect(mockNavigate).not.toHaveBeenCalled();
        if(ordering==='auth-before-active')act(()=>t.emitState('active'));
        await act(async()=>t.refresh());
      }
      expect(mockNavigate).toHaveBeenCalledTimes(1);expect(mockNavigate).toHaveBeenCalledWith(target);
    }finally{t.close();}
  }
});

test('authenticated navigation waits for the fresh native layout commit as well as active fields',async()=>{
  const t=authenticatedNavigation();
  try{
    await act(async()=>{});
    act(()=>{t.hook.result.current.navigate('Security');t.emitState('inactive');t.deferRefresh();});
    await act(async()=>t.authenticate());act(()=>t.emitState('active'));
    await act(async()=>t.refresh());
    expect(t.store.getSnapshot().snapshot).not.toBeNull();expect(mockNavigate).not.toHaveBeenCalled();
    await act(async()=>t.store.completePresentationLayout(t.store.getPresentationHydration().epoch));
    expect(mockNavigate).toHaveBeenCalledTimes(1);
  }finally{t.close();}
});

test.each(['background','protected-data','owner-change','blur','disconnect','refresh-error'] as const)('an authenticated pending navigation is retired on %s',async boundary=>{
  const t=authenticatedNavigation();
  try{
    await act(async()=>{});
    const command=jest.spyOn(t.store,'command');
    act(()=>{t.hook.result.current.navigate('Security');t.emit(t.full(2,true));t.emitState('inactive');t.deferRefresh();});
    let completion='pending';
    void (command.mock.results[0]!.value as Promise<unknown>).then(()=>{completion='authorized';},()=>{completion='retired';});
    await act(async()=>t.authenticate());
    expect(completion).toBe('pending');
    if(boundary==='background')act(()=>t.emitState('background'));
    if(boundary==='protected-data')act(()=>t.emit({...t.blocked(4),presentationRevoked:true}));
    if(boundary==='owner-change')act(()=>t.emit({...t.blocked(4),security:{ownerRevision:'replacement-owner'}}));
    if(boundary==='blur'){mockFocused=false;t.hook.rerender(undefined);}
    if(boundary==='disconnect'){t.close();await act(async()=>{});expect(completion).toBe('retired');expect(mockNavigate).not.toHaveBeenCalled();return;}
    if(['background','protected-data','owner-change'].includes(boundary)){
      // Retirement must settle the actual store command immediately, even
      // before UIKit resumes or another snapshot arrives. Merely withholding
      // the navigation push would also pass with a stranded pending command.
      await act(async()=>{});expect(completion).toBe('retired');
    }
    if(boundary==='refresh-error')t.native.getSnapshot.mockRejectedValue(new Error('Refresh failed.'));
    act(()=>t.emitState('active'));await act(async()=>t.refresh());
    // Focus retirement belongs to the route hook; all other boundaries retire
    // the store command itself. Neither may push after its source is gone.
    expect(completion).toBe(boundary==='blur'?'authorized':'retired');
    expect(mockNavigate).not.toHaveBeenCalled();
  }finally{t.close();}
});


test.each(['Security','Activity','Account'] as const)('%s reuses the fresh authorized event without waiting for an extra refresh',async target=>{
  const t=authenticatedNavigation();
  try {
    await act(async()=>{});
    act(()=>{t.hook.result.current.navigate(target);t.emit(t.full(2,true));t.emitState('inactive');t.deferRefresh();t.emitState('active');});
    const reads=t.native.getSnapshot.mock.calls.length;
    // Native event has already restored the current foreground projection, but
    // an unrelated getSnapshot call is still pending. It must not delay the tap.
    await act(async()=>t.emit(t.full(4)));
    await act(async()=>t.authenticate());
    expect(t.native.getSnapshot).toHaveBeenCalledTimes(reads);
    expect(mockNavigate).toHaveBeenCalledTimes(1);expect(mockNavigate).toHaveBeenCalledWith(target);
  } finally {t.close();}
});


test.each(['success','cancel','background'] as const)('Activity starts one data read alongside navigation only after current authorization: %s',async outcome=>{
  const previous=AppState.currentState;AppState.currentState='active';
  let resolve!:()=>void;let reject!:(error:Error)=>void;
  const authorization=new Promise<void>((yes,no)=>{resolve=yes;reject=no;});
  const data=new Promise(()=>{});
  const command=jest.fn((input:{type:string})=>input.type==='navigation.authorize'?authorization:data);
  const dates={start:1000,end:1100,label:'Today',includesToday:true};
  const app={command,getSnapshot:()=>({snapshot:{activityDates:dates}})} as unknown as AppStore;
  const listeners=new Set<(state:string)=>void>();
  jest.spyOn(AppState,'addEventListener').mockImplementation((_event,listener)=>{
    const callback=listener as (state:string)=>void;listeners.add(callback);return {remove:()=>listeners.delete(callback)};
  });
  const wrapper=({children}:PropsWithChildren)=><ReviewContext.Provider value={{app} as unknown as ReviewState}>{children}</ReviewContext.Provider>;
  try{
    const {result,unmount}=renderHook(()=>useReviewNavigation(),{wrapper});
    act(()=>result.current.navigate('Activity'));
    expect(command.mock.calls).toEqual([[{type:'navigation.authorize',surface:'activityViewing'}]]);
    expect(mockNavigate).not.toHaveBeenCalled();
    if(outcome==='background')act(()=>listeners.forEach(listener=>listener('background')));
    await act(async()=>outcome==='cancel'?reject(new Error('Authentication cancelled.')):resolve());
    if(outcome==='success'){
      expect(command.mock.calls).toEqual([[{type:'navigation.authorize',surface:'activityViewing'}],[{type:'activity.query',start:1000,end:1100,hourly:true}]]);
      // The unresolved data read must not hold the navigation transition.
      expect(mockNavigate).toHaveBeenCalledWith('Activity');
    }else{expect(command).toHaveBeenCalledTimes(1);expect(mockNavigate).not.toHaveBeenCalled();}
    unmount();
  }finally{AppState.currentState=previous;}
});
