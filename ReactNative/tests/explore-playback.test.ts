import {DemoPlaybackClock} from '../review/explore-playback';

beforeEach(()=>jest.useFakeTimers());
afterEach(()=>jest.useRealTimers());
const flush=async()=>{await Promise.resolve();await Promise.resolve();};

test('explicit playback waits for both reading and fallback speech',async()=>{
  const clock=new DemoPlaybackClock(),advance=jest.fn();let finish!:()=>void;
  clock.start(2600,new Promise<void>(resolve=>{finish=resolve;}),advance);
  jest.advanceTimersByTime(2600);await flush();expect(advance).not.toHaveBeenCalled();
  finish();await flush();expect(advance).toHaveBeenCalledTimes(1);
});
test('unavailable speech still advances after the readable interval',async()=>{
  const clock=new DemoPlaybackClock(),advance=jest.fn();
  clock.start(2600,Promise.reject(new Error('Voice unavailable')),advance);
  await flush();jest.advanceTimersByTime(2599);await flush();expect(advance).not.toHaveBeenCalled();
  jest.advanceTimersByTime(1);await flush();expect(advance).toHaveBeenCalledTimes(1);
});
test('manual navigation invalidates a pending speech completion and timer',async()=>{
  const clock=new DemoPlaybackClock(),old=jest.fn(),next=jest.fn();let finish!:()=>void;
  clock.start(2600,new Promise<void>(resolve=>{finish=resolve;}),old);
  jest.advanceTimersByTime(2600);clock.cancel();
  clock.start(3000,Promise.resolve(false),next);finish();await flush();expect(old).not.toHaveBeenCalled();
  jest.advanceTimersByTime(2999);await flush();expect(next).not.toHaveBeenCalled();
  jest.advanceTimersByTime(1);await flush();expect(next).toHaveBeenCalledTimes(1);
});
test('inspection, navigation or background cancellation prevents an advance',async()=>{
  const clock=new DemoPlaybackClock(),advance=jest.fn();
  clock.start(2600,Promise.resolve(false),advance);clock.cancel();
  jest.runAllTimers();await flush();expect(advance).not.toHaveBeenCalled();
});
