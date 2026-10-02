import {render} from '@testing-library/react-native';
import {Animated,AppState} from 'react-native';
import {GuardMaterial} from '../review/guard-material';

let mockReduceMotion=true;
jest.mock('../review/navigation-scaffold',()=>({useReducedMotionPreference:()=>mockReduceMotion}));

beforeEach(()=>{mockReduceMotion=true;});

test('reduce motion engage cross-fades in place at the capped cadence',()=>{
  const timing=jest.spyOn(Animated,'timing');
  const originalState=AppState.currentState;AppState.currentState='active';
  try {
    const view=render(<GuardMaterial intent="rest"/>);
    timing.mockClear();
    view.rerender(<GuardMaterial intent="affirmed"/>);
    expect(timing.mock.calls.map(([,config])=>config.toValue)).toEqual([1,0]);
    for(const call of timing.mock.calls)expect(call[1].duration).toBe(150);
  } finally {timing.mockRestore();AppState.currentState=originalState;}
});

test('reduce motion restore cross-fades without growing the front',()=>{
  const timing=jest.spyOn(Animated,'timing');
  const originalState=AppState.currentState;AppState.currentState='active';
  try {
    const view=render(<GuardMaterial intent="recovery"/>);
    timing.mockClear();
    view.rerender(<GuardMaterial intent="affirmed"/>);
    expect(timing.mock.calls.map(([,config])=>config.toValue)).toEqual([1,0]);
    for(const call of timing.mock.calls)expect(call[1].duration).toBe(150);
  } finally {timing.mockRestore();AppState.currentState=originalState;}
});

test('turning Reduce Motion on snaps an in-flight restore to its surface',()=>{
  const timing=jest.spyOn(Animated,'timing');
  const originalState=AppState.currentState;AppState.currentState='active';
  mockReduceMotion=false;
  try {
    const view=render(<GuardMaterial intent="recovery"/>);
    view.rerender(<GuardMaterial intent="affirmed"/>);
    const radius=timing.mock.calls.at(-1)![0] as Animated.Value;
    const set=jest.spyOn(radius,'setValue');
    mockReduceMotion=true;
    view.rerender(<GuardMaterial intent="affirmed"/>);
    expect(set).toHaveBeenCalledWith(1);
  } finally {timing.mockRestore();AppState.currentState=originalState;}
});
