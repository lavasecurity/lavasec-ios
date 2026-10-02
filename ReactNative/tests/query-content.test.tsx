import {act,fireEvent,render,renderHook,screen} from '@testing-library/react-native';
import {Text} from 'react-native';
import {QueryContent,useSettledSearch} from '../review/QueryContent';

test('a pending query reserves its accepted content height until the next result arrives',()=>{
  const view=render(<QueryContent pending={false} testID="body"><Text>Result</Text></QueryContent>);
  const body=screen.getByTestId('body');
  fireEvent(body,'layout',{nativeEvent:{layout:{height:420,width:300,x:0,y:0}}});
  view.rerender(<QueryContent pending testID="body"><Text>Loading</Text></QueryContent>);
  expect(screen.getByTestId('body')).toBe(body);
  expect(body).toHaveStyle({minHeight:420});
  view.rerender(<QueryContent pending={false} testID="body"><Text>Empty</Text></QueryContent>);
  expect(body).not.toHaveStyle({minHeight:420});
});
test('typing coalesces a native search and clearing immediately restores the unfiltered scope',()=>{
  jest.useFakeTimers();
  try {
    const hook=renderHook(({value}: {value:string})=>useSettledSearch(value),{initialProps:{value:''}});
    hook.rerender({value:'app'});act(()=>jest.advanceTimersByTime(100));
    hook.rerender({value:'apple'});act(()=>jest.advanceTimersByTime(150));
    expect(hook.result.current).toBe('');
    act(()=>jest.advanceTimersByTime(50));expect(hook.result.current).toBe('apple');
    hook.rerender({value:''});expect(hook.result.current).toBe('');
    hook.unmount();
  } finally {jest.useRealTimers();}
});
