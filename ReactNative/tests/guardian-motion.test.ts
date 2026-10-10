import {guardianFrame,guardianPlan,type GuardianState,type GuardianFrame} from '../src/guardian-motion';
import {OnboardingTravel,OnboardingPhaseCommands,onboardingTravelProgress,validOnboardingDestination,lavaWavePhase} from '../review/onboarding-motion';

test('returning to arrival after Back permits a new acknowledgement and retires an old pending reply',async()=>{
  const phases=new OnboardingPhaseCommands();const accepted=jest.fn(async()=>true);
  phases.send('visit:arriving:ready',2,accepted);await Promise.resolve();
  phases.send('visit:arriving:ready',3,accepted);expect(accepted).toHaveBeenCalledTimes(1);
  phases.reset();phases.send('visit:arriving:ready',4,accepted);await Promise.resolve();
  expect(accepted).toHaveBeenCalledTimes(2);
  let settle!:(value:boolean)=>void;phases.reset();
  phases.send('visit:arriving:ready',5,()=>new Promise(resolve=>{settle=resolve;}));
  phases.reset();phases.send('visit:arriving:ready',6,accepted);await Promise.resolve();
  settle(false);await Promise.resolve();
  phases.send('visit:arriving:ready',7,accepted);expect(accepted).toHaveBeenCalledTimes(3);
});
const samples=require('./fixtures/guardian-frames.json') as Array<{from:GuardianState;to:GuardianState;kind:'transition'|'blink';elapsed:number;duration:number;frame:GuardianFrame}>;

test.each(samples)('matches Swift $from → $to $kind at $elapsed',sample=>{
  const plan=guardianPlan(sample.from as GuardianState,sample.to as GuardianState,sample.kind as 'transition'|'blink');
  expect(plan.duration).toBeCloseTo(sample.duration,12);
  const actual=guardianFrame(plan,sample.elapsed);
  for(const [key,value] of Object.entries(sample.frame))expect(actual[key as keyof GuardianFrame]).toBeCloseTo(value,12);
});
const frame=(x:number,y:number,width=128,height=128)=>({x,y,width,height});
test('phase acknowledgement fences repeated frames while rejection permits a bounded retry',async()=>{
  const phases=new OnboardingPhaseCommands();const accepted=jest.fn(async()=>true);
  for(let i=0;i<100;i++){phases.send('visit:ready',i/60,accepted);await Promise.resolve();}
  expect(accepted).toHaveBeenCalledTimes(1);
  const retry=jest.fn().mockResolvedValueOnce(false).mockResolvedValue(true);
  phases.send('visit:release',2,retry);await Promise.resolve();
  phases.send('visit:release',2.1,retry);expect(retry).toHaveBeenCalledTimes(1);
  phases.send('visit:release',2.31,retry);await Promise.resolve();
  phases.send('visit:release',3,retry);expect(retry).toHaveBeenCalledTimes(2);
  phases.send('new-visit:ready',3,accepted);expect(accepted).toHaveBeenCalledTimes(2);
});
test('travel retargets from its visible position and preserves its finish time',()=>{
  const travel=new OnboardingTravel(frame(0,0),frame(100,200),10);
  expect(travel.position(10)).toEqual({x:64,y:64});
  const visible=travel.position(10.7);
  travel.retarget(frame(300,400),10.7);
  expect(travel.position(10.7)).toEqual(visible);
  expect(travel.position(11.4)).toEqual({x:364,y:464});
  expect(travel.settled(11.4)).toBe(true);
  travel.retarget(frame(500,600),12);
  expect(travel.position(12)).toEqual({x:564,y:664});
});
test('invalid, missing and out-of-panel destinations cannot complete arrival',()=>{
  const valid={panel:frame(0,0,400,500),mascot:frame(130,40),action:frame(20,350,360,60)};
  expect(validOnboardingDestination(valid)).toBe(true);
  expect(validOnboardingDestination({...valid,action:frame(20,480,360,60)})).toBe(false);
  expect(validOnboardingDestination({...valid,mascot:frame(NaN,40)})).toBe(false);
  expect(validOnboardingDestination({...valid,panel:frame(0,0,0,500)})).toBe(false);
});
test('travel clamps its endpoints and the welcome clock repeats in eighteen seconds',()=>{
  expect(onboardingTravelProgress(-1)).toBe(0);
  expect(onboardingTravelProgress(.7)).toBe(.875);
  expect(onboardingTravelProgress(20)).toBe(1);
  expect(lavaWavePhase(2)).toBeCloseTo(lavaWavePhase(20),12);
});
