import {act,fireEvent,render,screen} from '@testing-library/react-native';
import {Alert as NativeAlert,AppState,Pressable,Text} from 'react-native';
import {useNativeFlowAlert} from '../review/NativeFlowAlert.ios';
import {Alert,localized} from '../app/presentation';
import type {AppStore} from '../app/store';
import type {AppSnapshot,NativeFlowAlertOwner,NativeFlowAlertRequest} from '../app/contract';

const originalState=AppState.currentState;
beforeAll(()=>Object.defineProperty(AppState,'currentState',{configurable:true,value:'active'}));
afterAll(()=>Object.defineProperty(AppState,'currentState',{configurable:true,value:originalState}));
afterEach(()=>jest.restoreAllMocks());
function fixture(){
  let resolve!:(id:string|null)=>void;
  const selection=new Promise<string|null>(done=>{resolve=done;});
  const snapshot={presentationToken:'native-token',security:{readRevision:4}} as AppSnapshot;
  let visible:AppSnapshot|null=snapshot,epoch=3;
  const listeners=new Set<()=>void>();
  const command=jest.fn((request:any)=>request.type==='presentation.flowAlert'?selection:Promise.resolve(null));
  const app={command,getSnapshot:()=>({snapshot:visible}),getReadEpoch:()=>epoch,getPresentationHydration:()=>({required:false}),
    subscribe:(listener:()=>void)=>{listeners.add(listener);return()=>listeners.delete(listener);}} as unknown as AppStore;
  return {app,command,resolve,conceal:()=>{visible=null;for(const listener of listeners)listener();},revoke:()=>{++epoch;for(const listener of listeners)listener();}};
}
function Harness({app,owner={kind:'foreground',id:'visit',stageID:'stage'},active=true,selected,capture}:{app:AppStore;owner?:NativeFlowAlertOwner;active?:boolean;selected:()=>void;capture?:(callback:()=>void)=>void}){
  const show=useNativeFlowAlert(app,owner,active);
  const onPress=()=>{show('Replace the filter in effect?','Your previous filter is still active.',[
    {text:'Cancel',style:'cancel'},{text:'Replace active filter',style:'destructive',onPress:selected},
  ],{tint:'confirmation'});};
  capture?.(onPress);
  return <Pressable testID="show.alert" onPress={onPress}><Text>Show</Text></Pressable>;
}

test('the scoped system atom sends localized roles and explicit tint, returning only the chosen local callback',async()=>{
  const {app,command,resolve}=fixture(),selected=jest.fn();
  const native=jest.spyOn(NativeAlert,'alert').mockImplementation(()=>{});
  render(<Harness app={app} selected={selected}/>);
  fireEvent.press(screen.getByTestId('show.alert'));
  const request=command.mock.calls[0]![0] as NativeFlowAlertRequest;
  expect(request).toMatchObject({type:'presentation.flowAlert',owner:{kind:'foreground',id:'visit',stageID:'stage'},readRevision:4,presentationToken:'native-token',
    tint:'confirmation',title:localized('Replace the filter in effect?'),message:'Your previous filter is still active.',
    buttons:[{id:'0',title:'Cancel',role:'cancel'},{id:'1',title:'Replace active filter',role:'destructive'}]});
  expect(request.requestID).toMatch(/^[a-f0-9-]{36}$/);
  expect(selected).not.toHaveBeenCalled();expect(native).not.toHaveBeenCalled();
  await act(async()=>resolve('1'));
  expect(selected).toHaveBeenCalledTimes(1);
  expect(command).toHaveBeenCalledTimes(1); // No mutation is part of the system atom.
  Alert.alert('Lava','Your previous filter is still active.');
  expect(native).toHaveBeenCalledWith('Lava','Your previous filter is still active.',undefined,undefined);
});

test.each(['unmount','conceal','revision','owner','stage','focus'] as const)('%s retires the exact alert and rejects its late destructive callback',async event=>{
  const f=fixture(),selected=jest.fn();
  let oldCallback!:()=>void;
  const view=render(<Harness app={f.app} selected={selected} capture={callback=>{oldCallback??=callback;}}/>);
  fireEvent.press(screen.getByTestId('show.alert'));
  const request=f.command.mock.calls[0]![0];
  await act(async()=>{
    if(event==='unmount')view.unmount();
    else if(event==='conceal')f.conceal();
    else if(event==='revision')f.revoke();
    else if(event==='focus')view.rerender(<Harness app={f.app} selected={selected} active={false}/>);
    else view.rerender(<Harness app={f.app} selected={selected} owner={{kind:'foreground',id:event==='owner'?'replacement':'visit',stageID:event==='stage'?'next':'stage'}}/>);
  });
  expect(f.command.mock.calls[1]).toEqual([{type:'presentation.flowAlert.cancel',owner:request.owner,requestID:request.requestID}]);
  await act(async()=>f.resolve('1'));
  expect(selected).not.toHaveBeenCalled();
  oldCallback();expect(f.command).toHaveBeenCalledTimes(2);
});

test('unrecognized results and silent presentation cancellations cannot invoke an action',async()=>{
  const f=fixture(),selected=jest.fn();
  render(<Harness app={f.app} selected={selected}/>);fireEvent.press(screen.getByTestId('show.alert'));
  await act(async()=>f.resolve('unknown'));
  expect(selected).not.toHaveBeenCalled();
});
