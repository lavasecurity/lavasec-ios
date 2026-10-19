import {act,renderHook} from '@testing-library/react-native';
import {useChoiceRequest,useToggleRequest} from '../src/ui/behavior';
import type {LavaChoiceProps,LavaUIAdapter,LavaTextRole} from '../src/ui/contracts';
import type {lavaTokens} from '../src/generated/tokens';

// Evaluating either factory would mean the shared behavior accidentally crossed
// the platform boundary. These hooks also run without a production adapter.
jest.mock('../specs/NativeLavaReview',()=>{throw new Error('Unexpected iOS review dependency');});
jest.mock('../specs/LavaChoiceNativeComponent',()=>{throw new Error('Unexpected iOS choice dependency');});
jest.mock('../specs/LavaSwitchNativeComponent',()=>{throw new Error('Unexpected iOS switch dependency');});

type Equal<A,B>=[A] extends [B]?[B] extends [A]?true:false:false;
const textRolesRemainCompatible:Equal<LavaTextRole,keyof typeof lavaTokens.typography>=true;
type AdapterChoice=Parameters<LavaUIAdapter['Choice']>[0];
const acceptsStableStringValues:AdapterChoice['value']='value';

test('the semantic contract retains all existing text roles and generic option values',()=>{
  expect(textRolesRemainCompatible).toBe(true);
  expect(acceptsStableStringValues).toBe('value');
});

test('a platform-neutral choice adapter reconciles rejection to the current owner value',async()=>{
  let reject!:(error:Error)=>void;
  const request=jest.fn(()=>new Promise<void>((_resolve,no)=>{reject=no;}));
  const options=[{value:'a',label:'A'},{value:'b',label:'B'},{value:'c',label:'C'}];
  const props:LavaChoiceProps<string>={label:'Choice',options,value:'a',onValueChange:request};
  const hook=renderHook(useChoiceRequest<string>,{initialProps:props});
  act(()=>hook.result.current.change('b'));
  expect(request).toHaveBeenCalledWith('b');
  expect(hook.result.current.displayed).toBe('b');
  hook.rerender({...props,value:'c',options:[options[2]!,options[1]!,options[0]!]});
  expect(hook.result.current.displayed).toBe('b');
  await act(async()=>reject(new Error('Rejected')));
  expect(hook.result.current.displayed).toBe('c');
  expect(hook.result.current.selectionRevision).toBe(1);
  act(()=>hook.result.current.change('removed'));
  expect(request).toHaveBeenCalledTimes(1);
  expect(hook.result.current.selectionRevision).toBe(2);
});

test('a choice acknowledges disabled events and unchanged values but preserves explicit reselection',()=>{
  const request=jest.fn();
  const props:LavaChoiceProps<string>={label:'Choice',options:[{value:'a',label:'A'}],value:'a',onValueChange:request};
  const hook=renderHook(useChoiceRequest<string>,{initialProps:props});
  act(()=>hook.result.current.change('a'));
  expect(request).not.toHaveBeenCalled();
  hook.rerender({...props,reselectValue:'a'});
  act(()=>hook.result.current.change('a'));
  expect(request).toHaveBeenCalledTimes(1);
  hook.rerender({...props,reselectValue:'a',disabled:true});
  act(()=>hook.result.current.change('a'));
  expect(request).toHaveBeenCalledTimes(1);
  expect(hook.result.current.selectionRevision).toBe(3);
});

test('a toggle adapter claims synchronous reentry and clears rejected intent without saving it',async()=>{
  let reject!:(error:Error)=>void;
  let reenter=()=>{};
  const request=jest.fn(()=>{
    reenter();
    return new Promise<void>((_resolve,no)=>{reject=no;});
  });
  const hook=renderHook(()=>useToggleRequest({onValueChange:request}));
  reenter=()=>hook.result.current.change(false);
  act(()=>hook.result.current.change(true));
  expect(request).toHaveBeenCalledTimes(1);
  expect(hook.result.current.intent).toBe(true);
  act(()=>hook.result.current.change(false));
  expect(request).toHaveBeenCalledTimes(1);
  await act(async()=>reject(new Error('Rejected')));
  expect(hook.result.current.intent).toBeUndefined();
  expect(hook.result.current.resetRevision).toBe(1);
  act(()=>hook.result.current.change(false));
  expect(request).toHaveBeenCalledTimes(2);
  await act(async()=>reject(new Error('Rejected again')));
});
