import {act,fireEvent,render,screen,within} from '@testing-library/react-native';
import {Animated,AppState,StyleSheet,View} from 'react-native';
import * as SafeArea from 'react-native-safe-area-context';
import type {AppCommand,OnboardingSetup} from '../app/contract';
import {LavaActionButton} from '../src';
import {OnboardingFlow,OnboardingPages} from '../review/OnboardingFlow';
import {OnboardingGeometryContext,type Anchor} from '../review/onboarding-geometry';
import {onboardingPageMotion} from '../review/onboarding-motion';
import {OnboardingCurtain,OnboardingStep,onboardingPageTitle} from '../review/onboarding-scaffold';
import {useToolbar} from '../review/scaffold';
import {useReview} from '../review/ReviewContext';
let mockReduced=false,mockCrossFade=false;

jest.mock('@react-navigation/native',()=>({useNavigation:()=>({}),useIsFocused:()=>true,usePreventRemove:jest.fn()}));
jest.mock('react-native-safe-area-context',()=>({useSafeAreaInsets:jest.fn(()=>({top:0,bottom:21,left:59,right:59}))}));
jest.mock('../review/ReviewContext',()=>({useReview:jest.fn(()=>({look:'lava'})),useOptionalReview:()=>undefined,useRouteBodyConcealed:()=>false}));
jest.mock('../review/navigation-scaffold',()=>({...jest.requireActual('../review/navigation-scaffold'),useReducedMotionPreference:()=>mockReduced,useCrossFadePreference:()=>mockCrossFade}));
jest.mock('../review/scaffold',()=>({...jest.requireActual('../review/scaffold'),useToolbar:jest.fn()}));
jest.mock('../specs/LavaDecorationNativeComponent',()=>({__esModule:true,default:require('react-native').View}));
jest.mock('../specs/LavaTextFieldNativeComponent',()=>({__esModule:true,default:require('react-native').View}));
jest.mock('../src/GuardianDrawing',()=>({GuardianDrawing:require('react-native').View}));
jest.mock('../src/OnboardingDrawing',()=>({OnboardingBackground:require('react-native').View,OnboardingLavaDrawing:require('react-native').View}));

const setup=(page:number):OnboardingSetup=>({id:'visit',mock:true,page,history:page?[0,1]:[],visited:[0,1,2],level:'balanced',fallback:true,dnsProfile:false,supportsDNSProfile:true,vpnInstalled:false,notifications:false,busy:'',error:'',phase:'setup'});
type Motion={value:unknown;config:{duration?:number;delay?:number;toValue:unknown;useNativeDriver?:boolean};finish?: (result:{finished:boolean})=>void;stop:jest.Mock};
let motions:Motion[];
let previousAppPhase:typeof AppState.currentState;
beforeEach(()=>{
  previousAppPhase=AppState.currentState;
  jest.useFakeTimers();motions=[];mockReduced=false;mockCrossFade=false;jest.mocked(useToolbar).mockClear();jest.mocked(SafeArea.useSafeAreaInsets).mockReturnValue({top:0,bottom:21,left:59,right:59});
  jest.mocked(useReview).mockReturnValue({look:'lava'} as ReturnType<typeof useReview>);
  jest.spyOn(Animated,'timing').mockImplementation((_value,config)=>{
    const motion:Motion={value:_value,config,stop:jest.fn()};motions.push(motion);
    return {start:callback=>{motion.finish=callback;},stop:motion.stop,reset:jest.fn()};
  });
});
afterEach(()=>{AppState.currentState=previousAppPhase;jest.useRealTimers();jest.restoreAllMocks();});

const flow=(page:number,width=874,height=402)=>{
  const anchor:Anchor={current:null};
  return <OnboardingGeometryContext.Provider value={{panel:anchor,mascot:anchor,action:anchor,source:anchor,root:anchor,origin:{x:0,y:0},size:{width,height},sourceFrame:{x:59,y:48,width:128,height:128},setup:setup(page)}}><OnboardingFlow/></OnboardingGeometryContext.Provider>;
};
test('the decorative onboarding mascot does not announce internal English animation states',()=>{
  render(flow(2));
  const mascot=screen.getByTestId('onboarding.mascot',{includeHiddenElements:true});
  expect(mascot.props.accessible).toBe(false);
  expect(mascot.props.accessibilityLabel).toBeUndefined();
  expect(mascot.props.accessibilityValue).toBeUndefined();
  expect(screen.getByRole('button',{name:'Install local VPN'})).toBeTruthy();
});
test.each([[false,false,320],[true,false,200],[false,true,200]])('Features to Welcome shares its native return clock and prepares paused waves (reduced=%s, crossFade=%s)',(reduced,crossFade,duration)=>{
  mockReduced=reduced as boolean;mockCrossFade=crossFade as boolean;
  render(flow(1));motions=[];screen.rerender(flow(0));
  const progress=screen.UNSAFE_getByType(OnboardingPages).props.welcomeReturn;
  const clock=motions.find(m=>m.value===progress)!;
  expect(clock.config).toMatchObject({duration,toValue:1,useNativeDriver:true});expect(clock.config.delay).toBeUndefined();
  expect(motions.filter(m=>m.value===progress)).toHaveLength(1);
  expect(motions.every(m=>m.config.useNativeDriver)).toBe(true);
  const incoming=screen.UNSAFE_getAllByType(Animated.View).find(node=>{const style=StyleSheet.flatten(node.props.style);return style?.flex===1&&style?.opacity===progress;});
  expect(incoming).toBeDefined();expect(StyleSheet.flatten(incoming!.props.style).marginLeft).toBe(0);
  expect(screen.getByTestId('onboarding.page.outgoing',{includeHiddenElements:true})).toHaveStyle({marginLeft:128});
  const floor=()=>screen.UNSAFE_getAllByType(View).find(node=>node.props.floor)!;
  expect(floor().props.active).toBe(false);
  act(()=>clock.finish?.({finished:true}));
  expect(floor().props.active).toBe(true);expect(screen.queryByTestId('onboarding.page.outgoing',{includeHiddenElements:true})).toBeNull();
  expect(within(screen.getByTestId('onboarding.footer')).getByTestId('onboarding.steps')).toBeTruthy();
  expect(within(screen.getByTestId('onboarding.source.column')).queryByTestId('onboarding.steps',{includeHiddenElements:true})).toBeNull();
});
test('a cancelled Welcome return cannot start waves or retire the next page transition',()=>{
  render(flow(1));screen.rerender(flow(0));const oldProgress=screen.UNSAFE_getByType(OnboardingPages).props.welcomeReturn;
  const old=motions.find(m=>m.value===oldProgress)!;
  screen.rerender(flow(1));expect(old.stop).toHaveBeenCalled();
  act(()=>old.finish?.({finished:true}));expect(screen.UNSAFE_getByType(OnboardingPages).props.welcomeReturn).toBeUndefined();
  expect(screen.getByTestId('onboarding.page.outgoing',{includeHiddenElements:true})).toBeTruthy();
  screen.rerender(flow(0));const floor=screen.UNSAFE_getAllByType(View).find(node=>node.props.floor)!;
  act(()=>old.finish?.({finished:true}));expect(floor.props.active).toBe(false);
  expect(screen.getByTestId('onboarding.page.outgoing',{includeHiddenElements:true})).toBeTruthy();
});
test('Welcome Back waits for a usable committed canvas before starting the shared clock',()=>{
  render(flow(1,0,0));motions=[];screen.rerender(flow(0,0,0));
  const progress=screen.UNSAFE_getByType(OnboardingPages).props.welcomeReturn;
  expect(motions.some(m=>m.value===progress)).toBe(false);
  screen.rerender(flow(0));
  expect(motions.filter(m=>m.value===progress)).toHaveLength(1);
  expect(motions.find(m=>m.value===progress)!.config).toMatchObject({duration:320,useNativeDriver:true});
});
test('portrait Features to Welcome retains the original body layout while fading its incoming copy',()=>{
  render(flow(1,402,874));screen.rerender(flow(0,402,874));
  expect(screen.UNSAFE_getByType(OnboardingPages).props.sourceInset).toBe(0);
  expect(screen.getByRole('header',{name:onboardingPageTitle(0)})).toBeTruthy();
  expect(jest.mocked(useToolbar).mock.calls.at(-1)?.[0].title).toBe('');
});

test.each([[false,false,320],[true,false,200],[false,true,200]])('Back to features uses ordinary interruptible motion (reduced=%s, crossFade=%s)',(reduced,crossFade,duration)=>{
  const content=(page:number)=><OnboardingPages setup={setup(page)} command={jest.fn(async()=>true)} height={300} reduced={reduced as boolean} crossFade={crossFade as boolean}/>;
  render(content(2));motions=[];screen.rerender(content(1));
  expect(motions).toHaveLength(2);
  expect(motions.every(m=>m.config.duration===duration)).toBe(true);
  expect(motions.some(m=>m.config.delay===150)).toBe(false);
  expect(screen.getByRole('header',{name:onboardingPageTitle(1)})).toBeTruthy();
});
test('the first Welcome departure retains its authored entrance and a cancelled exit cannot retire the next outgoing page',()=>{
  const content=(page:number)=><OnboardingPages setup={setup(page)} command={jest.fn(async()=>true)} height={300} reduced={false} crossFade={false}/>;
  render(content(0));screen.rerender(content(1));
  expect(motions.some(m=>m.config.duration===1250&&m.config.delay===150)).toBe(true);
  const oldExit=motions.find(m=>m.config.duration===1100)!;
  screen.rerender(content(2));const outgoing=screen.getByTestId('onboarding.page.outgoing',{includeHiddenElements:true});
  expect(outgoing.props).toMatchObject({pointerEvents:'none',accessibilityElementsHidden:true,importantForAccessibility:'no-hide-descendants'});expect(oldExit.stop).toHaveBeenCalled();
  act(()=>oldExit.finish?.({finished:true}));
  expect(screen.getByTestId('onboarding.page.outgoing',{includeHiddenElements:true})).toBe(outgoing);
  expect(within(outgoing).getByText(onboardingPageTitle(1),{includeHiddenElements:true}).props.accessibilityRole).toBe('header');
  act(()=>motions.at(-1)?.finish?.({finished:true}));
  expect(screen.queryByTestId('onboarding.page.outgoing',{includeHiddenElements:true})).toBeNull();
});
test('returning to Welcome brings its curtain back with ordinary timing and ignores a retired departure callback',()=>{
  render(<OnboardingCurtain welcome width={874} height={402} reduced={false}/>);
  screen.rerender(<OnboardingCurtain welcome={false} width={874} height={402} reduced={false}/>);const oldExit=motions.at(-1)!;
  screen.rerender(<OnboardingCurtain welcome width={874} height={402} reduced={false}/>);
  expect(motions.at(-1)?.config).toMatchObject({duration:320,toValue:0});
  act(()=>oldExit.finish?.({finished:true}));expect(screen.getByTestId('onboarding.floor',{includeHiddenElements:true})).toBeTruthy();
  expect(onboardingPageMotion(1,0,false,false).entryDuration).toBe(320);
});
test.each([0,1,2,4])('landscape page %s delegates its single title to the native bar and restores portrait body title on rotation',page=>{
  const anchor:Anchor={current:null};const value=(width:number,height:number)=>({panel:anchor,mascot:anchor,action:anchor,source:anchor,root:anchor,origin:{x:0,y:0},size:{width,height},setup:setup(page)});
  const content=(width:number,height:number)=><OnboardingGeometryContext.Provider value={value(width,height)}><OnboardingFlow/></OnboardingGeometryContext.Provider>;
  render(content(874,402));
  expect(jest.mocked(useToolbar).mock.calls.at(-1)?.[0]).toMatchObject({title:onboardingPageTitle(page),headerBackVisible:false});
  expect(screen.queryByRole('header',{name:onboardingPageTitle(page)})).toBeNull();
  if(page>0)expect(within(screen.getByTestId('onboarding.source.column')).getByTestId('onboarding.steps')).toBeTruthy();
  screen.rerender(content(402,874));
  expect(jest.mocked(useToolbar).mock.calls.at(-1)?.[0].title).toBe('');
  expect(screen.getByRole('header',{name:onboardingPageTitle(page)})).toBeTruthy();
  expect(within(screen.getByTestId('onboarding.footer')).getByTestId('onboarding.steps')).toBeTruthy();
});
test.each([[1024,768],[1080,810],[1366,1024],[874,500]])('expanded landscape %s×%s retains a single footer progress group through Welcome return',(width,height)=>{
  render(flow(1,width,height));
  expect(within(screen.getByTestId('onboarding.source.column')).queryByTestId('onboarding.steps',{includeHiddenElements:true})).toBeNull();
  expect(within(screen.getByTestId('onboarding.footer')).getByTestId('onboarding.steps')).toBeTruthy();
  screen.rerender(flow(0,width,height));
  expect(screen.getAllByTestId('onboarding.steps',{includeHiddenElements:true})).toHaveLength(1);
  expect(within(screen.getByTestId('onboarding.source.column')).queryByTestId('onboarding.steps',{includeHiddenElements:true})).toBeNull();
});
test('rapid absolute choices retain every intent while identical pending navigation is deduplicated',async()=>{
  const pending:Array<{action:AppCommand;resolve:()=>void}>=[];
  const command=jest.fn((action:AppCommand)=>new Promise<void>(resolve=>pending.push({action,resolve})));
  jest.mocked(useReview).mockReturnValue({look:'lava',app:{command},live:{onboardingSetup:setup(3),security:{readRevision:1}}} as unknown as ReturnType<typeof useReview>);
  render(flow(3));
  fireEvent.press(screen.getByTestId('onboarding.filter.balanced'));
  fireEvent.press(screen.getByTestId('onboarding.filter.comprehensive'));
  fireEvent.press(screen.getByTestId('onboarding.filter.balanced'));
  expect(command.mock.calls.map(([action])=>action).filter(action=>action.type==='onboarding.choice')).toEqual([
    {type:'onboarding.choice',id:'visit',level:'balanced'},
    {type:'onboarding.choice',id:'visit',level:'comprehensive'},
    {type:'onboarding.choice',id:'visit',level:'balanced'},
  ]);
  fireEvent.press(screen.getByRole('button',{name:'Step 1 of 6'}));
  fireEvent.press(screen.getByRole('button',{name:'Step 2 of 6'}));
  fireEvent.press(screen.getByRole('button',{name:'Step 2 of 6'}));
  fireEvent.press(screen.getByRole('button',{name:'Step 1 of 6'}));
  fireEvent.press(screen.getByRole('button',{name:'Step 1 of 6'}));
  expect(command.mock.calls.map(([action])=>action).filter(action=>action.type==='onboarding.navigate')).toEqual([
    {type:'onboarding.navigate',id:'visit',page:0,revisit:true},
    {type:'onboarding.navigate',id:'visit',page:1,revisit:true},
    {type:'onboarding.navigate',id:'visit',page:0,revisit:true},
  ]);
  // Completing the first A cannot retire the third intent's duplicate guard.
  await act(async()=>{pending.find(({action})=>action.type==='onboarding.navigate')!.resolve();});
  fireEvent.press(screen.getByRole('button',{name:'Step 1 of 6'}));
  expect(command.mock.calls.map(([action])=>action).filter(action=>action.type==='onboarding.navigate')).toHaveLength(3);
  await act(async()=>{pending.forEach(({resolve})=>resolve());});
  fireEvent.press(screen.getByRole('button',{name:'Step 1 of 6'}));
  expect(command.mock.calls.map(([action])=>action).filter(action=>action.type==='onboarding.navigate')).toHaveLength(4);
  await act(async()=>{pending.forEach(({resolve})=>resolve());});
});
test.each([0,1,2])('the active step %s keeps its emphasis and does not request navigation',async page=>{
  const command=jest.fn(async(_action:AppCommand)=>{});
  jest.mocked(useReview).mockReturnValue({look:'lava',app:{command},live:{onboardingSetup:setup(page),security:{readRevision:1}}} as unknown as ReturnType<typeof useReview>);
  render(flow(page));
  const selected=screen.getByRole('button',{name:`Step ${page+1} of 6`});
  expect(selected).toBeDisabled();expect(selected.props.accessibilityState).toMatchObject({selected:true});
  expect(selected).toHaveStyle({opacity:1});
  fireEvent.press(selected);
  expect(command.mock.calls.some(([action])=>action.type==='onboarding.navigate')).toBe(false);
  fireEvent.press(screen.getByRole('button',{name:`Step ${page===0?2:1} of 6`}));
  expect(command).toHaveBeenCalledWith({type:'onboarding.navigate',id:'visit',page:page===0?1:0,revisit:true});
  await act(async()=>{});
});
test('a retry accepted as destination geometry arrives rebuilds travel and reaches Ready',async()=>{
  AppState.currentState='active';
  const state:OnboardingSetup={...setup(5),phase:'arriving',vpnInstalled:true};
  const command=jest.fn(async(_action:AppCommand)=>{});
  jest.mocked(useReview).mockReturnValue({look:'lava',app:{command},live:{onboardingSetup:state,security:{readRevision:1}}} as unknown as ReturnType<typeof useReview>);
  const anchor:Anchor={current:null};
  const frames={panel:{x:24,y:100,width:354,height:400},mascot:{x:136,y:124,width:128,height:128},action:{x:48,y:400,width:306,height:56}};
  const geometry={panel:anchor,mascot:anchor,action:anchor,source:anchor,root:anchor,origin:{x:0,y:0},size:{width:402,height:874},sourceFrame:{x:136,y:48,width:128,height:128},setup:state};
  const content=(measured:boolean)=><OnboardingGeometryContext.Provider value={{...geometry,frames:measured?frames:undefined}}><OnboardingFlow/></OnboardingGeometryContext.Provider>;
  render(content(false));
  await act(async()=>{jest.advanceTimersByTime(8100);});
  expect(screen.getByRole('button',{name:'Try again'})).toBeTruthy();
  // A tap accepted by the retry control can finish after the measurement
  // update. Keep that callback while the geometry itself becomes stable.
  const retry=screen.UNSAFE_getAllByType(LavaActionButton).find(node=>node.props.title==='Try again')!.props.onPress;
  screen.rerender(content(true));
  act(()=>retry());
  await act(async()=>{jest.advanceTimersByTime(1800);});
  expect(command.mock.calls.filter(([action])=>action.type==='onboarding.ready')).toEqual([[{type:'onboarding.ready',id:'visit'}]]);
  expect(screen.getByTestId('onboarding.ready')).toBeTruthy();
  expect(screen.queryByRole('button',{name:'Try again'})).toBeNull();
});
test('the protection level page uses its mapped title only when the scaffold owns the body heading',()=>{
  expect(onboardingPageTitle(3)).toBe('Pick how much Lava blocks');
  render(<OnboardingStep title={onboardingPageTitle(3)} showTitle={false}/>);
  expect(screen.queryByRole('header')).toBeNull();
  screen.rerender(<OnboardingStep title={onboardingPageTitle(3)} showTitle/>);
  expect(screen.getByRole('header',{name:'Pick how much Lava blocks'})).toBeTruthy();
});
test.each([0,2])('retiring landscape page %s clears its native title and controls before navigation dismisses it',page=>{
  const anchor:Anchor={current:null};
  const content=(state:OnboardingSetup|undefined)=><OnboardingGeometryContext.Provider value={{panel:anchor,mascot:anchor,action:anchor,source:anchor,root:anchor,origin:{x:0,y:0},size:{width:874,height:402},setup:state}}><OnboardingFlow/></OnboardingGeometryContext.Provider>;
  render(content(setup(page)));
  expect(jest.mocked(useToolbar).mock.calls.at(-1)?.[0].title).toBe(onboardingPageTitle(page));
  screen.rerender(content(undefined));
  const toolbar=jest.mocked(useToolbar).mock.calls.at(-1)![0];
  expect(toolbar.title).toBe('');expect(toolbar.headerTitleStyle).toBeUndefined();
  expect(toolbar.unstable_headerLeftItems?.({canGoBack:true})).toEqual([]);expect(toolbar.unstable_headerRightItems?.({canGoBack:true})).toEqual([]);
  expect(screen.toJSON()).toBeNull();
});
test('the onboarding CTA respects asymmetric landscape safe edges and retains its identity on portrait return',()=>{
  const insets=jest.mocked(SafeArea.useSafeAreaInsets);insets.mockReturnValue({top:0,bottom:21,left:59,right:44});
  const anchor:Anchor={current:null};
  const content=(width:number,height:number)=><OnboardingGeometryContext.Provider value={{panel:anchor,mascot:anchor,action:anchor,source:anchor,root:anchor,origin:{x:0,y:0},size:{width,height},setup:setup(2)}}><OnboardingFlow/></OnboardingGeometryContext.Provider>;
  render(content(874,402));const action=screen.getByTestId('onboarding.primary');
  expect(screen.getByTestId('onboarding.footer')).toHaveStyle({paddingLeft:79,paddingRight:64,paddingBottom:39});
  expect(within(screen.getByTestId('onboarding.source.column')).getByTestId('onboarding.steps')).toBeTruthy();
  insets.mockReturnValue({top:62,bottom:34,left:0,right:0});screen.rerender(content(402,874));
  expect(screen.getByTestId('onboarding.footer')).toHaveStyle({paddingHorizontal:20,paddingBottom:52});
  expect(screen.getByTestId('onboarding.primary')).toBe(action);
  expect(within(screen.getByTestId('onboarding.footer')).getByTestId('onboarding.steps')).toBeTruthy();
});
