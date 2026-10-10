import {act,renderHook,waitFor} from '@testing-library/react-native';
import {AccessibilityInfo,Platform} from 'react-native';
import {floatingTabMinimizeBehavior,ordinaryPageHeader,ordinaryPushPresentation,useOrdinaryPushPresentation,useReducedMotionPreference} from '../review/navigation-scaffold';

afterEach(()=>jest.restoreAllMocks());

test.each(['18.6','26.5','27.0'])('native page translucency is independent of title size on iOS %s',version=>{
  jest.spyOn(Platform,'Version','get').mockReturnValue(version);
  const options=ordinaryPageHeader();
  expect(options.headerTransparent).toBe(true);
  expect(options.headerStyle).toEqual({backgroundColor:'transparent'});
  expect(options.headerLargeTitleEnabled).toBeUndefined();
  expect(options.headerBlurEffect).toBe(version==='18.6'?'systemChromeMaterial':undefined);
  expect(options.headerBackground).toBeUndefined();
  expect(options.scrollEdgeEffects).toBeUndefined();
});

test('native page material and layout do not override Android navigation',()=>{
  jest.replaceProperty(Platform,'OS','android');
  expect(ordinaryPageHeader()).toEqual({});
});

test.each([
  ['18.6',undefined],
  ['26.0','none'],
  ['26.7','none'],
  ['27.0','onScrollDown'],
  ['27.0.1','onScrollDown'],
  ['28.1','onScrollDown'],
] as const)('floating tab minimization respects the nested-stack boundary on iOS %s',(version,expected)=>{
  jest.spyOn(Platform,'Version','get').mockReturnValue(version);
  expect(floatingTabMinimizeBehavior()).toBe(expected);
});

test('the iOS floating-tab behavior is not applied to Android',()=>{
  jest.replaceProperty(Platform,'OS','android');
  expect(floatingTabMinimizeBehavior()).toBeUndefined();
});

test('ordinary push and swipe use the native title transition while preserving explicit cross-fade',()=>{
  expect(ordinaryPushPresentation(false)).toEqual({animation:'default',animationMatchesGesture:false,fullScreenGestureEnabled:false});
  expect(ordinaryPushPresentation(true)).toEqual({animation:'fade',animationMatchesGesture:true,fullScreenGestureEnabled:false});
  for(const reduced of [false,true]){
    const options=ordinaryPushPresentation(reduced);
    expect(options.presentation).toBeUndefined();
    expect(options.gestureEnabled).toBeUndefined();
    expect(options.fullScreenGestureEnabled).toBe(false);
    expect(options.headerShown).toBeUndefined();
    expect(options.contentStyle).toBeUndefined();
  }
  jest.replaceProperty(Platform,'OS','android');
  expect(ordinaryPushPresentation(false).animation).toBe('slide_from_right');
});

test('navigation distinguishes Reduce Motion from an explicit cross-fade request',async()=>{
  let receive!:(enabled:boolean)=>void;const remove=jest.fn();
  jest.spyOn(AccessibilityInfo,'addEventListener').mockImplementation((_event,listener)=>{receive=listener;return{remove};});
  jest.spyOn(AccessibilityInfo,'isReduceMotionEnabled').mockResolvedValue(true);
  const read=jest.spyOn(AccessibilityInfo,'prefersCrossFadeTransitions').mockResolvedValue(false);
  const {result,unmount}=renderHook(()=>useOrdinaryPushPresentation());
  await waitFor(()=>expect(result.current.animation).toBe('default'));
  read.mockResolvedValue(true);act(()=>receive(true));
  await waitFor(()=>expect(result.current.animation).toBe('fade'));
  read.mockResolvedValue(false);act(()=>receive(true));
  await waitFor(()=>expect(result.current.animation).toBe('default'));
  unmount();expect(remove).toHaveBeenCalledTimes(1);
});

test('a late initial accessibility read cannot replace a newer preference',async()=>{
  let finish!:(enabled:boolean)=>void;let receive!:(enabled:boolean)=>void;
  jest.spyOn(AccessibilityInfo,'addEventListener').mockImplementation((_event,listener)=>{receive=listener;return{remove:jest.fn()};});
  jest.spyOn(AccessibilityInfo,'isReduceMotionEnabled').mockReturnValue(new Promise(resolve=>{finish=resolve;}));
  const {result}=renderHook(()=>useReducedMotionPreference());
  act(()=>receive(true));
  await act(async()=>finish(false));
  expect(result.current).toBe(true);
});

test('an unavailable accessibility preference keeps automatic motion disabled',async()=>{
  jest.spyOn(AccessibilityInfo,'isReduceMotionEnabled').mockRejectedValue(new Error('Unavailable'));
  const {result}=renderHook(()=>useReducedMotionPreference());
  await act(async()=>{});
  expect(result.current).toBe(true);
});
