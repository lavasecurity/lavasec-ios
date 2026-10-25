import {act,fireEvent,render,renderHook,screen,within} from '@testing-library/react-native';
import {Animated,AppState,Dimensions,ScrollView,View,type AppStateStatus} from 'react-native';
import {useOnboardingMeasurements,type Anchor} from '../review/onboarding-geometry';
import {OnboardingTravel} from '../review/onboarding-motion';
import {OnboardingSetupAction,OnboardingCurtain,OnboardingFooter,OnboardingPageContent,OnboardingProgress,OnboardingStageLayout,OnboardingStep} from '../review/onboarding-scaffold';

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
test.each([-500,0,850])('a source scrolled to window y=%s still reaches the visible Guard destination',async y=>{
  const refs=anchors();const hook=renderHook(()=>useOnboardingMeasurements('visit',refs));await act(async()=>{});
  refs.source.current=anchor([136,y,128,128]).current;await tick();
  const source=hook.result.current.sourceFrame;
  expect(source).toEqual({x:136,y:y-60,width:128,height:128});
  const destination=hook.result.current.frames!.mascot;
  const travel=new OnboardingTravel(source!,destination,0);
  expect(travel.position(2)).toEqual({x:destination.x+destination.width/2,y:destination.y+destination.height/2});
  refs.source.current=null;await tick();expect(hook.result.current.sourceFrame).toBeUndefined();
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

test('rotation keeps the centered scene, body heading, scroll owner and footer controls',()=>{
  const source:Anchor={current:null};const choose=jest.fn(),page=jest.fn(),next=jest.fn();
  const content=(width:number,height:number,busy=false,vpnInstalled=false)=>{
    const landscape=width>height;
    const progress=<OnboardingProgress page={2} visited={[0,1,2,3,4]} busy={busy} vpnInstalled={vpnInstalled} onPage={page} duration={320} smooth={false}/>;
    return <View><OnboardingStageLayout source={source} width={width} height={height} left={59} right={59}>
      <OnboardingPageContent><OnboardingStep title="First, let’s get Lava ready to help." showTitle><OnboardingSetupAction title="Install local VPN" symbol="shield" completed={false} disabled={busy} onPress={choose} testID="onboarding.install-vpn"/></OnboardingStep></OnboardingPageContent>
    </OnboardingStageLayout><OnboardingFooter page={2} busy={busy} vpnInstalled={vpnInstalled} bottom={21} progress={progress} onNext={next}/></View>;
  };
  render(content(402,874));
  const measuredSource=screen.getByTestId('onboarding.source'),scroll=screen.UNSAFE_getByType(ScrollView),action=screen.getByTestId('onboarding.primary');
  expect(screen.getByTestId('onboarding.composition')).toHaveStyle({flexDirection:'column',alignItems:'center'});
  expect(within(screen.getByTestId('onboarding.footer')).getByTestId('onboarding.steps')).toBeTruthy();
  expect(within(screen.getByTestId('onboarding.source.column')).queryByTestId('onboarding.steps')).toBeNull();
  expect(action).toBeDisabled();
  screen.rerender(content(874,402));
  expect(screen.getByTestId('onboarding.composition')).toHaveStyle({flexDirection:'row',alignItems:'center'});
  expect(screen.getByTestId('onboarding.source')).toBe(measuredSource);
  expect(measuredSource).toHaveStyle({width:128,height:128});
  expect(measuredSource.props.collapsable).toBe(false);
  expect(screen.getByTestId('onboarding.source.column')).toHaveStyle({width:128});
  expect(screen.getByTestId('onboarding.pages.viewport')).toHaveStyle({width:'100%',flexShrink:1,minWidth:0});
  expect(screen.UNSAFE_getByType(ScrollView)).toBe(scroll);
  expect(within(scroll).getByRole('header',{name:'First, let’s get Lava ready to help.'})).toBeTruthy();
  expect(within(screen.getByTestId('onboarding.source.column')).queryByTestId('onboarding.steps')).toBeNull();
  expect(within(screen.getByTestId('onboarding.footer')).getByTestId('onboarding.steps')).toBeTruthy();
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
  expect(screen.getByTestId('onboarding.composition')).toHaveStyle({flexDirection:'column'});
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

test.each([[402,874],[874,402],[768,1024],[1366,1024],[700,600]])('the %s×%s scene centers with flex alignment and lets overflow scroll', (width,height)=>{
  const source:Anchor={current:null};
  const content=(welcome:boolean)=><OnboardingStageLayout source={source} width={width} height={height} left={0} right={0} welcome={welcome}><OnboardingPageContent><View/></OnboardingPageContent></OnboardingStageLayout>;
  render(content(true));const measuredSource=screen.getByTestId('onboarding.source',{includeHiddenElements:true});
  const scroll=screen.UNSAFE_getByType(ScrollView);
  expect(scroll.props.contentContainerStyle).toMatchObject({flexGrow:1,justifyContent:'center',paddingVertical:24});
  expect(scroll.props.contentContainerStyle.height).toBeUndefined();
  expect(scroll.props.contentInsetAdjustmentBehavior).toBe('never');
  expect(scroll.props.removeClippedSubviews).toBe(false);
  expect(screen.getByTestId('onboarding.composition')).toHaveStyle({width:'100%',alignSelf:'center',alignItems:'center'});
  expect(screen.getByTestId('onboarding.source.column',{includeHiddenElements:true})).toHaveStyle({position:'absolute',opacity:0});
  screen.rerender(content(false));
  expect(screen.getByTestId('onboarding.source')).toBe(measuredSource);
  expect(screen.UNSAFE_getByType(ScrollView)).toBe(scroll);
  expect(screen.getByTestId('onboarding.source.column')).not.toHaveStyle({position:'absolute'});
});
