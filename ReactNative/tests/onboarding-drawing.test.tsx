import {act,render,screen} from '@testing-library/react-native';
import {Animated,AppState,StyleSheet,type AppStateStatus} from 'react-native';
import {Mask,Path,Rect} from 'react-native-svg';
import {OnboardingBackground,OnboardingLavaDrawing} from '../src/OnboardingDrawing';

test('only active crests animate, using noninteractive native transforms with no JS frame loop',()=>{
  AppState.currentState='active';
  let lifecycle:((state:AppStateStatus)=>void)|undefined;
  const motion={start:jest.fn(),stop:jest.fn(),reset:jest.fn()};
  const frame=jest.spyOn(globalThis,'requestAnimationFrame');
  const timing=jest.spyOn(Animated,'timing').mockReturnValue(motion);
  const loop=jest.spyOn(Animated,'loop').mockReturnValue(motion);
  const subscription=jest.spyOn(AppState,'addEventListener').mockImplementation((_event,callback)=>{lifecycle=callback;return {remove:jest.fn()};});
  try{
    render(<OnboardingLavaDrawing width={1366} height={1024} active/>);
    expect(timing).not.toHaveBeenCalled();
    screen.rerender(<OnboardingLavaDrawing width={1366} height={1024} active={false} floor/>);
    expect(timing).not.toHaveBeenCalled();
    expect(screen.UNSAFE_queryAllByType(Mask)).toHaveLength(0);
    const paths=screen.UNSAFE_getAllByType(Path).map(node=>node.props.d);
    screen.rerender(<OnboardingLavaDrawing width={1366} height={1024} active floor/>);
    expect(timing).toHaveBeenCalledTimes(3);expect(motion.start).toHaveBeenCalledTimes(3);
    for(const [,config] of timing.mock.calls)expect(config).toMatchObject({toValue:1,useNativeDriver:true,isInteraction:false});
    expect(timing.mock.calls.map(([,config])=>config.duration)).toEqual([18000,18000,9000]);
    expect(frame).not.toHaveBeenCalled();
    expect(screen.UNSAFE_getAllByType(Path).map(node=>node.props.d)).toEqual(paths);
    for(let index=0;index<3;index++)expect(StyleSheet.flatten(screen.getByTestId(`onboarding.wave.${index}`,{includeHiddenElements:true}).props.style).height).toBeLessThan(100);
    act(()=>lifecycle?.('background'));expect(motion.stop).toHaveBeenCalledTimes(3);
    act(()=>lifecycle?.('active'));expect(motion.start).toHaveBeenCalledTimes(6);
    screen.rerender(<OnboardingLavaDrawing width={1366} height={1024} active={false} floor/>);
    expect(motion.stop).toHaveBeenCalledTimes(6);
  }finally{frame.mockRestore();timing.mockRestore();loop.mockRestore();subscription.mockRestore();}
});

test('Guard reveal fades only its panel and keeps the surrounding cover opaque without raster masks',()=>{
  const frames={panel:{x:20,y:100,width:400,height:300},mascot:{x:40,y:120,width:100,height:100},action:{x:40,y:320,width:300,height:50}};
  render(<OnboardingBackground width={1000} height={800} frames={frames} reveal={0}/>);
  expect(screen.UNSAFE_queryAllByType(Path)).toHaveLength(0);
  expect(screen.UNSAFE_getByType(Rect).props).toMatchObject({width:1000,height:800});
  screen.rerender(<OnboardingBackground width={1000} height={800} frames={frames} reveal={.5}/>);
  expect(screen.UNSAFE_queryAllByType(Mask)).toHaveLength(0);
  expect(screen.UNSAFE_getByType(Path).props).toMatchObject({fillRule:'evenodd',d:'M0 0 H1000 V800 H0 Z M20 100 h400 v300 h-400 Z'});
  expect(screen.UNSAFE_getByType(Rect).props).toMatchObject({...frames.panel,opacity:.5});
  screen.rerender(<OnboardingBackground width={1000} height={800} frames={frames} reveal={1}/>);
  expect(screen.UNSAFE_getByType(Rect).props.opacity).toBe(0);
  screen.rerender(<OnboardingBackground width={1000} height={800} reveal={1}/>);
  expect(screen.UNSAFE_getByType(Rect).props).toMatchObject({width:1000,height:800});
});
