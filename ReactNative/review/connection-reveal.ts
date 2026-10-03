import type {ConnectionPart,ConnectionStage} from './connection-model';

export type GlyphCenter={x:number;y:number};
/** A demo frame focuses its last described part; focus marks narration, not live configuration. */
export function connectionAttention(stages:readonly ConnectionStage[],parts?:readonly ConnectionPart[]):ConnectionPart|undefined {
  return parts?.filter(id=>stages.some(stage=>stage.id===id)).at(-1);
}
/** Measure physical centers rather than assuming equal widths or a horizontal text size. */
export function connectionAperture(centers:Partial<Record<ConnectionPart,GlyphCenter>>,active?:ConnectionPart){
  const center=active?centers[active]:undefined;if(!center)return undefined;
  const distances=Object.values(centers).filter(point=>point!==center).map(point=>Math.hypot(point.x-center.x,point.y-center.y)).filter(distance=>distance>0);
  return {...center,radius:Math.max(22,(distances.length?Math.min(...distances):44)/2)};
}
