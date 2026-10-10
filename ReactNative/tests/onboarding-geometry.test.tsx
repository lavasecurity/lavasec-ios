import {act,fireEvent,render,renderHook,screen,within} from '@testing-library/react-native';
import {Animated,AppState,Dimensions,ScrollView,View,type AppStateStatus} from 'react-native';
import {useOnboardingMeasurements,type Anchor} from '../review/onboarding-geometry';
import {OnboardingChoice,OnboardingCurtain,OnboardingFooter,OnboardingPageScroll,OnboardingProgress,OnboardingStageLayout,OnboardingStep} from '../review/onboarding-scaffold';

jest.mock('@react-navigation/native',()=>({useNavigation:()=>({}),useIsFocused:()=>true}));
jest.mock('../specs/LavaDecorationNativeComponent',()=>({__esModule:true,default:require('react-native').View}));
jest.mock('../specs/LavaTextFieldNativeComponent',()=>({__esModule:true,default:require('react-native').View}));
jest.mock('../src/OnboardingDrawing',()=>({OnboardingLavaDrawing:require('react-native').View}));

type Measurement=[number,number,number,number];
let lifecycle:(value:AppStateStatus)=>void,rotation:()=>void;
beforeEach(()=>{
  jest.useFakeTimers();AppState.currentState='active';
  jest.spyOn(AppState,'addEventListener').mockImplementation((_event,callback)=>{lifecycle=callback;return {remove:jest.fn()};});
  jest.spyOn(Dimensions,'addEventListener').mockImplementation((_event,callback)=>{rotation=()=>callback({window:Dimensions.get('window'),screen:Dimensions.get('screen')});return {remove:jest.fn()};});
});
afterEach(()=>{jest.useRealTimers();jest.restoreAllMocks();});
const anchor=(value:Measurement):Anchor=>({current:{measureInWindow:(callback:(...v:Measurement)=>void)=>callback(...value)} as never});
const anchors=()=>({root:anchor([0,60,400,800]),source:anchor([0,114,400,128]),panel:anchor([16,360,368,330]),mascot:anchor([152,388,96,96]),action:anchor([36,600,328,64])});
const tick=()=>act(async()=>{jest.advanceTimersByTime(160);});
test('a retired native destination cannot starve the setup source or future measurements',async()=>{
  const refs=anchors();refs.panel.current={measureInWindow:()=>{}} as never;
  const hook=renderHook(()=>useOnboardingMeasurements('visit',refs));await act(async()=>{});
  expect(hook.result.current.sourceFrame).toEqual({x:0,y:54,width:400,height:128});
  expect(hook.result.current.frames).toBeUndefined();
  await act(async()=>{jest.advanceTimersByTime(200);});
  refs.panel.current=anchor([16,360,368,330]).current;await tick();
  expect(hook.result.current.frames).toBeDefined();hook.unmount();
});
test('the shared tree measures native insets and deduplicates unchanged destinations',async()=>{
  const refs=anchors();const hook=renderHook(()=>useOnboardingMeasurements('visit',refs));await act(async()=>{});
  expect(hook.result.current.origin).toEqual({x:0,y:60});
  expect(hook.result.current.frames?.mascot).toEqual({x:152,y:328,width:96,height:96});
  const previous=hook.result.current.frames;await tick();expect(hook.result.current.frames).toBe(previous);
  hook.unmount();
});
test('missing, nonfinite and off-screen measurements remove stale destinations',async()=>{
  const refs=anchors();const hook=renderHook(()=>useOnboardingMeasurements('visit',refs));await act(async()=>{});
  expect(hook.result.current.frames).toBeDefined();refs.mascot.current=null;await tick();expect(hook.result.current.frames).toBeUndefined();
  refs.mascot=anchor([152,388,96,96]);await act(async()=>hook.rerender({}));expect(hook.result.current.frames).toBeDefined();
  refs.root.current=anchor([NaN,60,400,800]).current;await tick();expect(hook.result.current.frames).toBeUndefined();expect(hook.result.current.sourceFrame).toBeUndefined();
  refs.root.current=anchor([0,60,400,300]).current;await tick();expect(hook.result.current.frames).toBeUndefined();hook.unmount();
});
test('late callbacks cannot restore frames invalidated by rotation or backgrounding',async()=>{
  const refs=anchors();let pending:((...v:Measurement)=>void)|undefined;
  const hook=renderHook(()=>useOnboardingMeasurements('visit',refs));await act(async()=>{});
  refs.panel.current={measureInWindow:(callback:typeof pending)=>{pending=callback;}} as never;
  await tick();act(()=>rotation());expect(hook.result.current.frames).toBeUndefined();
  await act(async()=>pending?.(16,360,368,330));expect(hook.result.current.frames).toBeUndefined();
  refs.panel.current=anchor([16,360,368,330]).current;await tick();expect(hook.result.current.frames).toBeDefined();
  act(()=>{AppState.currentState='background';lifecycle('background');});expect(hook.result.current.frames).toBeUndefined();expect(hook.result.current.sourceFrame).toBeUndefined();
  await tick();expect(hook.result.current.frames).toBeUndefined();hook.unmount();
});
test('a retired visit cannot deliver a pending measurement into its replacement',async()=>{
  const refs=anchors();let pending:((...v:Measurement)=>void)|undefined;
  refs.panel.current={measureInWindow:(callback:typeof pending)=>{pending=callback;}} as never;
  const hook=renderHook(({visit}:{visit:string})=>useOnboardingMeasurements(visit,refs),{initialProps:{visit:'old'}});const old=pending;
  refs.panel.current=anchor([16,360,368,330]).current;await act(async()=>hook.rerender({visit:'new'}));
  const current=hook.result.current.frames;await act(async()=>old?.(16,900,368,330));expect(hook.result.current.frames).toBe(current);hook.unmount();
});

test.each([false,true])('the welcome floor retires only after its exit, stays retired across rotation, and remounts safely (reduced=%s)',reduced=>{
  const motions:Array<{configuration:{toValue:unknown;duration?:number;useNativeDriver:boolean};finish?: (result:{finished:boolean})=>void;stop:jest.Mock}>=[];
  jest.spyOn(Animated,'timing').mockImplementation((_value,configuration)=>{
    const motion={configuration,finish:undefined as ((result:{finished:boolean})=>void)|undefined,stop:jest.fn()};motions.push(motion);
    return {start:finish=>{motion.finish=finish;},stop:motion.stop,reset:jest.fn()};
  });
  const content=(welcome:boolean,width=402,height=874)=><OnboardingCurtain welcome={welcome} width={width} height={height} reduced={reduced}/>;
  render(content(true));
  expect(screen.getByTestId('onboarding.floor',{includeHiddenElements:true}).props.pointerEvents).toBe('none');
  screen.rerender(content(false));
  const departure=motions.at(-1)!;
  expect(departure.configuration).toMatchObject({toValue:1,duration:reduced?250:1100,useNativeDriver:true});
  expect(screen.getByTestId('onboarding.floor',{includeHiddenElements:true})).toBeTruthy();
  act(()=>departure.finish?.({finished:false}));
  expect(screen.getByTestId('onboarding.floor',{includeHiddenElements:true})).toBeTruthy();
  act(()=>departure.finish?.({finished:true}));
  expect(screen.queryByTestId('onboarding.floor',{includeHiddenElements:true})).toBeNull();
  screen.rerender(content(false,874,402));screen.rerender(content(false));
  expect(screen.queryByTestId('onboarding.floor',{includeHiddenElements:true})).toBeNull();
  screen.rerender(content(true));
  expect(screen.getByTestId('onboarding.floor',{includeHiddenElements:true})).toBeTruthy();
  expect(departure.stop).toHaveBeenCalled();
  act(()=>departure.finish?.({finished:true}));
  expect(screen.getByTestId('onboarding.floor',{includeHiddenElements:true})).toBeTruthy();
});

test('a later onboarding page never mounts a floor when its first canvas arrives or rotates',()=>{
  render(<OnboardingCurtain welcome={false} width={0} height={0} reduced={false}/>);
  screen.rerender(<OnboardingCurtain welcome={false} width={874} height={402} reduced={false}/>);
  screen.rerender(<OnboardingCurtain welcome={false} width={402} height={874} reduced={false}/>);
  expect(screen.queryByTestId('onboarding.floor',{includeHiddenElements:true})).toBeNull();
});

test('landscape keeps progress below the measured mascot and frees the content heading for the native title while retaining scroll and footer ownership',()=>{
  const source:Anchor={current:null};const choose=jest.fn(),page=jest.fn(),next=jest.fn();
  const content=(width:number,height:number,busy=false,vpnInstalled=false)=>{
    const landscape=width>height;
    const progress=<OnboardingProgress page={2} visited={[0,1,2,3,4]} busy={busy} vpnInstalled={vpnInstalled} onPage={page} duration={320} smooth={false}/>;
    return <View><OnboardingStageLayout source={source} progress={landscape?progress:null} width={width} height={height} left={59} right={59}>
      <OnboardingPageScroll landscape={landscape}><OnboardingStep title="First, let’s get Lava ready to help." showTitle={!landscape}><OnboardingChoice title="Install local VPN" symbol="shield" selected={false} disabled={busy} onPress={choose} testID="onboarding.install-vpn"/></OnboardingStep></OnboardingPageScroll>
    </OnboardingStageLayout><OnboardingFooter page={2} busy={busy} vpnInstalled={vpnInstalled} bottom={21} progress={landscape?null:progress} onNext={next}/></View>;
  };
  render(content(402,874));
  const measuredSource=screen.getByTestId('onboarding.source'),scroll=screen.UNSAFE_getByType(ScrollView),action=screen.getByTestId('onboarding.primary');
  expect(screen.getByTestId('onboarding.stage')).toHaveStyle({flex:1,flexDirection:'column',paddingLeft:0,paddingRight:0});
  expect(within(screen.getByTestId('onboarding.footer')).getByTestId('onboarding.steps')).toBeTruthy();
  expect(within(screen.getByTestId('onboarding.source.column')).queryByTestId('onboarding.steps')).toBeNull();
  expect(action).toBeDisabled();
  screen.rerender(content(874,402));
  expect(screen.getByTestId('onboarding.stage')).toHaveStyle({flex:1,flexDirection:'row',paddingLeft:59,paddingRight:59});
  expect(screen.getByTestId('onboarding.source')).toBe(measuredSource);
  expect(measuredSource).toHaveStyle({width:128,height:128});
  expect(measuredSource.props.collapsable).toBe(false);
  expect(screen.getByTestId('onboarding.source.column')).toHaveStyle({width:128});
  expect(screen.getByTestId('onboarding.pages.viewport')).toHaveStyle({flex:1,minWidth:0,overflow:'hidden'});
  expect(screen.UNSAFE_getByType(ScrollView)).toBe(scroll);
  expect(within(scroll).queryByRole('header')).toBeNull();
  expect(within(screen.getByTestId('onboarding.source.column')).getByTestId('onboarding.steps')).toBeTruthy();
  expect(within(screen.getByTestId('onboarding.footer')).queryByTestId('onboarding.steps')).toBeNull();
  expect(screen.getAllByTestId('onboarding.steps')).toHaveLength(1);
  expect(screen.getAllByRole('button',{name:/^Step [1-6] of 6$/})).toHaveLength(6);
  expect(screen.getByRole('button',{name:'Step 3 of 6',selected:true})).toBeTruthy();
  expect(screen.getByRole('button',{name:'Step 4 of 6'})).toBeDisabled();
  expect(screen.getByTestId('onboarding.primary')).toBe(action);
  expect(screen.getByTestId('onboarding.footer')).toHaveStyle({paddingHorizontal:20,paddingBottom:39});
  fireEvent.press(screen.getByRole('button',{name:'Step 1 of 6'}));expect(page).toHaveBeenCalledWith(0);
  fireEvent.press(screen.getByTestId('onboarding.install-vpn'));expect(choose).toHaveBeenCalledTimes(1);
  screen.rerender(content(874,402,true,true));
  expect(screen.getByRole('button',{name:'Step 1 of 6'})).toBeDisabled();
  expect(screen.getByTestId('onboarding.primary')).toBeDisabled();
  screen.rerender(content(402,874,false,true));
  expect(screen.getByTestId('onboarding.stage')).toHaveStyle({flexDirection:'column'});
  expect(screen.getByTestId('onboarding.source')).toBe(measuredSource);
  expect(screen.UNSAFE_getByType(ScrollView)).toBe(scroll);
  expect(screen.getByTestId('onboarding.primary')).toBe(action);
  expect(within(screen.getByTestId('onboarding.footer')).getByTestId('onboarding.steps')).toBeTruthy();
  expect(within(scroll).getByRole('header',{name:'First, let’s get Lava ready to help.'})).toBeTruthy();
  expect(within(screen.getByTestId('onboarding.source.column')).queryByTestId('onboarding.steps')).toBeNull();
  expect(screen.getAllByTestId('onboarding.steps')).toHaveLength(1);
  fireEvent.press(action);expect(next).toHaveBeenCalledTimes(1);
  fireEvent.press(screen.getByTestId('onboarding.install-vpn'));expect(choose).toHaveBeenCalledTimes(2);
});

test('landscape Welcome copy starts near the native header and uses the full stage without moving its retained source anchor',()=>{
  const source:Anchor={current:null};
  const content=(welcome:boolean,width=874,height=402)=><OnboardingStageLayout source={source} width={width} height={height} left={59} right={59} welcome={welcome}><OnboardingPageScroll welcome={welcome} landscape={width>height}><View/></OnboardingPageScroll></OnboardingStageLayout>;
  render(content(true));const measuredSource=screen.getByTestId('onboarding.source');
  expect(screen.getByTestId('onboarding.source.column')).toHaveStyle({position:'absolute',left:59,width:128});
  expect(measuredSource).toHaveStyle({width:128,height:128});
  expect(screen.UNSAFE_getByType(ScrollView).props.contentContainerStyle).toMatchObject({paddingTop:8,paddingHorizontal:24,paddingBottom:24});
  expect(screen.UNSAFE_getByType(ScrollView).props.contentInsetAdjustmentBehavior).toBe('never');
  screen.rerender(content(false));
  expect(screen.getByTestId('onboarding.source')).toBe(measuredSource);
  expect(screen.getByTestId('onboarding.source.column')).toHaveStyle({position:'absolute',left:59,width:128});
  screen.rerender(content(true,402,874));
  expect(screen.UNSAFE_getByType(ScrollView).props.contentContainerStyle.paddingTop).toBe(72);
  expect(screen.getByTestId('onboarding.stage')).toHaveStyle({flexDirection:'column',paddingLeft:0,paddingRight:0});
});
