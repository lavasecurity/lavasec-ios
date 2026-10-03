import {fireEvent,render,screen,renderHook} from '@testing-library/react-native';
import {FeedbackProvider,useFeedback} from '../src/feedback';
import {LavaChoice} from '../src/choice.ios';
jest.mock('../specs/LavaChoiceNativeComponent',()=>require('./native-choice-mock'));

test('unsupported hosts have a harmless feedback sink',()=>{
  const hook=renderHook(useFeedback);
  expect(()=>hook.result.current.emit({semantic:'succeeded',controlID:'test'})).not.toThrow();
});
test('shared choice reports direct changed selections, never reconciliation or disabled events',()=>{
  const emit=jest.fn();
  const props={testID:'choice',label:'Choice',options:[{value:'a',label:'A'},{value:'b',label:'B'}],value:'a',onValueChange:jest.fn()};
  render(<FeedbackProvider value={{emit}}><LavaChoice {...props}/></FeedbackProvider>);
  fireEvent(screen.getByTestId('choice'),'valueChange',{nativeEvent:{value:'a'}});
  expect(emit).not.toHaveBeenCalled();
  fireEvent(screen.getByTestId('choice'),'valueChange',{nativeEvent:{value:'b'}});
  expect(emit).toHaveBeenCalledWith({semantic:'selected',controlID:expect.stringMatching(/^choice@/),value:'b'});
  emit.mockClear();
  screen.rerender(<FeedbackProvider value={{emit}}><LavaChoice {...props} value="b" disabled/></FeedbackProvider>);
  fireEvent(screen.getByTestId('choice'),'valueChange',{nativeEvent:{value:'a'}});
  expect(emit).not.toHaveBeenCalled();
});

test('selection identities remain stable on rerender and change on remount',()=>{
  const emit=jest.fn();
  const wrapper=({children}:{children:React.ReactNode})=><FeedbackProvider value={{emit}}>{children}</FeedbackProvider>;
  const first=renderHook(useFeedback,{wrapper});
  first.result.current.emit({semantic:'selected',controlID:'sudoku.notes',value:'true'});
  const firstID=emit.mock.calls.at(-1)![0].controlID;
  first.rerender({});
  first.result.current.emit({semantic:'selected',controlID:'sudoku.notes',value:'false'});
  expect(emit.mock.calls.at(-1)![0].controlID).toBe(firstID);
  first.unmount();
  const second=renderHook(useFeedback,{wrapper});
  second.result.current.emit({semantic:'selected',controlID:'sudoku.notes',value:'true'});
  expect(emit.mock.calls.at(-1)![0].controlID).not.toBe(firstID);
  second.result.current.emit({semantic:'succeeded',controlID:'operation',value:'owned-token'});
  expect(emit).toHaveBeenLastCalledWith({semantic:'succeeded',controlID:'operation',value:'owned-token'});
});
test('native page dots retain system feedback ownership',()=>{
  const emit=jest.fn();
  render(<FeedbackProvider value={{emit}}><LavaChoice testID="pages" label="Pages" presentation="pages" options={[{value:'a',label:'A'},{value:'b',label:'B'}]} value="a" onValueChange={()=>{}}/></FeedbackProvider>);
  fireEvent(screen.getByTestId('pages'),'valueChange',{nativeEvent:{value:'b'}});
  expect(emit).not.toHaveBeenCalled();
});
