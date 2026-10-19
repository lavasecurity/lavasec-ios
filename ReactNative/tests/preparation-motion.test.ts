import {PreparationProgressMotion,preparationEaseOut,preparationFillDuration} from '../src/flows/preparation/motion';
import type {PreparationSnapshot} from '../src/flows/preparation/contract';

const snapshot=(changes:Partial<PreparationSnapshot>={}):PreparationSnapshot=>({id:'attempt-1',origin:'filters',state:'preparing',progress:0,title:'Building the filter',message:'',busy:false,recovery:{retry:false,editReturn:false,keepCurrent:false,upgrade:null},...changes});

test('progress is eased over 550 ms and an interrupted fill starts at its displayed fraction',()=>{
  const motion=new PreparationProgressMotion();motion.update(snapshot(),0);
  motion.update(snapshot({progress:.25}),0);
  const first=motion.frame(275).progress;
  expect(first).toBeCloseTo(.25*preparationEaseOut(.5),6);
  expect(first).toBeGreaterThan(.125);
  motion.update(snapshot({progress:.5}),275);
  expect(motion.frame(275).progress).toBeCloseTo(first,6);
  expect(motion.frame(550).progress).toBeCloseTo(first+(.5-first)*preparationEaseOut(.5),6);
  expect(motion.frame(825).progress).toBe(.5);
  expect(motion.needsFrame(825)).toBe(false);
  expect(preparationFillDuration).toBe(550);
});

test('a late mount at confirmed Success paints saving-top then fills before the result glyph',()=>{
  const motion=new PreparationProgressMotion();motion.update(snapshot({state:'success',progress:1}),0);
  expect(motion.frame(0)).toEqual({progress:.75,glyph:false,complete:false});
  expect(motion.frame(549).glyph).toBe(false);
  expect(motion.frame(550)).toEqual({progress:1,glyph:true,complete:false});
  expect(motion.frame(1199).complete).toBe(false);
  expect(motion.frame(1200).complete).toBe(true);
  expect(motion.needsFrame(1200)).toBe(false);
});

test('batched Success cannot skip an unfinished saving quarter',()=>{
  const motion=new PreparationProgressMotion();motion.update(snapshot({progress:.5}),0);
  motion.update(snapshot({state:'success',progress:1}),100);
  motion.update(snapshot({state:'success',progress:1}),300);
  expect(motion.frame(649).glyph).toBe(false);
  expect(motion.frame(650)).toEqual({progress:.75,glyph:false,complete:false});
  expect(motion.frame(1199).glyph).toBe(false);
  expect(motion.frame(1200).glyph).toBe(true);
});

test('native success after the 500ms saving hold continues directly to full without restarting saving',()=>{
  const motion=new PreparationProgressMotion();motion.update(snapshot({progress:.5}),0);
  motion.update(snapshot({progress:.75}),0);
  const displayed=motion.frame(500).progress;
  expect(displayed).toBeLessThan(.75);
  motion.update(snapshot({state:'success',progress:1}),500);
  expect(motion.frame(500).progress).toBeCloseTo(displayed,6);
  expect(motion.frame(775).progress).toBeCloseTo(displayed+(1-displayed)*preparationEaseOut(.5),6);
  expect(motion.frame(1050)).toEqual({progress:1,glyph:true,complete:false});
  expect(motion.frame(1699).complete).toBe(false);
  expect(motion.frame(1700).complete).toBe(true);
});

test('local animation completion never creates native success',()=>{
  const motion=new PreparationProgressMotion();motion.update(snapshot(),0);
  motion.update(snapshot({progress:1}),10);
  expect(motion.frame(10000)).toEqual({progress:1,glyph:false,complete:false});
});

test('background time cannot consume a hidden final sweep or success hold',()=>{
  const motion=new PreparationProgressMotion();motion.update(snapshot({state:'success',progress:1}),0);motion.frame(0);
  const before=motion.frame(200).progress;
  motion.pause(200);expect(motion.frame(10000).progress).toBe(before);
  motion.resume(10000);expect(motion.frame(10000).progress).toBe(before);
  expect(motion.frame(10349).glyph).toBe(false);
  expect(motion.frame(10350).glyph).toBe(true);
  expect(motion.frame(11000).complete).toBe(true);
});

test('a new attempt retires the old success and its display completion',()=>{
  const motion=new PreparationProgressMotion();motion.update(snapshot({state:'success',progress:1}),0);motion.frame(0);
  motion.frame(550);expect(motion.frame(1200).complete).toBe(true);
  motion.update(snapshot({id:'attempt-2',progress:.1}),1500);
  expect(motion.frame(5000)).toEqual({progress:.1,glyph:false,complete:false});
});
