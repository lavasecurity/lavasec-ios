import type {OnboardingFrame} from '../app/contract';
export const onboardingTravelDuration=1.4;
/** The authored entrance belongs to leaving Welcome. Returning to a visited
 * page uses ordinary motion rather than replaying that first introduction. */
export function onboardingPageMotion(previousPage:number|undefined,page:number,reduced:boolean,crossFade:boolean){
  const ordinary=reduced||crossFade?200:320,featuresEntrance=previousPage===0&&page===1,leavingWelcome=previousPage===0&&page!==0;
  return {ordinary,entryDuration:featuresEntrance?(reduced?250:1250):ordinary,entryDelay:featuresEntrance&&!reduced?150:0,
    entrySmooth:featuresEntrance||reduced||crossFade,exitDuration:leavingWelcome?(reduced?250:1100):ordinary,exitSmooth:leavingWelcome||reduced||crossFade};
}
export function onboardingTravelProgress(elapsed:number,duration=onboardingTravelDuration){if(duration<=0)return 1;const t=Math.min(1,Math.max(0,elapsed/duration));return 1-Math.pow(1-t,3);}
export function lavaWavePhase(elapsed:number){return ((elapsed%18)+18)%18/18*Math.PI*2;}
export function lavaWavePath(width:number,height:number,phase:number,amplitude:number,baseline:number){
  const base=height*baseline,step=Math.max(width/96,1);let path=`M0 ${height} L0 ${base}`;
  for(let x=0;x<=width;x+=step){const p=x/Math.max(width,1),y=base+Math.sin(p*Math.PI*2+phase)*amplitude+Math.sin(p*Math.PI*4-phase)*amplitude*.34+Math.sin(p*Math.PI*6+phase*2)*amplitude*.16;path+=` L${x} ${y}`;}
  return path+` L${width} ${height} Z`;
}
export type OnboardingDestination={panel:OnboardingFrame;mascot:OnboardingFrame;action:OnboardingFrame};
/** An acknowledged phase advances once. A rejected native timing/privacy gate
 * retries at a bounded cadence; a new visit or authority retires late results. */
export class OnboardingPhaseCommands {
  private key='';private nextAttempt=0;private generation=0;
  reset(){this.key='';this.nextAttempt=0;++this.generation;}
  send(key:string,now:number,perform:()=>Promise<boolean>){
    if(this.key!==key){this.key=key;this.nextAttempt=0;++this.generation;}
    if(now<this.nextAttempt)return;
    const generation=this.generation;this.nextAttempt=Infinity;
    void perform().then(accepted=>{if(generation===this.generation&&!accepted)this.nextAttempt=now+.3;},()=>{if(generation===this.generation)this.nextAttempt=now+.3;});
  }
}
export function validOnboardingDestination(frames:OnboardingDestination){
  const all=[frames.panel,frames.mascot,frames.action];if(all.some(f=>![f.x,f.y,f.width,f.height].every(Number.isFinite)||f.width<=0||f.height<=0))return false;
  const inside=(f:OnboardingFrame)=>f.x>=frames.panel.x-1&&f.y>=frames.panel.y-1&&f.x+f.width<=frames.panel.x+frames.panel.width+1&&f.y+f.height<=frames.panel.y+frames.panel.height+1;
  return inside(frames.mascot)&&inside(frames.action);
}
/** Retarget measured geometry from the visible position without replaying an
 * old destination after rotation or a new visit. Time is injected for tests. */
export class OnboardingTravel {
  private origin:{x:number;y:number};private target:{x:number;y:number};private start:number;private duration:number;
  constructor(origin:OnboardingFrame,target:OnboardingFrame,now:number){this.origin={x:origin.x+origin.width/2,y:origin.y+origin.height/2};this.target={x:target.x+target.width/2,y:target.y+target.height/2};this.start=now;this.duration=onboardingTravelDuration;}
  position(now:number){const t=onboardingTravelProgress(now-this.start,this.duration);return {x:this.origin.x+(this.target.x-this.origin.x)*t,y:this.origin.y+(this.target.y-this.origin.y)*t};}
  retarget(target:OnboardingFrame,now:number){const next={x:target.x+target.width/2,y:target.y+target.height/2};if(next.x===this.target.x&&next.y===this.target.y)return;const remaining=Math.max(0,this.duration-(now-this.start));this.origin=this.position(now);this.target=next;this.start=now;this.duration=remaining;}
  settled(now:number){return now-this.start>=this.duration;}
}
