import type {PreparationSnapshot} from './contract';

export const preparationFillDuration=550;
export const preparationSuccessGlyphHold=650;
const clamp=(value:number)=>Math.max(0,Math.min(1,value));

/** SwiftUI easeOut's cubic-bezier(0,0,.58,1), with elapsed time as x. */
export function preparationEaseOut(elapsed:number):number {
  const x=clamp(elapsed);let low=0,high=1;
  for(let i=0;i<24;i++){
    const t=(low+high)/2;
    const curveX=3*(1-t)*t*t*.58+t*t*t;
    if(curveX<x)low=t;else high=t;
  }
  const t=(low+high)/2;
  return x===0?0:x===1?1:3*(1-t)*t*t+t*t*t;
}
export type PreparationFrame={progress:number;glyph:boolean;complete:boolean};

/** One monotonic timeline for both accessibility settings. Native truth alone
 * selects terminal success. A missed saving-top snapshot is staged before the
 * final sweep, including when RN first mounts after native commit. */
export class PreparationProgressMotion {
  private id='';private from=0;private target=0;private started=0;
  private success=false;private pendingSuccess=false;private glyphAt:number|undefined;
  private pausedAt:number|undefined;

  update(snapshot:PreparationSnapshot,now:number):void {
    if(snapshot.id!==this.id){
      this.id=snapshot.id;this.success=snapshot.state==='success';
      this.from=this.success ? .75 : clamp(snapshot.progress);this.target=this.from;this.started=now;
      this.pendingSuccess=this.success;this.glyphAt=undefined;this.pausedAt=undefined;
      return;
    }
    const current=this.value(now);
    const success=snapshot.state==='success';
    // A delivered saving-top target may still be easing when native's 500ms
    // hold ends. Continue that displayed value toward the latest native 100%
    // target; restarting a 550ms approach to 75% would lengthen normal pacing.
    const missingSavingTop=success&&(this.pendingSuccess||this.target<.75&&current<.75);
    const next=success ? (missingSavingTop ? .75 : 1) : clamp(snapshot.progress);
    if(this.success===success&&this.target===next)return;
    this.success=success;this.pendingSuccess=missingSavingTop;
    this.from=current;this.target=next;this.started=this.pausedAt??now;this.glyphAt=undefined;
  }

  pause(now:number):void { if(this.pausedAt===undefined)this.pausedAt=now; }
  resume(now:number):void {
    if(this.pausedAt===undefined)return;
    const duration=now-this.pausedAt;this.started+=duration;
    if(this.glyphAt!==undefined)this.glyphAt+=duration;
    this.pausedAt=undefined;
  }

  private value(now:number):number {
    const time=this.pausedAt??now;
    return this.from+(this.target-this.from)*preparationEaseOut((time-this.started)/preparationFillDuration);
  }

  needsFrame(now:number):boolean {
    if(this.pausedAt!==undefined)return false;
    return this.pendingSuccess||this.value(now)!==this.target
      ||this.success&&this.target===1&&(this.glyphAt===undefined||now-this.glyphAt<preparationSuccessGlyphHold);
  }

  frame(now:number):PreparationFrame {
    const time=this.pausedAt??now;
    const progress=this.value(time);
    if(this.pendingSuccess&&progress>=.75){
      this.pendingSuccess=false;this.from=.75;this.target=1;this.started=time;
      return {progress:.75,glyph:false,complete:false};
    }
    const glyph=this.success&&!this.pendingSuccess&&this.target===1&&progress>=1;
    if(glyph&&this.glyphAt===undefined)this.glyphAt=time;
    return {progress,glyph,complete:glyph&&time-(this.glyphAt??time)>=preparationSuccessGlyphHold};
  }
}
