import {useRef,useState} from 'react';
import {localized} from '../app/presentation';
import NativeSwitch from '../specs/LavaSwitchNativeComponent';
import {colors} from './colors.ios';
import type {LavaToggleRowProps} from './contracts';
import {LavaControlContent} from './row-content';
import {foundation} from './foundation';

// Both app and gallery use the measured UIKit switch. The parent remains the
// source of truth; optimistic presentation is explicit for asynchronous changes.
function useToggleControl({title,verbatimTitle=false,summary,value,onValueChange,disabled=false,pending:externalPending=false,optimistic=false,accessibilityHint,testID}:LavaToggleRowProps) {
  const pending=useRef(false);
  const [intent,setIntent]=useState<boolean>();
  const [resetRevision,setResetRevision]=useState(0);
  const [size,setSize]=useState<{width:number;height:number}>(foundation.nativeSwitch);
  const change=(next:boolean)=>{
    if(disabled||externalPending||pending.current)return;
    // Own the gesture before invoking the parent. A synchronous native state
    // publication or another label/native event cannot dispatch it twice.
    pending.current=true;
    const finish=()=>{pending.current=false;setIntent(undefined);setResetRevision(revision=>revision+1);};
    let completion:ReturnType<typeof onValueChange>;
    try {completion=onValueChange(next);} catch(error) {finish();throw error;}
    if(completion&&typeof completion.then==='function'){
      setIntent(next);
      void completion.then(finish,finish);
    }else finish();
  };
  const control=<NativeSwitch testID={testID} label={verbatimTitle?title:localized(title)} accessibilityHint={accessibilityHint!==undefined?localized(accessibilityHint):summary?localized(summary):undefined} accessible={false}
      pointerEvents={externalPending||intent!==undefined?'none':'auto'} pending={externalPending||intent!==undefined} value={optimistic?(intent??value):value}
      optimistic={optimistic} resetRevision={resetRevision} disabled={disabled} onValueChange={event=>change(event.nativeEvent.value)}
      onSizeChange={event=>{const {width,height}=event.nativeEvent;if(width>0&&height>0&&Number.isFinite(width)&&Number.isFinite(height))setSize({width,height});}}
      tintColor={colors.safeGreen} style={size}/>;
  return {change,control};
}

// The same native switch can occupy a numbered list row's accessory lane.
export function LavaToggleControl(props:LavaToggleRowProps) { return useToggleControl(props).control; }
export function LavaToggleRow(props:LavaToggleRowProps) {
  const {change,control}=useToggleControl(props);
  return <LavaControlContent title={props.title} summary={props.summary} titleRole={props.titleRole} verbatimTitle={props.verbatimTitle} disabled={props.disabled} onLabelPress={()=>change(!props.value)} testID={props.testID}>{control}</LavaControlContent>;
}
