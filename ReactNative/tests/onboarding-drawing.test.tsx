import {act,render,screen} from '@testing-library/react-native';
import {AppState} from 'react-native';
import {Path} from 'react-native-svg';
import {OnboardingLavaDrawing} from '../src/OnboardingDrawing';

test('the static gradient has no frame loop and a paused floor starts only when activated',()=>{
  AppState.currentState='active';
  let frame:((time:number)=>void)|undefined;
  const request=jest.spyOn(globalThis,'requestAnimationFrame').mockImplementation(callback=>{frame=callback;return 12;});
  const cancel=jest.spyOn(globalThis,'cancelAnimationFrame').mockImplementation(()=>{});
  const lifecycle=jest.spyOn(AppState,'addEventListener').mockReturnValue({remove:jest.fn()});
  try{
    render(<OnboardingLavaDrawing width={874} height={402} active/>);
    expect(request).not.toHaveBeenCalled();expect(screen.UNSAFE_queryAllByType(Path)).toHaveLength(0);
    screen.rerender(<OnboardingLavaDrawing width={874} height={402} active={false} floor/>);
    expect(request).not.toHaveBeenCalled();expect(screen.UNSAFE_getAllByType(Path)).toHaveLength(4);
    screen.rerender(<OnboardingLavaDrawing width={874} height={402} active floor/>);
    expect(request).toHaveBeenCalledTimes(1);
    act(()=>frame?.(16));expect(request).toHaveBeenCalledTimes(2);
    screen.rerender(<OnboardingLavaDrawing width={874} height={402} active={false} floor/>);
    expect(cancel).toHaveBeenCalledWith(12);
    screen.unmount();
  }finally{request.mockRestore();cancel.mockRestore();lifecycle.mockRestore();}
});
