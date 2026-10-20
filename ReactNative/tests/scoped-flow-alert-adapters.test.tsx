import {act,fireEvent,render,screen} from '@testing-library/react-native';
import {AppState} from 'react-native';
import {ImportFlowAdapter} from '../review/ImportFlowAdapter.ios';
import {AccountBackupFlowAdapter} from '../review/AccountBackupFlowAdapter.ios';
import type {AppStore} from '../app/store';
import type {ImportState} from '../src/flows/import/contract';
import type {AccountBackupFlowState} from '../src/flows/account-backup/types';
let mockApp:AppStore;
jest.mock('../review/ReviewContext',()=>({useReview:()=>({app:mockApp})}));
jest.mock('../review/scaffold',()=>({nativeInlineHeader:{},toolbarAction:jest.fn(),useToolbar:jest.fn()}));
jest.mock('../review/settings-scaffold',()=>({SettingsIntro:()=>null}));
jest.mock('@react-navigation/native',()=>({useNavigation:()=>({setOptions:jest.fn()})}));
jest.mock('../src/flows/import/ImportFlow',()=>({ImportFlow:()=>null}));
jest.mock('../src/flows/account-backup/AccountBackupFlow',()=>({AccountBackupFlow:({confirmAccountDeletion}:any)=>{
  const {Pressable,Text}=require('react-native');return <Pressable testID="account.confirm" onPress={confirmAccountDeletion}><Text>Delete</Text></Pressable>;
}}));
jest.mock('../specs/LavaImportScannerNativeComponent',()=>({__esModule:true,default:require('react-native').View}));
jest.mock('../specs/LavaBackupCredentialsNativeComponent',()=>({__esModule:true,default:require('react-native').View}));
const original=AppState.currentState;
beforeAll(()=>Object.defineProperty(AppState,'currentState',{configurable:true,value:'active'}));
afterAll(()=>Object.defineProperty(AppState,'currentState',{configurable:true,value:original}));
beforeEach(()=>jest.useFakeTimers());
afterEach(()=>{jest.clearAllTimers();jest.useRealTimers();});
const base:ImportState={stage:'reviewReplacement',stageID:'stage',direction:'forward',code:'',error:'',cameraDenied:false,checkingCatalog:false,catalogCheckFailed:false,decodingPhoto:false,canDismiss:true,alertID:'alert',activeReplacement:{id:'consent',message:'Reviewed replacement'}};
const account={kind:'account',title:'Account',busy:false,canClose:true,success:false,connections:[]} as unknown as AccountBackupFlowState;
function fixture(kind='import'){
  let visible=true,epoch=1;const listeners=new Set<()=>void>();
  const pending:{request:any;resolve:(id:string|null)=>void}[]=[];
  const command=jest.fn((request:any)=>{
    if(request.type==='presentation.flowAlert')return new Promise<string|null>(resolve=>pending.push({request,resolve}));
    return Promise.resolve(null);
  });
  mockApp={command,getReadEpoch:()=>epoch,getPresentationHydration:()=>({required:false}),
    getSnapshot:()=>({snapshot:visible?{presentationToken:`token-${epoch}`,security:{readRevision:epoch},foregroundFlow:{id:'visit',kind,accountBackup:kind==='account'?account:undefined}}:null}),
    subscribe:(listener:()=>void)=>{listeners.add(listener);return()=>listeners.delete(listener);}} as unknown as AppStore;
  return {pending,command,setVisible:(next:boolean)=>{visible=next;++epoch;for(const listener of listeners)listener();}};
}
test('active-filter cancellation clears the native alert, while only the destructive role supplies existing consent',async()=>{
  const f=fixture();render(<ImportFlowAdapter id="visit" state={base}/>);
  expect(f.pending).toHaveLength(1);
  expect(f.pending[0]!.request).toMatchObject({tint:'confirmation',owner:{kind:'foreground',id:'visit',stageID:'stage'},buttons:[{id:'0',role:'cancel'},{id:'1',role:'destructive'}]});
  await act(async()=>f.pending[0]!.resolve('0'));
  expect(f.command).toHaveBeenCalledWith({type:'import.clearAlert',id:'visit',stageID:'stage'});
  expect(f.command.mock.calls.some(([request])=>request.type==='import.confirmActive')).toBe(false);
});
test('the same pending consent can reappear after privacy cancellation only under a fresh admitted epoch',async()=>{
  const f=fixture();render(<ImportFlowAdapter id="visit" state={base}/>);
  await act(async()=>f.setVisible(false));
  expect(f.command).toHaveBeenCalledWith({type:'presentation.flowAlert.cancel',owner:f.pending[0]!.request.owner,requestID:f.pending[0]!.request.requestID});
  await act(async()=>f.pending[0]!.resolve('1'));
  expect(f.command.mock.calls.some(([request])=>request.type==='import.confirmActive')).toBe(false);
  await act(async()=>f.setVisible(true));
  expect(f.pending).toHaveLength(2);
  expect(f.pending[1]!.request.requestID).not.toBe(f.pending[0]!.request.requestID);
  expect(f.pending[1]!.request.readRevision).toBe(3);
  await act(async()=>f.pending[1]!.resolve('1'));
  expect(f.command).toHaveBeenCalledWith({type:'import.confirmActive',confirmation:'consent',id:'visit',stageID:'stage'});
});
test('an unavailable initial presenter retries at most three times without consuming consent or applying',async()=>{
  const f=fixture();render(<ImportFlowAdapter id="visit" state={base}/>);
  for(let i=0;i<3;i++){
    await act(async()=>f.pending[i]!.resolve(null));
    await act(async()=>jest.advanceTimersByTime(250));
  }
  expect(f.pending).toHaveLength(3);
  expect(f.command.mock.calls.every(([request])=>request.type.startsWith('presentation.flowAlert'))).toBe(true);
});
test('a replacement stage retires the old alert and cannot inherit its destructive callback',async()=>{
  const f=fixture();const view=render(<ImportFlowAdapter id="visit" state={base}/>);
  view.rerender(<ImportFlowAdapter id="visit" state={{...base,stageID:'replacement-stage',activeReplacement:undefined}}/>);
  await act(async()=>f.pending[0]!.resolve('1'));
  await act(async()=>jest.advanceTimersByTime(1000));
  expect(f.pending).toHaveLength(1);
  expect(f.command.mock.calls.some(([request])=>request.type==='import.confirmActive')).toBe(false);
});
test.each(['app','confirmation'] as const)('native-projected %s alert tint remains semantic and copy stays verbatim',tint=>{
  const f=fixture();render(<ImportFlowAdapter id="visit" state={{...base,activeReplacement:undefined,alert:{title:'Native title',message:'Native message',tint}}}/>);
  expect(f.pending[0]!.request).toMatchObject({title:'Native title',message:'Native message',tint,buttons:[{id:'0',role:'cancel'}]});
});
test('account confirmation keeps native destructive consent separate from the system presentation command',async()=>{
  const f=fixture('account');render(<AccountBackupFlowAdapter id="visit" state={account}/>);
  fireEvent.press(screen.getByTestId('account.confirm'));
  expect(f.pending[0]!.request).toMatchObject({tint:'confirmation',buttons:[{id:'0',role:'cancel'},{id:'1',role:'destructive'}]});
  expect(f.command.mock.calls.some(([request])=>request.type==='accountBackup.command')).toBe(false);
  await act(async()=>f.pending[0]!.resolve('1'));
  expect(f.command).toHaveBeenCalledWith({type:'accountBackup.command',id:'visit',command:{action:'account.delete'}});
});
