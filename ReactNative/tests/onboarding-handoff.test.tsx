import {act,renderHook} from '@testing-library/react-native';
import type {AppStore} from '../app/store';
import type {OnboardingPresentation} from '../app/contract';
import {useOnboardingHandoff} from '../review/onboarding-handoff';

beforeEach(()=>jest.useFakeTimers());
afterEach(()=>jest.useRealTimers());
const presentation:OnboardingPresentation={session:'demo',mock:true,phase:'arriving',layoutRevision:1};
async function setup(command:jest.Mock) {
  const app={command} as unknown as AppStore;
  const hook=renderHook(({value}:{value:OnboardingPresentation})=>useOnboardingHandoff(app,value),{initialProps:{value:presentation}});
  for(const ref of Object.values(hook.result.current))ref.current={measureInWindow:(callback:(...values:number[])=>void)=>callback(0,0,100,100)} as never;
  await act(async()=>{});
  return hook;
}
const tick=()=>act(async()=>{jest.advanceTimersByTime(160);await Promise.resolve();});

test('retries unchanged geometry until native accepts it, then deduplicates',async()=>{
  const command=jest.fn().mockResolvedValueOnce(false).mockResolvedValue(true);
  const hook=await setup(command);
  await tick();expect(command).toHaveBeenCalledTimes(1);
  await tick();expect(command).toHaveBeenCalledTimes(2);
  await tick();expect(command).toHaveBeenCalledTimes(2);
  hook.unmount();
});

test('an arrival retry resends the same frames with a new layout revision',async()=>{
  const command=jest.fn().mockResolvedValue(true);
  const hook=await setup(command);
  await tick();expect(command).toHaveBeenCalledTimes(1);
  await act(async()=>hook.rerender({value:{...presentation,layoutRevision:2}}));
  expect(command).toHaveBeenCalledTimes(2);
  expect(command.mock.calls[1][0]).toMatchObject({session:'demo',phase:'arriving',layoutRevision:2});
  await tick();expect(command).toHaveBeenCalledTimes(2);
  hook.unmount();
});
