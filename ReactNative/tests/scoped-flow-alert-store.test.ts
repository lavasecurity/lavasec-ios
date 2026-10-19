import {AppState} from 'react-native';
import {AppStore} from '../app/store';
import type {Spec} from '../specs/NativeLavaApp';
import type {AppSnapshot,NativeFlowAlertRequest} from '../app/contract';

const original=AppState.currentState;
beforeAll(()=>Object.defineProperty(AppState,'currentState',{configurable:true,value:'active'}));
afterAll(()=>Object.defineProperty(AppState,'currentState',{configurable:true,value:original}));
const snapshot=(revision:number)=>({schema:1,fullApp:true,revision,presentationToken:'token',security:{readRevision:1}} as AppSnapshot);
const request:NativeFlowAlertRequest={type:'presentation.flowAlert',owner:{kind:'foreground',id:'visit',stageID:'stage'},requestID:'00000000-0000-4000-8000-000000000001',readRevision:1,presentationToken:'token',title:'Title',message:'Message',tint:'confirmation',buttons:[{id:'0',title:'Cancel',role:'cancel'}]};
function setup(){
  let resolve!:(reply:string)=>void,event!:(value:string)=>void;
  const pending=new Promise<string>(done=>{resolve=done;});
  const native={getSnapshot:jest.fn(async()=>JSON.stringify(snapshot(1))),onSnapshot:(callback:(value:string)=>void)=>{event=callback;return{remove(){}};},
    command:jest.fn(async(raw:string)=>JSON.parse(raw).type==='presentation.flowAlert'?pending:JSON.stringify({result:null,snapshot:snapshot(2)}))};
  const store=new AppStore(native as unknown as Spec,snapshot(1)),disconnect=store.connect();
  return {store,native,resolve,emit:(value:unknown)=>event(JSON.stringify(value)),disconnect};
}
test('awaiting a dialog never queues Close or repaints/invalidates from its result-only reply',async()=>{
  const f=setup();
  try{
    const selected=f.store.command(request);
    await f.store.command({type:'foreground.dismiss',id:'visit'});
    expect(f.native.command.mock.calls.map(([raw])=>JSON.parse(raw).type)).toEqual(['presentation.flowAlert','foreground.dismiss']);
    const invalidation=f.store.getInvalidation(),revision=f.store.getSnapshot().snapshot?.revision;
    f.resolve(JSON.stringify({result:'0'}));await expect(selected).resolves.toBe('0');
    expect(f.store.getInvalidation()).toBe(invalidation);
    expect(f.store.getSnapshot().snapshot?.revision).toBe(revision);
  }finally{f.disconnect();}
});
test('concealed cleanup crosses the bridge while a stale dialog selection cannot restore read fields',async()=>{
  const f=setup();
  try{
    const selected=f.store.command(request);
    f.emit({...snapshot(3),presentationBlocked:true,presentationRevoked:true});
    const epoch=f.store.getReadEpoch(),invalidation=f.store.getInvalidation();
    f.native.command.mockImplementationOnce(async()=>JSON.stringify({result:null}));
    await expect(f.store.command({type:'presentation.flowAlert.cancel',owner:request.owner,requestID:request.requestID})).resolves.toBeNull();
    expect(f.store.getReadEpoch()).toBe(epoch);expect(f.store.getInvalidation()).toBe(invalidation);
    f.resolve(JSON.stringify({result:'0'}));
    await expect(selected).rejects.toThrow('Read access changed.');
    expect(f.store.getSnapshot().snapshot).toBeNull();
  }finally{f.disconnect();}
});
