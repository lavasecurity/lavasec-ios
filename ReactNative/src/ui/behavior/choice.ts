import {useEffect,useRef,useState} from 'react';
import {useFeedback} from '../../feedback';
import type {LavaChoiceProps} from '../contracts';

/** Existing request/acknowledgement behavior, independent of the native widget. */
export function useChoiceRequest<Value extends string>({label, options, value, onValueChange, reselectValue, disabled = false, testID, presentation = 'segments'}: LavaChoiceProps<Value>) {
  const feedback=useFeedback();
  const [selectionRevision,setSelectionRevision]=useState(0);
  const [pending,setPending]=useState<{value:Value;generation:number}>();
  const generation=useRef(0);
  const mounted=useRef(true);
  useEffect(()=>{mounted.current=true;return()=>{mounted.current=false;};},[]);
  const displayed=pending&&options.some(option=>option.value===pending.value)?pending.value:value;
  const change=(requestedValue:string)=>{
    // A queued native event carries a stable value, never an index into a newer option list.
    const option = options.find(candidate => candidate.value === requestedValue);
    if (disabled || !option || (option.value === displayed && option.value !== reselectValue)){setSelectionRevision(previous=>previous+1);return;}
    const request=++generation.current;
    const acknowledge=()=>{if(mounted.current&&request===generation.current){setPending(undefined);setSelectionRevision(previous=>previous+1);}};
    // An acknowledgement reconciles the native control to its authoritative value. Sending
    // it before an async owner finishes visibly restores the previous segment.
    // Hold native tracking until settlement; rejection/cancellation then uses
    // the same reconciliation, without inventing a saved optimistic value.
    try{
      const result=onValueChange(option.value);
      // Page indicators retain their native response; reconciliation never enters here.
      if(option.value!==displayed&&presentation!=='pages') feedback.emit({semantic:'selected',controlID:testID??label,value:option.value});
      if(result&&typeof result.then==='function'){
        setPending({value:option.value,generation:request});
        void result.then(acknowledge,acknowledge);
      }else acknowledge();
    }catch(error){acknowledge();throw error;}
  };
  return {displayed,selectionRevision,change};
}
