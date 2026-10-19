import {act,fireEvent,render,screen} from '@testing-library/react-native';
import {AppState,View} from 'react-native';
import {localized} from '../app/presentation';
import {AccountBackupFlow} from '../src/flows/account-backup/AccountBackupFlow';
import {AccountBackupFlowAdapter} from '../review/AccountBackupFlowAdapter.ios';
import {ReviewContext,type ReviewState} from '../review/ReviewContext';
import type {AppStore} from '../app/store';
import type {AppSnapshot} from '../app/contract';
import type {AccountBackupFlowState} from '../src/flows/account-backup/types';
const mockNavigation={setOptions:jest.fn(),isFocused:()=>true};
jest.mock('@react-navigation/native',()=>({useNavigation:()=>mockNavigation,useIsFocused:()=>true}));
jest.mock('react-native-safe-area-context',()=>require('react-native-safe-area-context/jest/mock').default);
jest.mock('../specs/LavaDecorationNativeComponent',()=>({__esModule:true,default:require('react-native').View}));
jest.mock('../specs/LavaInlineSymbolTextNativeComponent',()=>({__esModule:true,default:require('react-native').View}));
jest.mock('../specs/LavaBackupCredentialsNativeComponent',()=>({__esModule:true,default:require('react-native').View}));
jest.mock('../specs/LavaChoiceNativeComponent',()=>require('./native-choice-mock'));
jest.mock('../specs/NativeLavaReview',()=>({__esModule:true,default:{getGuardAccents:()=>JSON.stringify({})}}));
const base:AccountBackupFlowState={kind:'backupSetup',title:'Set Up Encrypted Backup',busy:false,canBack:false,canClose:true,success:false,connections:[],deleting:false,step:'overview',error:'',copied:false,canContinue:false,supportsPasskey:true,selectedPasskey:false,saved:false,understands:false,uploading:false,uploadError:'',mode:'deviceKey',modes:[{id:'deviceKey',title:'This Device',unavailable:false},{id:'passkey',title:'Passkey',unavailable:false},{id:'recoveryCode',title:'Recovery',unavailable:false}],status:null,review:null,resolverConfirmationRequired:false,resolverConfirmed:false};
const mount=(state:Partial<AccountBackupFlowState>={})=>{const command=jest.fn(),confirmAccountDeletion=jest.fn();const props={state:{...base,...state},command,confirmAccountDeletion,credentials:<View testID="native-credential-atom"/>};render(<AccountBackupFlow {...props}/>);return {command,confirmAccountDeletion,props};};
test('setup offers separate native passkey ceremonies and never runs an operation on appearance',()=>{
  const {command}=mount();expect(command).not.toHaveBeenCalled();fireEvent.press(screen.getByRole('button',{name:localized('Set up with Passkey')}));expect(command).toHaveBeenLastCalledWith({action:'setup.begin',passkey:true});
  fireEvent.press(screen.getByRole('button',{name:localized('Set up without Passkey')}));expect(command).toHaveBeenLastCalledWith({action:'setup.begin',passkey:false});
});
test('copy remains independent of explicit acknowledgments and finishing stays gated by native consent',()=>{
  const {command,props}=mount({step:'recoveryPhrase',copied:false,canContinue:false});
  expect(screen.getByTestId('native-credential-atom')).toBeTruthy();expect(command).not.toHaveBeenCalled();
  fireEvent.press(screen.getByRole('button',{name:localized('Turn On Backup')}));expect(command).not.toHaveBeenCalledWith({action:'setup.finish'});
  screen.rerender(<AccountBackupFlow {...props} state={{...props.state,saved:true,understands:true,canContinue:true}}/>);
  fireEvent.press(screen.getByRole('button',{name:localized('Turn On Backup')}));expect(command).toHaveBeenLastCalledWith({action:'setup.finish'});
});
test('busy setup prevents repeat operation and validation cancellation',()=>{
  const {command}=mount({step:'validatePasskey',busy:true});fireEvent.press(screen.getByRole('button',{name:localized('Checking Passkey')}));fireEvent.press(screen.getByRole('button',{name:localized('Cancel')}));expect(command).not.toHaveBeenCalled();
});
test('restore separates review from confirmation and respects resolver consent from the native owner',()=>{
  const {command,props}=mount({kind:'backupRestore',canContinue:true});fireEvent.press(screen.getByRole('button',{name:localized('Review Backup')}));expect(command).toHaveBeenLastCalledWith({action:'restore.prepare'});
  screen.rerender(<AccountBackupFlow {...props} state={{...props.state,review:[{id:'settings',rows:[{title:'Primary DNS',before:'Device',after:'Private'}],notes:[]}],resolverConfirmationRequired:true,canContinue:false}}/>);
  fireEvent.press(screen.getByRole('button',{name:localized('Restore Backup')}));expect(command).not.toHaveBeenCalledWith({action:'restore.confirm'});
  expect(screen.getByText('Device → Private')).toBeTruthy();
});
test('account deletion asks the platform for its confirmation before invoking a destructive command',()=>{
  const {command,confirmAccountDeletion}=mount({kind:'account',connections:[{provider:'apple',title:'private@example.com'}]});
  fireEvent.press(screen.getByRole('button',{name:localized('Delete my Lava account')}));expect(confirmAccountDeletion).toHaveBeenCalledTimes(1);expect(command).not.toHaveBeenCalled();
});
test('a confirmed success displays stable copy and Done without credential material',()=>{
  const {command}=mount({success:true});expect(screen.getByText('Your encrypted backup is set up on this device.')).toBeTruthy();expect(screen.queryByTestId('native-credential-atom')).toBeNull();fireEvent.press(screen.getByRole('button',{name:localized('Done')}));expect(command).toHaveBeenCalledWith({action:'close'});
});

const originalAppState=AppState.currentState;
beforeAll(()=>Object.defineProperty(AppState,'currentState',{configurable:true,value:'active'}));
afterAll(()=>Object.defineProperty(AppState,'currentState',{configurable:true,value:originalAppState}));
const scopedSnapshot=(id:string,state:AccountBackupFlowState)=>({revision:1,foregroundFlow:{id,kind:state.kind,accountBackup:state}} as unknown as AppSnapshot);
const nativeStore=(initial:AppSnapshot)=>{
  let snapshot=initial;const listeners=new Set<()=>void>();const command=jest.fn(async()=>null);
  const app={command,getSnapshot:()=>({snapshot}),subscribe:(listener:()=>void)=>{listeners.add(listener);return()=>listeners.delete(listener);},
    getReadEpoch:()=>2,getPresentationHydration:()=>({required:false,epoch:0})} as unknown as AppStore;
  return {app,command,replace:(next:AppSnapshot,notify=true)=>{snapshot=next;if(notify)for(const listener of listeners)listener();}};
};
const headerOptions=()=>Object.assign({},...mockNavigation.setOptions.mock.calls.map(([options])=>options));
test.each(['account','backupSetup','backupRestore'] as const)('%s Close remains exact-visit cleanup while private actions are concealed',async kind=>{
  mockNavigation.setOptions.mockClear();
  const command=jest.fn(async()=>null);
  const app={command,subscribe:()=>()=>{},getSnapshot:()=>({snapshot:null}),getReadEpoch:()=>2,getPresentationHydration:()=>({required:true})} as unknown as AppStore;
  const state={...base,kind,step:'validatePasskey' as const,canBack:true};
  const content=(id:string,busy=false)=><ReviewContext.Provider value={{app} as ReviewState}><AccountBackupFlowAdapter id={id} state={{...state,busy,canClose:!busy}}/></ReviewContext.Provider>;
  const view=render(content('retained-visit'));
  const side=kind==='account'?'unstable_headerLeftItems':'unstable_headerRightItems';
  const close=headerOptions()[side]()[0];
  expect(close.disabled).toBe(false);
  if(kind==='backupSetup'){
    fireEvent.press(screen.getByRole('button',{name:localized('Validate the passkey')}));
    const back=headerOptions().unstable_headerLeftItems()[0];await act(async()=>back.onPress());
    expect(command).not.toHaveBeenCalled();
  }
  await act(async()=>close.onPress());
  expect(command).toHaveBeenCalledTimes(1);
  expect(command).toHaveBeenLastCalledWith({type:'foreground.dismiss',id:'retained-visit'});
  view.rerender(content('replacement-visit'));
  await act(async()=>close.onPress());
  expect(command).toHaveBeenCalledTimes(1);
  const replacementClose=headerOptions()[side]()[0];
  view.rerender(content('replacement-visit',true));
  // Busy metadata is retained under concealment; native owns the fresh gate.
  expect(headerOptions()[side]()[0].disabled).toBe(false);
  await act(async()=>replacementClose.onPress());
  expect(command).toHaveBeenCalledTimes(1);
  const retainedBusyClose=headerOptions()[side]()[0];await act(async()=>retainedBusyClose.onPress());
  expect(command).toHaveBeenCalledTimes(2);
  expect(command).toHaveBeenLastCalledWith({type:'foreground.dismiss',id:'replacement-visit'});
  const retiredClose=headerOptions()[side]()[0];view.unmount();
  await act(async()=>retiredClose.onPress());
  expect(command).toHaveBeenCalledTimes(2);
});

test('current busy backup keeps its Close control disabled',async()=>{
  mockNavigation.setOptions.mockClear();const command=jest.fn(async()=>null);
  const state={...base,busy:true,canClose:false};const live=scopedSnapshot('busy-visit',state);
  const app={command,getSnapshot:()=>({snapshot:live}),subscribe:()=>()=>{},getPresentationHydration:()=>({required:false})} as unknown as AppStore;
  render(<ReviewContext.Provider value={{app,live} as ReviewState}><AccountBackupFlowAdapter id="busy-visit" state={state}/></ReviewContext.Provider>);
  const close=headerOptions().unstable_headerRightItems()[0];expect(close.disabled).toBe(true);
  await act(async()=>close.onPress());expect(command).not.toHaveBeenCalled();
});


test.each((['account','backupSetup','backupRestore'] as const).flatMap(kind=>(['missing','replaced'] as const).map(scope=>({kind,scope}))))('$kind cleanup ignores retained busy when its scoped projection is $scope but global app-unlock remains active',async({kind,scope})=>{
  mockNavigation.setOptions.mockClear();
  const retained={...base,kind,step:'validatePasskey' as const,busy:true,canClose:false,canBack:true};
  const live=scopedSnapshot('retained-visit',retained);const store=nativeStore(live);
  render(<ReviewContext.Provider value={{app:store.app,live} as ReviewState}><AccountBackupFlowAdapter id="retained-visit" state={retained}/></ReviewContext.Provider>);
  const side=kind==='account'?'unstable_headerLeftItems':'unstable_headerRightItems';
  expect(headerOptions()[side]()[0].disabled).toBe(true);
  // The privacy cover retains this busy body while native finishes its work.
  // A fresh global read does not contain the old app-settings projection; the
  // stale context above deliberately remains present to catch fallback leaks.
  const global=scope==='missing'?{revision:2}:scopedSnapshot('new-visit',{...retained,busy:false,canClose:true});
  act(()=>store.replace(global as AppSnapshot));
  const close=headerOptions()[side]()[0];expect(close.disabled).toBe(false);
  const protectedCommand=screen.UNSAFE_getByType(AccountBackupFlow).props.command;
  await act(async()=>protectedCommand({action:kind==='account'?'account.signOut':'back'}));
  expect(store.command).not.toHaveBeenCalled();
  await act(async()=>close.onPress());
  expect(store.command.mock.calls).toEqual([[{type:'foreground.dismiss',id:'retained-visit'}]]);
});

test.each(['missingAccountBackup','wrongKind'] as const)('%s is not current scoped authority for retained busy metadata',async mismatch=>{
  mockNavigation.setOptions.mockClear();const retained={...base,busy:true,canClose:false};
  const stale=scopedSnapshot('retained-visit',retained);
  const fresh=scopedSnapshot('retained-visit',mismatch==='wrongKind'?{...retained,kind:'account'}:retained);
  if(mismatch==='missingAccountBackup')fresh.foregroundFlow!.accountBackup=null;
  const store=nativeStore(fresh);
  render(<ReviewContext.Provider value={{app:store.app,live:stale} as ReviewState}><AccountBackupFlowAdapter id="retained-visit" state={retained}/></ReviewContext.Provider>);
  const close=headerOptions().unstable_headerRightItems()[0];expect(close.disabled).toBe(false);
  await act(async()=>close.onPress());
  expect(store.command).toHaveBeenCalledWith({type:'foreground.dismiss',id:'retained-visit'});
});

test('a queued Close rechecks scoped busy and revocation before React receives the next snapshot',async()=>{
  mockNavigation.setOptions.mockClear();const ready={...base};const live=scopedSnapshot('current-visit',ready);const store=nativeStore(live);
  render(<ReviewContext.Provider value={{app:store.app,live} as ReviewState}><AccountBackupFlowAdapter id="current-visit" state={ready}/></ReviewContext.Provider>);
  const close=headerOptions().unstable_headerRightItems()[0];expect(close.disabled).toBe(false);
  store.replace(scopedSnapshot('current-visit',{...ready,busy:true,canClose:false}),false);
  await act(async()=>close.onPress());expect(store.command).not.toHaveBeenCalled();
  store.replace({revision:2} as AppSnapshot,false);
  await act(async()=>close.onPress());expect(store.command.mock.calls).toEqual([[{type:'foreground.dismiss',id:'current-visit'}]]);
});

test('isolated adapters use the matching live projection only when no snapshot getter exists',async()=>{
  mockNavigation.setOptions.mockClear();const command=jest.fn(async()=>null);const state={...base,busy:true,canClose:false};
  const app={command} as unknown as AppStore;const live=scopedSnapshot('busy-visit',state);
  render(<ReviewContext.Provider value={{app,live} as ReviewState}><AccountBackupFlowAdapter id="busy-visit" state={state}/></ReviewContext.Provider>);
  const close=headerOptions().unstable_headerRightItems()[0];expect(close.disabled).toBe(true);
  await act(async()=>close.onPress());expect(command).not.toHaveBeenCalled();
});
