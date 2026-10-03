import {act,renderHook} from '@testing-library/react-native';
import {AppState,type ScrollViewInstance} from 'react-native';
import {useScrollInteractionController,useScrollInteractionLock} from '../src/interaction-lock';

test('independent contact owners release scrolling only after the last contact ends',()=>{
  const setNativeProps=jest.fn();
  const scroll={current:{setNativeProps} as unknown as ScrollViewInstance};
  const view=renderHook(()=>{
    const controller=useScrollInteractionController(scroll);
    return [useScrollInteractionLock(controller),useScrollInteractionLock(controller)] as const;
  });
  act(()=>view.result.current[0](true));
  act(()=>view.result.current[1](true));
  act(()=>view.result.current[0](false));
  expect(setNativeProps).toHaveBeenLastCalledWith({scrollEnabled:false});
  act(()=>view.result.current[1](false));
  expect(setNativeProps).toHaveBeenLastCalledWith({scrollEnabled:true});
  act(()=>view.result.current[0](true));
  view.unmount();
  expect(setNativeProps).toHaveBeenLastCalledWith({scrollEnabled:true});
});

test('background and focus departure release contacts without enabling a normally disabled page',()=>{
  let change!:(state:string)=>void;
  const listener=jest.spyOn(AppState,'addEventListener').mockImplementation((_event,callback)=>{change=callback as typeof change;return {remove:jest.fn()};});
  const setNativeProps=jest.fn();
  const scroll={current:{setNativeProps} as unknown as ScrollViewInstance};
  try{
    const view=renderHook(({enabled,focused}:{enabled:boolean;focused:boolean})=>{
      const controller=useScrollInteractionController(scroll,enabled,focused);
      return useScrollInteractionLock(controller);
    },{initialProps:{enabled:true,focused:true}});
    act(()=>view.result.current(true));
    act(()=>change('background'));
    expect(setNativeProps).toHaveBeenLastCalledWith({scrollEnabled:true});
    act(()=>view.result.current(true));
    view.rerender({enabled:true,focused:false});
    expect(setNativeProps).toHaveBeenLastCalledWith({scrollEnabled:true});
    view.rerender({enabled:false,focused:true});
    act(()=>view.result.current(true));
    act(()=>view.result.current(false));
    expect(setNativeProps).toHaveBeenLastCalledWith({scrollEnabled:false});
    view.unmount();
  }finally{listener.mockRestore();}
});
