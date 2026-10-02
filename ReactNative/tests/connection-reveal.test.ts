import {connectionAperture,connectionAttention} from '../review/connection-reveal';
import type {ConnectionStage} from '../review/connection-model';

const stages=[{id:'phone'},{id:'filter'},{id:'vpn',muted:true},{id:'dns'}] as ConnectionStage[];
test('a demo frame focuses its last described part even when the live stage is muted',()=>{
  expect(connectionAttention(stages,['phone','filter','vpn'])).toBe('vpn');
  expect(connectionAttention(stages,['phone','filter','vpn','dns'])).toBe('dns');
  expect(connectionAttention(stages,['vpn'])).toBe('vpn');
  expect(connectionAttention(stages,undefined)).toBeUndefined();
});
test('aperture uses actual center spacing in either orientation',()=>{
  expect(connectionAperture({phone:{x:22,y:22},filter:{x:122,y:22}},'filter')).toEqual({x:122,y:22,radius:50});
  expect(connectionAperture({phone:{x:22,y:22},filter:{x:22,y:102}},'phone')).toEqual({x:22,y:22,radius:40});
  expect(connectionAperture({},'phone')).toBeUndefined();
});
