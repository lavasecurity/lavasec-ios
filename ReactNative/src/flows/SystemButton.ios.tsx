import {useRef,useState} from 'react';
import NativeButton from '../../specs/LavaSystemButtonNativeComponent';
import {localized} from '../../app/presentation';
import {useTextScale} from '../../app/text-metrics';
import type {SystemButtonProps} from './system-button';

/** Only the system control stays native; the containing RN flow owns its action. */
export function SystemButton({title,eventID,onPress,prominent=false,disabled=false,destructive=false,testID}:SystemButtonProps){
  const scale=useTextScale();
  const current=useRef({eventID,disabled,onPress});current.current={eventID,disabled,onPress};
  const [size,setSize]=useState({width:1,height:34});
  return <NativeButton fontSize={17*scale} title={localized(title)} eventID={eventID} prominent={prominent} disabled={disabled} destructive={destructive} testID={testID}
    style={{width:size.width,height:size.height,alignSelf:'flex-start'}}
    onPress={event=>{if(!current.current.disabled&&event.nativeEvent.eventID===current.current.eventID)current.current.onPress();}}
    onSizeChange={event=>{const {width,height}=event.nativeEvent;if(Number.isFinite(width)&&Number.isFinite(height)&&width>0&&height>0)setSize(previous=>previous.width===width&&previous.height===height?previous:{width,height});}}/>;
}
