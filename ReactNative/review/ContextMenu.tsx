import {colors} from '../src/colors.ios';
import {useId,type PropsWithChildren} from 'react';
import {localized} from '../app/presentation';
import NativeContextMenu from '../specs/LavaContextMenuNativeComponent';
export function ContextMenu({children,actions,onAction,label,testID}:PropsWithChildren<{actions:{id:string;title:string;symbol:string}[];onAction:(id:string)=>void;label?:string;testID?:string}>){
  const identity=useId();
  const translated=actions.map(action=>({...action,title:localized(action.title)}));
  return <NativeContextMenu blockedTintColor={colors.lavaOrange} allowedTintColor={colors.safeGreen} contextID={testID??identity} testID={testID} actions={translated} onAction={event=>onAction(event.nativeEvent.id)}
    accessible={!!label} accessibilityLabel={label} accessibilityActions={translated.map(action=>({name:action.id,label:action.title}))}
    onAccessibilityAction={event=>onAction(event.nativeEvent.actionName)}>{children}</NativeContextMenu>;
}
