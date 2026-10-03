import {act,fireEvent, render, screen} from '@testing-library/react-native';
import {LavaChoice} from '../src';

jest.mock('../specs/LavaChoiceNativeComponent', () => require('./native-choice-mock'));

const options = [{value: 'light', label: 'Clair'}, {value: 'dark', label: 'Sombre'}];

test('an editor segment can reopen while selected without weakening ordinary selection guards', () => {
  const changed = jest.fn();
  const props = {label:'Range', options:[{value:'today',label:'Today'},{value:'custom',label:'Custom'}], value:'custom', reselectValue:'custom', onValueChange:changed};
  render(<LavaChoice {...props}/>);
  fireEvent.press(screen.getByRole('button',{name:'Custom'}));
  expect(changed).toHaveBeenCalledWith('custom');
  changed.mockClear();
  screen.rerender(<LavaChoice {...props} disabled/>);
  fireEvent.press(screen.getByRole('button',{name:'Custom'}));
  expect(changed).not.toHaveBeenCalled();
});

test('choices request stable values while their owner confirms the selected value', () => {
  const changed = jest.fn();
  const props = {label: 'Appearance', options, value: 'light', onValueChange: changed};
  render(<LavaChoice {...props} />);
  fireEvent.press(screen.getByRole('button', {name: 'Sombre'}));
  expect(changed).toHaveBeenCalledWith('dark');
  expect(screen.getByRole('button', {name: 'Clair'})).toBeSelected();
  screen.rerender(<LavaChoice {...props} value="dark" />);
  expect(screen.getByRole('button', {name: 'Sombre'})).toBeSelected();
});

test('queued native values survive reordering but removed, repeated and disabled choices are ignored', () => {
  const changed = jest.fn();
  const props = {testID: 'choice', label: 'Appearance', options, value: 'light', onValueChange: changed};
  render(<LavaChoice {...props} />);
  screen.rerender(<LavaChoice {...props} options={[...options].reverse()} />);
  fireEvent(screen.getByTestId('choice'), 'valueChange', {nativeEvent: {value: 'dark'}});
  expect(changed).toHaveBeenCalledWith('dark');
  changed.mockClear();
  screen.rerender(<LavaChoice {...props} options={[options[0]!]} />);
  fireEvent(screen.getByTestId('choice'), 'valueChange', {nativeEvent: {value: 'dark'}});
  fireEvent(screen.getByTestId('choice'), 'valueChange', {nativeEvent: {value: 'light'}});
  screen.rerender(<LavaChoice {...props} disabled />);
  fireEvent(screen.getByTestId('choice'), 'valueChange', {nativeEvent: {value: 'dark'}});
  expect(changed).not.toHaveBeenCalled();
  expect(screen.getByRole('button', {name: 'Sombre'})).toBeDisabled();
});

test('the iOS mapping reserves the intrinsic height reported by UIKit', () => {
  render(<LavaChoice testID="choice" label="Appearance" options={options} value="light" onValueChange={() => {}} />);
  fireEvent(screen.getByTestId('choice'), 'sizeChange', {nativeEvent: {height: 44}});
  expect(screen.getByTestId('choice')).toHaveStyle({height: 44});
  for (const height of [0, -1, NaN, Infinity]) {
    fireEvent(screen.getByTestId('choice'), 'sizeChange', {nativeEvent: {height}});
  }
  expect(screen.getByTestId('choice')).toHaveStyle({height: 44});
});

test.each([true,false])('async choice holds requested selection until accepted=%s settlement',async accepted=>{
  let finish!:()=>void;
  const change=jest.fn(()=>new Promise<void>(resolve=>{finish=resolve;}));
  const props={testID:'async-choice',label:'Transport',options,value:'light',onValueChange:change};
  const view=render(<LavaChoice {...props}/>);
  fireEvent.press(screen.getByRole('button',{name:'Sombre'}));
  expect(screen.getByRole('button',{name:'Sombre'})).toBeSelected();
  expect(screen.getByTestId('async-choice')).toHaveProp('selectionRevision',0);
  view.rerender(<LavaChoice {...props} disabled/>);
  expect(screen.getByRole('button',{name:'Sombre'})).toBeSelected();
  if(accepted)view.rerender(<LavaChoice {...props} value="dark"/>);
  await act(async()=>finish());
  expect(screen.getByRole('button',{name:accepted?'Sombre':'Clair'})).toBeSelected();
  expect(screen.getByTestId('async-choice')).toHaveProp('selectionRevision',1);
});

test('stale async acknowledgement cannot retract a newer requested choice',async()=>{
  const finish:Array<()=>void>=[];
  const change=jest.fn((_value:string)=>new Promise<void>(resolve=>finish.push(resolve)));
  render(<LavaChoice label="Appearance" options={options} value="light" onValueChange={change}/>);
  fireEvent.press(screen.getByRole('button',{name:'Sombre'}));
  fireEvent.press(screen.getByRole('button',{name:'Clair'}));
  expect(change.mock.calls.map(call=>call[0])).toEqual(['dark','light']);
  await act(async()=>finish[0]!());
  expect(screen.getByRole('button',{name:'Clair'})).toBeSelected();
  await act(async()=>finish[1]!());
  expect(screen.getByRole('button',{name:'Clair'})).toBeSelected();
});

test('rejected async selection reconciles to the authoritative value',async()=>{
  let reject!:(error:Error)=>void;
  render(<LavaChoice label="Appearance" options={options} value="light" onValueChange={()=>new Promise<void>((_,fail)=>{reject=fail;})}/>);
  fireEvent.press(screen.getByRole('button',{name:'Sombre'}));
  await act(async()=>reject(new Error('cancelled')));
  expect(screen.getByRole('button',{name:'Clair'})).toBeSelected();
});
