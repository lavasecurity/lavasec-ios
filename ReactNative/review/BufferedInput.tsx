import {useImperativeHandle,useLayoutEffect,useRef,useState,type ComponentRef,type Ref} from 'react';
import {Platform,StyleSheet,TextInput,type TextInputProps} from 'react-native';
import NativeInput from '../specs/LavaTextFieldNativeComponent';

export type BufferedInputHandle=ComponentRef<typeof NativeInput>;
/** The platform owns uninterrupted keyboard editing; only an explicit reset
 * replaces its buffer. The iOS leaf also enforces composed-character limits
 * before an asynchronous report acknowledgement can replace a newer edit. */
export type BufferedInputProps=TextInputProps&{
  ref?:Ref<BufferedInputHandle>;resetRevision?:number;characterLimit?:number;grows?:boolean;nativeKind?:'wireGuardName';ownerID?:string;
};
export function BufferedInput({ref,value,defaultValue,resetRevision=0,characterLimit=0,grows=false,nativeKind,ownerID,...props}:BufferedInputProps){
  const input=useRef<BufferedInputHandle>(null);const initial=useRef(value??defaultValue??'');const reset=useRef(resetRevision);
  const [height,setHeight]=useState(0);
  useImperativeHandle(ref,()=>input.current!,[]);
  useLayoutEffect(()=>{if(reset.current!==resetRevision){reset.current=resetRevision;if(Platform.OS!=='ios')input.current?.setNativeProps({text:value??''});}},[resetRevision,value]);
  useLayoutEffect(()=>{if(Platform.OS!=='ios'&&props.editable===false)(input.current as ComponentRef<typeof TextInput>|null)?.blur();},[props.editable]);
  if(Platform.OS==='ios')return <NativeInput ref={input} testID={props.testID} accessibilityLabel={props.accessibilityLabel}
    inputLabel={props.accessibilityLabel??''} placeholder={props.placeholder??''} value={value??defaultValue??''} resetRevision={resetRevision}
    kind={nativeKind??(props.multiline?'prose':props.clearButtonMode?'search':'plain')} ownerID={ownerID} editable={props.editable!==false}
    keyboardType={props.keyboardType} autoCapitalize={props.autoCapitalize} autoCorrect={props.autoCorrect} spellCheck={props.spellCheck} smartInsertDelete={props.smartInsertDelete} clearButtonMode={props.clearButtonMode} characterLimit={characterLimit} selectionColor={props.selectionColor}
    fontPointSize={StyleSheet.flatten(props.style)?.fontSize}
    lineHeight={StyleSheet.flatten(props.style)?.lineHeight}
    textColor={StyleSheet.flatten(props.style)?.color} placeholderTextColor={props.placeholderTextColor}
    onChange={event=>{props.onChangeText?.(event.nativeEvent.text);}}
    onSubmit={event=>{props.onSubmitEditing?.(event as unknown as Parameters<NonNullable<TextInputProps['onSubmitEditing']>>[0]);}}
    onFocusChange={event=>{if(event.nativeEvent.focused)props.onFocus?.(event as unknown as Parameters<NonNullable<TextInputProps['onFocus']>>[0]);else props.onBlur?.(event as unknown as Parameters<NonNullable<TextInputProps['onBlur']>>[0]);}}
    onSizeChange={grows?event=>setHeight(event.nativeEvent.height):undefined}
    style={[props.style,grows&&height?{height}:undefined]}/>;
  return <TextInput {...props} ref={input as Ref<ComponentRef<typeof TextInput>>} defaultValue={initial.current}/>;
}
