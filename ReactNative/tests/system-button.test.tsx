import {fireEvent,render,screen} from '@testing-library/react-native';
import {SystemButton} from '../src/flows/SystemButton.ios';

jest.mock('../specs/LavaSystemButtonNativeComponent',()=>({__esModule:true,default:'NativeSystemButton'}));
jest.mock('../app/presentation',()=>({localized:(value:string)=>value}));
jest.mock('../app/text-metrics',()=>({useTextScale:()=>1.25}));

test('a system button uses native intrinsic metrics and preserves its native style props',()=>{
  render(<SystemButton title="Stage upstream" eventID="visit-1" prominent onPress={()=>{}} testID="button"/>);
  const button=screen.getByTestId('button');
  expect(button).toHaveProp('prominent',true);
  expect(button).toHaveProp('fontSize',21.25);
  fireEvent(button,'sizeChange',{nativeEvent:{width:137,height:34}});
  expect(button).toHaveStyle({width:137,height:34});
  fireEvent(button,'sizeChange',{nativeEvent:{width:0,height:NaN}});
  expect(button).toHaveStyle({width:137,height:34});
});

test('queued native button events cannot act on a replacement detail or a disabled control',()=>{
  const first=jest.fn(),next=jest.fn();
  const view=render(<SystemButton title="Passed" eventID="check-1" onPress={first} testID="button"/>);
  const queued=screen.getByTestId('button').props.onPress;
  view.rerender(<SystemButton title="Passed" eventID="check-2" onPress={next} testID="button"/>);
  queued({nativeEvent:{eventID:'check-1'}});
  expect(first).not.toHaveBeenCalled();expect(next).not.toHaveBeenCalled();
  fireEvent(screen.getByTestId('button'),'press',{nativeEvent:{eventID:'check-2'}});
  expect(next).toHaveBeenCalledTimes(1);
  view.rerender(<SystemButton title="Passed" eventID="check-2" disabled onPress={next} testID="button"/>);
  queued({nativeEvent:{eventID:'check-2'}});
  expect(next).toHaveBeenCalledTimes(1);
});
