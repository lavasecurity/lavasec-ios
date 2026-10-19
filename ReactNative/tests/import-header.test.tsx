import {act,render} from '@testing-library/react-native';
import {AppState} from 'react-native';
import {ImportFlowAdapter} from '../review/ImportFlowAdapter.ios';
import type {AppStore} from '../app/store';
import type {ImportState} from '../src/flows/import/contract';

let mockApp: AppStore;
let mockToolbar: any;
jest.mock('../review/ReviewContext',()=>({useReview:()=>({app:mockApp})}));
jest.mock('../review/scaffold',()=>({nativeInlineHeader:{},useToolbar:(options:any)=>{mockToolbar=options;},
  toolbarAction:(title:string,symbol:string,onPress:()=>void,disabled:boolean)=>({title,symbol,onPress,disabled})}));
jest.mock('../review/NativeFlowAlert.ios',()=>({useNativeFlowAlert:()=>jest.fn()}));
jest.mock('../src/flows/import/ImportFlow',()=>({ImportFlow:()=>null}));
jest.mock('../specs/LavaImportScannerNativeComponent',()=>({__esModule:true,default:require('react-native').View}));

const originalState=AppState.currentState;
const base:ImportState={stage:'confirm',stageID:'payload-review',direction:'forward',code:'',error:'',cameraDenied:false,
  checkingCatalog:false,catalogCheckFailed:false,decodingPhoto:false,canDismiss:true,alertID:''};
const command=jest.fn(async()=>null);
beforeEach(()=>{
  Object.defineProperty(AppState,'currentState',{configurable:true,value:'active'});
  command.mockClear();
  mockApp={command,subscribe:()=>()=>{},getReadEpoch:()=>1,getSnapshot:()=>({snapshot:{}}),
    getPresentationHydration:()=>({required:false})} as unknown as AppStore;
});
afterAll(()=>Object.defineProperty(AppState,'currentState',{configurable:true,value:originalState}));

test('a payload-only review offers Close and dismisses its exact native stage',async()=>{
  render(<ImportFlowAdapter id="deep-link" state={{...base,closeAtRoot:true}}/>);
  const close=mockToolbar.unstable_headerLeftItems()[0];
  expect(close).toMatchObject({title:'Close',symbol:'close',disabled:false});
  await act(async()=>close.onPress());
  expect(command).toHaveBeenCalledWith({type:'import.dismiss',id:'deep-link',stageID:'payload-review'});
});

test('a review reached from a code or scan retains Back and its native payload owner',async()=>{
  render(<ImportFlowAdapter id="entered-import" state={{...base,closeAtRoot:false}}/>);
  const back=mockToolbar.unstable_headerLeftItems()[0];
  expect(back).toMatchObject({title:'Back',symbol:'back',disabled:false});
  await act(async()=>back.onPress());
  expect(command).toHaveBeenCalledWith({type:'import.back',id:'entered-import',stageID:'payload-review'});
});

test('a retained review Close cannot borrow a replacement stage token',async()=>{
  const view=render(<ImportFlowAdapter id="deep-link" state={{...base,closeAtRoot:true}}/>);
  const outgoingClose=mockToolbar.unstable_headerLeftItems()[0];
  view.rerender(<ImportFlowAdapter id="deep-link" state={{...base,stage:'chooseReplace',stageID:'target-picker',closeAtRoot:false}}/>);
  expect(mockToolbar.unstable_headerLeftItems()[0]).toMatchObject({title:'Back',symbol:'back'});
  await act(async()=>outgoingClose.onPress());
  expect(command).toHaveBeenCalledWith({type:'import.dismiss',id:'deep-link',stageID:'payload-review'});
  expect(command).not.toHaveBeenCalledWith(expect.objectContaining({type:'import.dismiss',stageID:'target-picker'}));
});

test('a concealed review cannot dispatch its retained Close',async()=>{
  render(<ImportFlowAdapter id="deep-link" state={{...base,closeAtRoot:true}}/>);
  const close=mockToolbar.unstable_headerLeftItems()[0];
  Object.defineProperty(AppState,'currentState',{configurable:true,value:'background'});
  await act(async()=>close.onPress());
  expect(command).not.toHaveBeenCalled();
});
