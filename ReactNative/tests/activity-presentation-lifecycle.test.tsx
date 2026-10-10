import {useSyncExternalStore} from 'react';
import {AppState,View,type AppStateStatus} from 'react-native';
import {act,cleanup,fireEvent,render,screen} from '@testing-library/react-native';
import {AppStore} from '../app/store';
import type {AppSnapshot} from '../app/contract';
import type {Spec} from '../specs/NativeLavaApp';
import type {ActivityDates} from '../specs/NativeLavaReview';
import {ActivityScreen} from '../review/ActivityScreen';
import {ReviewContext,type ReviewState} from '../review/ReviewContext';
import {initialSession} from '../review/session';

const today={start:1000,end:1100,label:'Original day',includesToday:true};
const nextDay={start:2000,end:2100,label:'Next day',includesToday:true};
const custom={start:20,end:30,label:'Accepted custom range',includesToday:false};
const mockGetDates=jest.fn<Promise<ActivityDates>,[]>();
const mockGetPreset=jest.fn<Promise<ActivityDates|null>,[string]>();
const mockPickDates=jest.fn<Promise<ActivityDates|null>,[number,number]>();

jest.mock('../specs/NativeLavaReview',()=>({__esModule:true,default:{
  getActivityDates:()=>mockGetDates(),getActivityDatePreset:(preset:string)=>mockGetPreset(preset),
  pickActivityDates:(start:number,end:number)=>mockPickDates(start,end),
}}));
jest.mock('@react-navigation/native',()=>({useIsFocused:()=>true}));
jest.mock('../review/navigation',()=>({useReviewNavigation:()=>({navigate:jest.fn()})}));
jest.mock('../src',()=>({LavaChoice:require('react-native').View}));
jest.mock('../review/primitives',()=>({Screen:require('react-native').View,Copy:require('react-native').Text,Row:require('react-native').View}));
jest.mock('../review/scaffold',()=>({QuietFooter:require('react-native').View}));
jest.mock('../review/story-scaffold',()=>({StorySurface:require('react-native').View}));
jest.mock('../review/settings-scaffold',()=>({SettingsSurface:require('react-native').View}));
jest.mock('../review/activity-scaffold',()=>({ActivityCharts:(props:object)=>{
  const React=require('react');return React.createElement(require('react-native').View,{...props,testID:'activity.accepted-range'});
}}));
jest.mock('../review/PresentationCover',()=>({PresentationCover:require('react-native').View}));

const deferred=<T,>()=>{let resolve!:(value:T)=>void;const promise=new Promise<T>(yes=>{resolve=yes;});return {promise,resolve};};
const snapshot=(revision:number,readRevision=1,backgroundPrivacyCoverRequired=false)=>({
  schema:1,fullApp:true,revision,backgroundPrivacyCoverRequired,
  session:initialSession(),security:{ownerRevision:'activity-owner',sourceRevision:'source-1',readRevision},
  activityDates:today,
} as unknown as AppSnapshot);

let emitState:(state:AppStateStatus)=>void;
let restoreLifecycle:()=>void;
let disconnect:(()=>void)|undefined;
const originalState=AppState.currentState;
beforeEach(()=>{
  Object.defineProperty(AppState,'currentState',{configurable:true,value:'active'});
  const listeners=new Set<(state:AppStateStatus)=>void>();const previous=AppState.addEventListener;
  AppState.addEventListener=(_event,listener)=>{const callback=listener as (state:AppStateStatus)=>void;listeners.add(callback);return {remove:()=>{listeners.delete(callback);}};};
  emitState=state=>act(()=>{Object.defineProperty(AppState,'currentState',{configurable:true,value:state});for(const listener of listeners)listener(state);});
  restoreLifecycle=()=>{AppState.addEventListener=previous;Object.defineProperty(AppState,'currentState',{configurable:true,value:originalState});};
  mockGetDates.mockReset().mockResolvedValue(today);mockGetPreset.mockReset().mockResolvedValue(nextDay);mockPickDates.mockReset().mockResolvedValue(custom);
});
afterEach(()=>{cleanup();disconnect?.();disconnect=undefined;restoreLifecycle();jest.useRealTimers();});

function start(policy=false,initialDates=true){
  let nativeSnapshot=snapshot(1,1,policy);if(!initialDates)delete nativeSnapshot.activityDates;let emit!:(value:string)=>void;
  const reads:ReturnType<typeof deferred<string>>[]=[];
  const command=jest.fn(async(_request:string)=>JSON.stringify({snapshot:nativeSnapshot,result:{allowed:1,blocked:0,uptime:'1m'}}));
  const native={getSnapshot:()=>{const read=deferred<string>();reads.push(read);return read.promise;},command,
    onSnapshot:(callback:(value:string)=>void)=>{emit=callback;return {remove:jest.fn()};}} as unknown as Spec;
  const app=new AppStore(native,nativeSnapshot);disconnect=app.connect();
  function Provider(){
    const current=useSyncExternalStore(app.subscribe,app.getSnapshot);
    const live=current.snapshot??undefined;
    return <ReviewContext.Provider value={{app,live,session:live?.session??initialSession(),look:'original'} as unknown as ReviewState}>
      <View><ActivityScreen/></View>
    </ReviewContext.Provider>;
  }
  const view=render(<Provider/>);
  return {app,command,view,
    publish:(value:AppSnapshot)=>act(()=>{nativeSnapshot=value;emit(JSON.stringify(value));}),
    restore:async(value:AppSnapshot)=>{nativeSnapshot=value;await act(async()=>reads[reads.length-1]!.resolve(JSON.stringify(value)));},
  };
}
const range=()=>screen.getByTestId('activity.accepted-range').props.rangeKey;
const choose=(value:string)=>fireEvent(screen.getByTestId('activity.period'),'valueChange',value);

test.each([false,true])('midnight resume waits for fresh AppStore authority before advancing dates (cover=%p)',async policy=>{
  jest.useFakeTimers();jest.setSystemTime(new Date(2026,8,30,23,59,58));
  const runtime=start(policy);await act(async()=>{});
  expect(range()).toBe('today:1000:1100');
  emitState('background');jest.setSystemTime(new Date(2026,9,1,0,0,1));emitState('active');
  await act(async()=>{});expect(mockGetPreset).not.toHaveBeenCalled();
  await runtime.restore(snapshot(2,2,policy));
  expect(mockGetPreset).toHaveBeenCalledTimes(1);expect(mockGetPreset).toHaveBeenCalledWith('today');
  expect(range()).toBe('today:2000:2100');
  expect(runtime.command.mock.calls.some(([request])=>JSON.parse(request).start===2000)).toBe(true);
  runtime.publish(snapshot(3,2,policy));await act(async()=>jest.advanceTimersByTimeAsync(5000));
  expect(mockGetDates).not.toHaveBeenCalled();expect(mockGetPreset).toHaveBeenCalledTimes(1);
});

test('unfinished initial dates restart after real AppStore revocation and reject the retired reply',async()=>{
  const old=deferred<ActivityDates>(),fresh=deferred<ActivityDates>();
  mockGetDates.mockImplementationOnce(()=>old.promise).mockImplementationOnce(()=>fresh.promise);
  const runtime=start(false,false);expect(mockGetDates).toHaveBeenCalledTimes(1);
  emitState('background');emitState('active');await act(async()=>{});
  expect(mockGetDates).toHaveBeenCalledTimes(1);
  await runtime.restore(snapshot(2,2));expect(mockGetDates).toHaveBeenCalledTimes(2);
  await act(async()=>old.resolve({...today,start:999,label:'Retired initial range'}));
  expect(range()).toBe('today:undefined:undefined');
  await act(async()=>fresh.resolve(nextDay));expect(range()).toBe('today:2000:2100');
  runtime.publish(snapshot(3,2));await act(async()=>{});expect(mockGetDates).toHaveBeenCalledTimes(2);
});

test('revoking a Custom preparation cancels its request before the native date picker can open',async()=>{
  const preparation=deferred<ActivityDates|null>();
  const runtime=start();await act(async()=>{});
  mockGetPreset.mockImplementation(preset=>preset==='fortnight'?preparation.promise:Promise.resolve(nextDay));
  choose('custom');expect(screen.getByTestId('activity.period').props.disabled).toBe(true);
  emitState('background');emitState('active');await runtime.restore(snapshot(2,2));
  await act(async()=>preparation.resolve({...today,start:-13}));
  expect(mockPickDates).not.toHaveBeenCalled();expect(screen.getByTestId('activity.period').props.disabled).toBe(false);
  expect(range()).toBe('today:2000:2100');
});

test('retired native picker and input replies cannot replace a current range; accepted Custom survives resume',async()=>{
  const retiredPicker=deferred<ActivityDates|null>();mockPickDates.mockImplementationOnce(()=>retiredPicker.promise);
  const runtime=start();await act(async()=>{});
  const retiredInput=screen.getByTestId('activity.period').props.onValueChange;
  await act(async()=>choose('custom'));expect(mockPickDates).toHaveBeenCalledTimes(1);
  runtime.publish(snapshot(2,2));await act(async()=>{});
  expect(screen.getByTestId('activity.period').props.disabled).toBe(false);
  await act(async()=>retiredPicker.resolve({...custom,label:'Retired picker range'}));
  expect(screen.queryByText('Retired picker range')).toBeNull();expect(range()).toBe('today:2000:2100');
  const presets=mockGetPreset.mock.calls.length;act(()=>retiredInput('week'));
  expect(mockGetPreset).toHaveBeenCalledTimes(presets);
  await act(async()=>choose('custom'));expect(range()).toBe('custom:20:30');
  expect(screen.getByText('Accepted custom range')).toBeTruthy();
  const acceptedPresets=mockGetPreset.mock.calls.length;
  emitState('background');emitState('active');await runtime.restore(snapshot(3,3));
  expect(range()).toBe('custom:20:30');expect(mockGetPreset).toHaveBeenCalledTimes(acceptedPresets);
});


test('the first Activity frame uses native snapshot dates and starts its summary without a second date request',async()=>{
  const runtime=start();await act(async()=>{});
  expect(mockGetDates).not.toHaveBeenCalled();expect(mockGetPreset).not.toHaveBeenCalled();
  expect(range()).toBe('today:1000:1100');
  const queries=runtime.command.mock.calls.map(([raw])=>JSON.parse(raw)).filter(input=>input.type==='activity.query');
  expect(queries).toEqual([{type:'activity.query',start:1000,end:1100,hourly:true}]);
});
