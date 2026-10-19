import {useState} from 'react';
import NativeChoice from '../specs/LavaChoiceNativeComponent';
import type {LavaChoiceProps} from './contracts';
import {colors} from './colors.ios';
import {useChoiceRequest} from './ui/behavior/choice';

export function LavaChoice<Value extends string>({label, options, value, onValueChange, reselectValue, disabled = false, testID, presentation = 'segments'}: LavaChoiceProps<Value>) {
  const {displayed,selectionRevision,change}=useChoiceRequest({label,options,value,onValueChange,reselectValue,disabled,testID,presentation});
  const [height, setHeight] = useState(32);
  return <NativeChoice selectionRevision={selectionRevision} label={label} controlID={testID ?? label} options={options} value={displayed} reselectValue={reselectValue} disabled={disabled} stepper={presentation==='stepper'} pageControl={presentation==='pages'}
    accessible={false} testID={testID} tintColor={colors.safeGreen} style={presentation==='stepper'?{height,width:94}:{height,alignSelf:'stretch'}}
    onValueChange={event=>change(event.nativeEvent.value)}
    onSizeChange={event => {
      const next = event.nativeEvent.height;
      if (Number.isFinite(next) && next > 0) setHeight(next);
    }} />;
}
