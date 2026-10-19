import {useRef} from 'react';
import {GuardianDrawing} from '../../GuardianDrawing';
import {stableGuardianFrame} from '../../guardian-motion';

/** The native preparation Guardian wakes in both motion settings. Keep its
 * sleeping origin until the first admitted paint so initial hydration cannot
 * consume the wake, then let the canonical drawing own pause/resume behavior. */
export function PreparationGuardian({active,look}:{active:boolean;look:string}){
  const admitted=useRef(false);if(active)admitted.current=true;
  return <GuardianDrawing size={76} mood="waking" look={look} active={active}
    frame={admitted.current?undefined:stableGuardianFrame('sleeping')}/>;
}
