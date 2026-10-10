/** Shared foreground counterpart of GuardianMascotAnimationPlan. Widgets keep
 * the Swift renderer; cross-language frame fixtures exercise both equations. */
export type GuardianState='sleeping'|'waking'|'awake'|'paused'|'retrying'|'concerned'|'grateful';
export type GuardianFrame={shieldWakeAmount:number;shieldScale:number;glowAmount:number;sleepyEyeAmount:number;leftEyeOpenAmount:number;rightEyeOpenAmount:number;winkAmount:number;happyEyeAmount:number;concernAmount:number;pauseAmount:number;gratitudeAmount:number;mouthCurve:number};
export const unit=(n:number)=>Math.min(1,Math.max(0,n));
const mix=(a:number,b:number,t:number)=>a+(b-a)*t;
export const smoothstep=(n:number)=>{const t=unit(n);return t*t*(3-2*t);};
export function stableGuardianFrame(state:GuardianState):GuardianFrame{
  const f:GuardianFrame={shieldWakeAmount:1,shieldScale:1,glowAmount:.74,sleepyEyeAmount:0,leftEyeOpenAmount:1,rightEyeOpenAmount:1,winkAmount:0,happyEyeAmount:0,concernAmount:0,pauseAmount:0,gratitudeAmount:0,mouthCurve:1};
  if(state==='sleeping')Object.assign(f,{shieldWakeAmount:0,glowAmount:0,sleepyEyeAmount:1,leftEyeOpenAmount:0,rightEyeOpenAmount:0});
  if(state==='paused')Object.assign(f,{sleepyEyeAmount:1,leftEyeOpenAmount:0,rightEyeOpenAmount:0,pauseAmount:1});
  if(state==='retrying')Object.assign(f,{leftEyeOpenAmount:.8,rightEyeOpenAmount:.8,mouthCurve:0});
  if(state==='concerned')Object.assign(f,{leftEyeOpenAmount:.78,rightEyeOpenAmount:.78,concernAmount:1,mouthCurve:-.22});
  if(state==='grateful')Object.assign(f,{glowAmount:.88,leftEyeOpenAmount:0,rightEyeOpenAmount:0,happyEyeAmount:1,gratitudeAmount:1,mouthCurve:1.18});
  return f;
}
export type GuardianPlan={from:GuardianState;to:GuardianState;duration:number;kind:'transition'|'blink'|'hold';sequence?:GuardianPlan[]};
export function guardianPlan(from:GuardianState,to:GuardianState,kind:GuardianPlan['kind']='transition'):GuardianPlan{
  if(kind==='blink')return {from,to,duration:.46,kind};
  if(kind==='hold')return {from,to,duration:.5,kind};
  const wake=from==='sleeping'&&(to==='awake'||to==='waking');
  const duration=wake||to==='sleeping'&&from!=='sleeping'?.82:from==='waking'&&to==='awake'?.22:.44;
  if(wake){const sequence:GuardianPlan[]=[{from,to,duration,kind},{from:'awake',to:'awake',duration:.5,kind:'hold'},{from:'awake',to:'awake',duration:.46,kind:'blink'}];return {from,to,duration:1.78,kind,sequence};}
  return {from,to,duration,kind};
}
export function guardianFrame(plan:GuardianPlan,elapsed:number):GuardianFrame{
  if(plan.sequence){let remaining=Math.max(0,elapsed);for(const part of plan.sequence){if(remaining<=part.duration)return guardianFrame(part,remaining);remaining-=part.duration;}const last=plan.sequence.at(-1)!;return guardianFrame(last,last.duration);}
  const a=stableGuardianFrame(plan.from),b=stableGuardianFrame(plan.to),raw=plan.duration<=0?1:elapsed/plan.duration,t=smoothstep(raw);
  if(plan.kind==='hold')return b;
  if(plan.kind==='blink'){
    const p=unit(raw),blink=p<.12||p>.78?0:p<=.45?unit((p-.12)/.33):unit((.78-p)/.33);
    return {...b,leftEyeOpenAmount:b.leftEyeOpenAmount*(1-blink),rightEyeOpenAmount:b.rightEyeOpenAmount*(1-blink)};
  }
  const frame=Object.fromEntries(Object.keys(a).map(key=>[key,mix(a[key as keyof GuardianFrame],b[key as keyof GuardianFrame],t)])) as GuardianFrame;
  if(plan.from==='awake'&&plan.to==='grateful'||plan.from==='grateful'&&plan.to==='awake'){
    const p=plan.to==='grateful'?t:1-t,close=smoothstep((p-.34)/.66);
    frame.sleepyEyeAmount=0;frame.happyEyeAmount=smoothstep(p/.44);frame.leftEyeOpenAmount=1-close;frame.rightEyeOpenAmount=1-close;
  }
  return frame;
}

export function guardianEye(frame:GuardianFrame,size:number,right=false,minimumFeatureScale=1){
  const open=unit(right?frame.rightEyeOpenAmount:frame.leftEyeOpenAmount),happy=unit(frame.happyEyeAmount),concern=unit(frame.concernAmount);
  const length=Math.max(1-open,unit(happy/.85)),feature=Math.max(.72,Math.min(1,minimumFeatureScale));
  const width=size*(.074+length*.066+concern*.014)*feature,height=size*(.064+open*.004+happy*.006-concern*.012)*feature;
  const curve=unit(happy/.92)-unit(frame.sleepyEyeAmount)*Math.max(0,1-open*5)-(right?unit(frame.winkAmount):0)*Math.max(0,1-open*2)*.24;
  const bend=Math.abs(curve),closed=Math.max(1-open,bend),lineWidth=Math.max(2,height*mix(1,.5,closed));
  const start=Math.min(lineWidth/2,width/2-Math.max(.5,width*.04)/2),end=Math.max(width-lineWidth/2,width/2+Math.max(.5,width*.04)/2);
  const y=height*mix(.5,curve>0?.32+bend*.30:.32,closed),control=height*mix(.5,curve>0?.32-bend*.32:.32+bend*.68,closed);
  return {width,height,lineWidth,path:`M ${start} ${y} Q ${width/2} ${control} ${end} ${y}`,rotation:(right?-4:4)*(1-open)*(1-happy*.4)+(right?5:-5)*concern};
}
