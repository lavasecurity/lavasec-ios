import {createContext,useContext,useId,useMemo} from 'react';

export type FeedbackEvent = {semantic:'selected'|'engaged'|'succeeded'|'attentionRequired'|'failed'|'acknowledged'|'inspectionEmpty';controlID:string;value?:string};
export type Feedback = {emit:(event:FeedbackEvent)=>void};
const context=createContext<Feedback>({emit:()=>{}});
export const FeedbackProvider=context.Provider;
export function useFeedback():Feedback {
  const parent=useContext(context);
  // The native deduplicator outlives screens. A new control instance must not
  // inherit the final selection of a dismissed instance with the same name.
  // useId is stable through rerenders; it changes only with component identity.
  const scope=useId();
  return useMemo(()=>({emit:(event:FeedbackEvent)=>parent.emit(
    event.semantic==='selected'||event.semantic==='inspectionEmpty'
      ? {...event,controlID:`${event.controlID}@${scope}`} : event
  )}),[parent,scope]);
}
