import {activityBranches, activityShare, activityOutcomeAt, activityInspectionFeedback, activityExample, activityRate, activityLegendValue} from '../review/activity-model';

test('Activity legends keep counts and rounded shares, including zero and unavailable data',()=>{
  expect(activityLegendValue(2648,3246,true,'en_US')).toBe('2,648 (82%)');
  expect(activityLegendValue(598,3246,true,'en_US')).toBe('598 (18%)');
  expect(activityLegendValue(0,0,true,'en')).toBe('0 (0%)');
  expect(activityLegendValue(7,7,true,'en')).toBe('7 (100%)');
  expect(activityLegendValue(0,7,true,'en')).toBe('0 (0%)');
  expect(activityLegendValue(0,0,false,'en')).toBe('—');
});

test('Activity legend count grouping and percentage spacing use the selected locale',()=>{
  expect(activityLegendValue(2648,3246,true,'de_DE')).toBe('2.648 (82\u00a0%)');
  const locale='ar-EG';
  expect(activityLegendValue(2648,3246,true,locale)).toBe(`${new Intl.NumberFormat(locale).format(2648)} (${new Intl.NumberFormat(locale,{style:'percent',maximumFractionDigits:0}).format(2648/3246)})`);
});

test('isolated Activity sample totals agree with the rendered mixed, zero and unavailable buckets',()=>{
  const buckets=activityExample.buckets!;
  expect(buckets.reduce((sum,bucket)=>sum+bucket.allowed,0)).toBe(activityExample.allowed);
  expect(buckets.reduce((sum,bucket)=>sum+bucket.blocked,0)).toBe(activityExample.blocked);
  expect(buckets.map(activityRate)).toEqual([20,undefined,undefined,19,0,100]);
  expect(buckets.map(activityInspectionFeedback)).toEqual(['populated','empty','empty','populated','populated','populated']);
  expect(buckets[1]!.available).toBe(true);
  expect(buckets[2]!.available).toBe(false);
  expect(buckets.at(-1)!.partial).toBe(true);
});

test('activity shares retain tiny and near-total traffic instead of reporting zero or all', () => {
  expect(activityShare(0, 0)).toBe('0%');
  expect(activityShare(2648, 3246)).toBe('82%');
  expect(activityShare(598, 3246)).toBe('18%');
  expect(activityShare(1, 1000)).toBe('<1%');
  expect(activityShare(999, 1000)).toBe('>99%');
  expect(activityShare(1000, 1000)).toBe('100%');
});

test('flow branches preserve the shared gap, truthful tiny proportions and empty/single-branch states', () => {
  expect(activityBranches(303, 80, 20)).toEqual({gap: 3, allowed: 240, blocked: 60});
  expect(activityBranches(303, 999, 1)).toEqual({gap: 3, allowed: 299.7, blocked: 0.3});
  expect(activityBranches(300, 0, 0)).toEqual({gap: 0, allowed: 0, blocked: 0});
  expect(activityBranches(300, 12, 0)).toEqual({gap: 0, allowed: 300, blocked: 0});
  expect(activityBranches(300, 0, 12)).toEqual({gap: 0, allowed: 0, blocked: 300});
  expect(activityBranches(0, 1, 1)).toEqual({gap: 3, allowed: 0, blocked: 0});
});


test('Total inspection hit-tests only the rendered nonzero portions, never their gap',()=>{
  expect(activityOutcomeAt(59,303,80,20)).toBe('blocked');
  expect(activityOutcomeAt(61.5,303,80,20)).toBeUndefined();
  expect(activityOutcomeAt(64,303,80,20)).toBe('allowed');
  expect(activityOutcomeAt(301,300,80,20)).toBeUndefined();
  expect(activityOutcomeAt(0,300,0,20)).toBe('blocked');
  expect(activityOutcomeAt(300,300,20,0)).toBe('allowed');
  expect(activityOutcomeAt(150,300,0,0)).toBeUndefined();
  expect(activityOutcomeAt(0.1,303,999,1)).toBe('blocked');
});
test('empty feedback distinguishes actual requests from zero-rate and missing buckets',()=>{
  const bucket={start:1,label:'Today',allowed:0,blocked:0,partial:false,available:true};
  expect(activityInspectionFeedback(bucket)).toBe('empty');
  expect(activityInspectionFeedback({...bucket,available:false})).toBe('empty');
  expect(activityInspectionFeedback({...bucket,allowed:7})).toBe('populated');
  expect(activityInspectionFeedback({...bucket,blocked:3})).toBe('populated');
});
