import type {PropsWithChildren} from 'react';
import {act, renderHook} from '@testing-library/react-native';
import {useFilterRoute} from '../review/filter-route';
import {ReviewContext, type ReviewState} from '../review/ReviewContext';
import type {AppSnapshot} from '../app/contract';

let mockFocused=true;
const mockBack=jest.fn();
const mockNavigation={goBack:mockBack};
jest.mock('@react-navigation/native',()=>({useIsFocused:()=>mockFocused,useNavigation:()=>mockNavigation,useRoute:()=>({params:{id:'saved'}})}));
beforeEach(()=>{mockFocused=true;mockBack.mockClear();});
function setup(restore=true) {
  let live={session:{filterID:'saved',editing:true},filters:[{id:'saved',frozen:false},{id:'active',frozen:false}],filterPreparationPresented:false} as unknown as AppSnapshot;
  const command=jest.fn().mockResolvedValue(null);
  const app={command};
  const wrapper=({children}:PropsWithChildren)=><ReviewContext.Provider value={{app,live} as unknown as ReviewState}>{children}</ReviewContext.Provider>;
  const hook=renderHook(()=>useFilterRoute(restore),{wrapper});
  return {...hook,command,update:(change:Partial<AppSnapshot>)=>{live={...live,...change};hook.rerender(undefined);},snapshot:()=>live};
}
test('an off-screen automation switch cannot retarget a retained filter detail',async()=>{
  const {result,command,update,snapshot}=setup();
  mockFocused=false;
  update({session:{...snapshot().session,filterID:'active'}});
  expect(result.current).toEqual({id:'saved',ready:false});
  expect(command).not.toHaveBeenCalled();
  mockFocused=true;
  await act(async()=>update({}));
  expect(command).toHaveBeenCalledTimes(1);
  expect(command).toHaveBeenCalledWith({type:'filter.open',id:'saved'});
  expect(result.current.ready).toBe(false);
  update({session:{...snapshot().session,filterID:'saved'}});
  expect(result.current).toEqual({id:'saved',ready:true});
});
test('deleting the retained filter dismisses instead of substituting the active filter',()=>{
  const {result,command,update,snapshot}=setup();
  update({filters:snapshot().filters.filter(filter=>filter.id!=='saved')});
  expect(mockBack).toHaveBeenCalledTimes(1);
  expect(command).not.toHaveBeenCalled();
  expect(result.current.ready).toBe(false);
});
test('an editing sheet closes when another editor takes the shared native target',()=>{
  const {result,command,update,snapshot}=setup(false);
  update({session:{...snapshot().session,filterID:'active'}});
  expect(result.current).toEqual({id:'saved',ready:false});
  expect(mockBack).toHaveBeenCalledTimes(1);
  expect(command).not.toHaveBeenCalled();
});
test('native preparation finishes before its review sheet dismisses once',()=>{
  const {result,update,snapshot}=setup(false);
  update({session:{...snapshot().session,editing:false},filterPreparationPresented:true});
  expect(result.current.ready).toBe(false);
  expect(mockBack).not.toHaveBeenCalled();
  update({filterPreparationPresented:false});
  expect(mockBack).toHaveBeenCalledTimes(1);
});
test('a newly frozen retained detail asks native to discard its stale draft',async()=>{
  const {command,update,snapshot}=setup();
  await act(async()=>update({filters:snapshot().filters.map(filter=>filter.id==='saved'?{...filter,frozen:true}:filter)}));
  expect(command).toHaveBeenCalledTimes(1);
  expect(command).toHaveBeenCalledWith({type:'filter.open',id:'saved'});
});
test('covering a filter detail retains its native draft; only a real pop ends viewing',()=>{
  const {command,update,unmount}=setup();
  mockFocused=false;update({});
  expect(command).not.toHaveBeenCalled();
  mockFocused=true;update({});
  expect(command).not.toHaveBeenCalled();
  unmount();
  expect(command).toHaveBeenCalledTimes(1);
  expect(command).toHaveBeenCalledWith({type:'filter.close',id:'saved'});
});


test('a new editor identity is available without entering the saved library, then cancellation removes it',()=>{
  const {result,update,snapshot}=setup();
  const created=snapshot().filters.find(filter=>filter.id==='saved')!;
  update({filters:snapshot().filters.filter(filter=>filter.id!=='saved'),newFilter:created});
  expect(result.current.ready).toBe(true);
  expect(snapshot().filters.some(filter=>filter.id==='saved')).toBe(false);
  expect(mockBack).not.toHaveBeenCalled();
  update({newFilter:undefined});
  expect(result.current.ready).toBe(false);
  expect(mockBack).toHaveBeenCalledTimes(1);
});
