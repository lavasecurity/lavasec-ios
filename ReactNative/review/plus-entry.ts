import {useEffect,useRef} from 'react';
import {useReviewNavigation} from './navigation';
import {usePlusIntents,type PlusReason,type PlusResume} from './plus-intents';

export function usePlusEntry(){
  const nav=useReviewNavigation();const intents=usePlusIntents();
  const pending=useRef<string|undefined>(undefined);
  useEffect(()=>()=>{if(pending.current)intents.remove(pending.current);},[intents]);
  return (reason:PlusReason,resume?:PlusResume)=>nav.navigateToUpgrade(()=>{
    if(pending.current)intents.remove(pending.current);
    const intent=resume?intents.add(resume):undefined;pending.current=intent;
    return {reason,intent};
  });
}
