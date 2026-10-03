import {act,render} from '@testing-library/react-native';
import {Animated,AppState} from 'react-native';
import {GuardMaterial,guardSurface,guardDuration} from '../review/guard-material';

jest.mock('../review/navigation-scaffold',()=>({useReducedMotionPreference:()=>false}));

test('readiness holds its material through confirmation; stop waits for off',()=>{
  expect(guardSurface('affirmed','affirmed')).toBe('affirmed');
  expect(guardDuration('affirmed','affirmed','affirmed')).toBe(0);
  expect(guardSurface('stopping','affirmed')).toBe('affirmed');
  expect(guardSurface('rest','affirmed')).toBe('rest');
});

test('same-target stop preserves in-flight engage; neutral fades without moving the front',()=>{
  const timing=jest.spyOn(Animated,'timing');const parallel=jest.spyOn(Animated,'parallel');
  const originalState=AppState.currentState;AppState.currentState='active';
  try {
    const view=render(<GuardMaterial intent="rest"/>);
    view.rerender(<GuardMaterial intent="affirmed"/>);
    // Engage cross-fades in place: only the fill opacity and the grey layer animate.
    expect(timing.mock.calls.map(([,config])=>config.toValue)).toEqual([1,0]);
    const running=parallel.mock.results.at(-1)!.value as Animated.CompositeAnimation;
    const stop=jest.spyOn(running,'stop');timing.mockClear();
    view.rerender(<GuardMaterial intent="stopping"/>);
    expect(stop).not.toHaveBeenCalled();expect(timing).not.toHaveBeenCalled();
    view.rerender(<GuardMaterial intent="unknown"/>);
    expect(stop).toHaveBeenCalled();
    // The neutral fade never moves the front either: two calls, opacity and grey only.
    expect(timing).toHaveBeenCalledTimes(2);
    expect(timing.mock.calls.map(([,config])=>config.toValue)).toEqual([0,1]);
    timing.mockClear();
    view.rerender(<GuardMaterial intent="recovery"/>);
    expect(timing).not.toHaveBeenCalled();
  } finally {timing.mockRestore();parallel.mockRestore();AppState.currentState=originalState;}
});

test('direct release cross-fades in place at the stop cadence',()=>{
  const timing=jest.spyOn(Animated,'timing');
  const originalState=AppState.currentState;AppState.currentState='active';
  try {
    const view=render(<GuardMaterial intent="affirmed"/>);
    timing.mockClear();
    view.rerender(<GuardMaterial intent="rest"/>);
    expect(timing.mock.calls.map(([,config])=>config.toValue)).toEqual([0,0]);
    for(const call of timing.mock.calls)expect(call[1].duration).toBe(550);
  } finally {timing.mockRestore();AppState.currentState=originalState;}
});

test('an old neutral completion cannot reset a newer restoration',()=>{
  const completions:(((result:{finished:boolean})=>void)|undefined)[]=[];
  const parallel=jest.spyOn(Animated,'parallel').mockImplementation(()=>({
    start:callback=>{completions.push(callback);},stop:()=>{},reset:()=>{},
    _startNativeLoop:()=>{},_isUsingNativeDriver:()=>true,
  }));
  const timing=jest.spyOn(Animated,'timing');
  const originalState=AppState.currentState;AppState.currentState='active';
  try {
    const view=render(<GuardMaterial intent="recovery"/>);
    view.rerender(<GuardMaterial intent="affirmed"/>);
    // Only a restore from neutral grows the front, so its last timing is the radius.
    const radius=timing.mock.calls.at(-1)![0] as Animated.Value;
    const set=jest.spyOn(radius,'setValue');
    view.rerender(<GuardMaterial intent="recovery"/>);
    const oldCompletion=completions.at(-1);
    view.rerender(<GuardMaterial intent="affirmed"/>);
    act(()=>{oldCompletion?.({finished:true});});
    expect(set).not.toHaveBeenCalled();
    view.rerender(<GuardMaterial intent="paused"/>);
    act(()=>{completions.at(-1)?.({finished:true});});
    expect(set).toHaveBeenCalledWith(0);
  } finally {timing.mockRestore();parallel.mockRestore();AppState.currentState=originalState;}
});
test('unresolved starts stay outlined but unresolved recovery loses green',()=>{
  expect(guardSurface('unresolved')).toBe('rest');
  expect(guardSurface('unresolved','rest')).toBe('rest');
  expect(guardSurface('unresolved','affirmed')).toBe('neutral');
  for(const intent of ['recovery','paused','unknown'] as const)expect(guardSurface(intent,'affirmed')).toBe('neutral');
});
test('cosmetic durations distinguish recovery, stop and uncertainty',()=>{
  expect(guardDuration('affirmed','rest','affirmed')).toBe(500);
  expect(guardDuration('affirmed','neutral','affirmed')).toBe(500);
  expect(guardDuration('rest','affirmed','rest')).toBe(550);
  expect(guardDuration('recovery','affirmed','neutral')).toBe(240);
  expect(guardDuration('unknown','affirmed','neutral')).toBe(300);
  expect(guardDuration('paused','affirmed','neutral')).toBe(400);
});

test('rerenders and returning to a hidden hero do not replay engage',()=>{
  const timing=jest.spyOn(Animated,'timing');
  const originalState=AppState.currentState;
  AppState.currentState='active';
  try {
    const view=render(<GuardMaterial intent="rest"/>);
    timing.mockClear();
    view.rerender(<GuardMaterial intent="affirmed"/>);
    expect(timing).toHaveBeenCalledWith(expect.anything(),expect.objectContaining({duration:500,toValue:1}));
    timing.mockClear();
    view.rerender(<GuardMaterial intent="affirmed"/>);
    expect(timing).not.toHaveBeenCalled();
    view.rerender(<GuardMaterial intent="affirmed" active={false}/>);
    timing.mockClear();
    view.rerender(<GuardMaterial intent="affirmed" active/>);
    for(const call of timing.mock.calls)expect(call[1].duration).toBe(0);
  } finally {timing.mockRestore();AppState.currentState=originalState;}
});
