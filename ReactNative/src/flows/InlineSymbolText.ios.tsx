import {useRef,useState} from 'react';
import {localized} from '../../app/presentation';
import {useTextScale} from '../../app/text-metrics';
import {useLavaColorScheme} from '../appearance';
import NativeInlineSymbolText from '../../specs/LavaInlineSymbolTextNativeComponent';
import type {InlineSymbolTextProps} from './inline-symbol-text';

/** Native owns one inline run. React owns colors, type, width and its parent. */
export function InlineSymbolText({title,symbol,tintColor,textColor,fontSize,fontWeight,testID}:InlineSymbolTextProps){
  const scale=useTextScale('headline');const colorScheme=useLavaColorScheme();
  const [width,setWidth]=useState(0);const [height,setHeight]=useState(22*scale);
  const measurementID=JSON.stringify([localized(title),symbol,fontSize*scale,fontWeight,colorScheme,width]);
  const current=useRef(measurementID);current.current=measurementID;
  return <NativeInlineSymbolText title={localized(title)} symbol={symbol} tintColor={tintColor} textColor={textColor}
    fontSize={fontSize*scale} fontWeight={fontWeight} colorScheme={colorScheme} measurementID={measurementID} testID={testID}
    style={{width:'100%',height}} onLayout={event=>{const next=event.nativeEvent.layout.width;if(Number.isFinite(next)&&next>0)setWidth(previous=>Math.abs(previous-next)>.5?next:previous);}}
    onSizeChange={event=>{const value=event.nativeEvent;if(value.measurementID===current.current&&Number.isFinite(value.height)&&value.height>0&&Number.isFinite(value.width)&&Math.abs(value.width-width)<.5)setHeight(previous=>Math.abs(previous-value.height)>.01?value.height:previous);}}/>;
}
