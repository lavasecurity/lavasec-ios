import {localizedFormat} from '../app/presentation';
// Shared chart proportions and inspection rules. Fixture counts are isolated
// from the production diagnostics store and tunnel.
export type ActivityBucket={start:number;label:string;allowed:number;blocked:number;available:boolean;partial:boolean};
export type ActivitySummary={allowed:number;blocked:number;uptime:string;buckets?:ActivityBucket[]};
// Explicit isolated review-host sample, never substituted for a live AppStore
// query. Mixed traffic, measured zero, a missing interval, and 0%/100% rates
// exercise the same chart/inspection path as native telemetry.
export const activityExample:ActivitySummary = {allowed:2648,blocked:598,get uptime(){return localizedFormat('%dh %dm',9,30);},buckets:[
  {start:0,label:'09:00',allowed:800,blocked:200,available:true,partial:false},
  {start:3600,label:'10:00',allowed:0,blocked:0,available:true,partial:false},
  {start:7200,label:'11:00',allowed:0,blocked:0,available:false,partial:false},
  {start:10800,label:'12:00',allowed:848,blocked:198,available:true,partial:false},
  {start:14400,label:'13:00',allowed:1000,blocked:0,available:true,partial:false},
  {start:18000,label:'14:00',allowed:0,blocked:200,available:true,partial:true},
]};
export const activityEmpty:ActivitySummary = {allowed: 0, blocked: 0, get uptime(){return localizedFormat('%dm',0);}};
export function activityRate(bucket:ActivityBucket):number|undefined {
  const total=bucket.allowed+bucket.blocked;
  return bucket.available&&total>0?Math.round(bucket.blocked/total*100):undefined;
}

// Inspection changes the displayed bucket, not the denominator for a highlighted outcome.
export function activityLegendValue(count:number,total:number,available:boolean,locale:string):string {
  if(!available)return '—';
  const language=locale.replace(/_/g,'-');
  const number=new Intl.NumberFormat(language).format(count);
  const share=new Intl.NumberFormat(language,{style:'percent',maximumFractionDigits:0}).format(total>0?count/total:0);
  return `${number} (${share})`;
}

export function activityShare(count: number, total: number): string {
  if (count <= 0 || total <= 0) return '0%';
  if (count >= total) return '100%';
  const rate = count / total;
  if (rate < 0.01) return '<1%';
  if (rate > 0.99) return '>99%';
  return `${Math.round(rate * 100)}%`;
}

export function activityBranches(width: number, allowed: number, blocked: number) {
  const total = allowed + blocked;
  const gap = allowed > 0 && blocked > 0 ? 3 : 0;
  const available = Math.max(width - gap, 0);
  const blockedWidth = blocked > 0 ? available * blocked / total : 0;
  return {gap, blocked: blockedWidth, allowed: total > 0 ? Math.max(available - blockedWidth, 0) : 0};
}

export type ActivityOutcome='allowed'|'blocked';
// Horizontal summaries place Blocked on the left, then the real gap and Allowed.
// Hit-test those rendered portions; zero outcomes have no target.
export function activityOutcomeAt(x:number,width:number,allowed:number,blocked:number):ActivityOutcome|undefined {
  if(x<0||x>width||width<=0)return undefined;
  const parts=activityBranches(width,allowed,blocked);
  if(blocked>0&&x<=parts.blocked)return 'blocked';
  if(allowed>0&&x>=parts.blocked+parts.gap)return 'allowed';
  return undefined;
}
export const activityInspectionFeedback=(bucket:ActivityBucket)=>bucket.available&&bucket.allowed+bucket.blocked>0?'populated':'empty';
