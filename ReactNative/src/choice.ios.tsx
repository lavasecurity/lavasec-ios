import {useEffect,useRef,useState} from 'react';
import NativeChoice from '../specs/LavaChoiceNativeComponent';
import type {LavaChoiceProps} from './contracts';
import {colors} from './colors.ios';
import {useFeedback} from './feedback';

export function LavaChoice<Value extends string>({label, options, value, onValueChange, reselectValue, disabled = false, testID, presentation = 'segments'}: LavaChoiceProps<Value>) {
  const feedback=useFeedback();
  const [selectionRevision,setSelectionRevision]=useState(0);
  const [pending,setPending]=useState<{value:Value;generation:number}>();
  const generation=useRef(0);
  const mounted=useRef(true);
  useEffect(()=>{mounted.current=true;return()=>{mounted.current=false;};},[]);
  const [height, setHeight] = useState(32);
  const displayed=pending&&options.some(option=>option.value===pending.value)?pending.value:value;
  return <NativeChoice selectionRevision={selectionRevision} label={label} controlID={testID ?? label} options={options} value={displayed} reselectValue={reselectValue} disabled={disabled} stepper={presentation==='stepper'} pageControl={presentation==='pages'}
    accessible={false} testID={testID} tintColor={colors.safeGreen} style={presentation==='stepper'?{height,width:94}:{height,alignSelf:'stretch'}}
    onValueChange={event => {
      // A queued native event carries a stable value, never an index into a newer option list.
      const option = options.find(candidate => candidate.value === event.nativeEvent.value);
      if (disabled || !option || (option.value === displayed && option.value !== reselectValue)){setSelectionRevision(previous=>previous+1);return;}
      const request=++generation.current;
      const acknowledge=()=>{if(mounted.current&&request===generation.current){setPending(undefined);setSelectionRevision(previous=>previous+1);}};
      // An acknowledgement reconciles UIKit to the authoritative value. Sending
      // it before an async owner finishes visibly restores the previous segment.
      // Hold native tracking until settlement; rejection/cancellation then uses
      // the same reconciliation, without inventing a saved optimistic value.
      try{
        const result=onValueChange(option.value);
        // UIPageControl owns its system response; programmatic reconciliation never enters here.
        if(option.value!==displayed&&presentation!=='pages') feedback.emit({semantic:'selected',controlID:testID??label,value:option.value});
        if(result&&typeof result.then==='function'){
          setPending({value:option.value,generation:request});
          void result.then(acknowledge,acknowledge);
        }else acknowledge();
      }catch(error){acknowledge();throw error;}
    }}
    onSizeChange={event => {
      const next = event.nativeEvent.height;
      if (Number.isFinite(next) && next > 0) setHeight(next);
    }} />;
}
