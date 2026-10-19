import {useContext,useRef,useState} from 'react';
import {PixelRatio,type ColorValue} from 'react-native';
import {PresentationContext} from '../app/presentation';
import {useTextScale} from '../app/text-metrics';
import {useLavaColorScheme} from '../src/appearance';
import NativeInlineSymbolText from '../specs/LavaInlineSymbolTextNativeComponent';

type Alignment='leading'|'center'|'trailing';
type TextStyle='headline'|'title1'|'subheadline'|'footnote';

/** One system Text run. RN supplies its content, typography, width and placement. */
export function NativeTextRun({text,textStyle,fontSize,fontWeight,color,contentAlignment='leading',multilineAlignment='leading',testID}:{
  text:string;textStyle:TextStyle;fontSize:number;fontWeight:'regular'|'semibold'|'bold';color:ColorValue;
  contentAlignment?:Alignment;multilineAlignment?:Alignment;testID?:string;
}){
  const scale=useTextScale(textStyle),colorScheme=useLavaColorScheme();
  const {nativeTextMetrics}=useContext(PresentationContext);
  const fontPointSize=fontSize*scale,metric=nativeTextMetrics?.[textStyle];
  const initialHeight=metric&&Number.isFinite(metric.lineHeight)&&metric.lineHeight>0&&Math.abs(metric.fontSize-fontPointSize)<.01
    ?Math.ceil(metric.lineHeight*PixelRatio.get())/PixelRatio.get():fontPointSize*1.25;
  const [width,setWidth]=useState(0);
  const measurementID=JSON.stringify([text,textStyle,fontPointSize,fontWeight,colorScheme,contentAlignment,multilineAlignment,width]);
  const current=useRef(measurementID);current.current=measurementID;
  const [measured,setMeasured]=useState<{id:string;height:number}>();
  const height=measured?.id===measurementID?measured.height:initialHeight;
  return <NativeInlineSymbolText title={text} symbol="" tintColor={color} textColor={color}
    fontSize={fontPointSize} fontWeight={fontWeight} textStyle={textStyle} colorScheme={colorScheme}
    contentAlignment={contentAlignment} multilineAlignment={multilineAlignment} measurementID={measurementID} testID={testID}
    style={{width:'100%',height}} onLayout={event=>{
      const next=event.nativeEvent.layout.width;
      if(Number.isFinite(next)&&next>0)setWidth(previous=>Math.abs(previous-next)>.5?next:previous);
    }} onSizeChange={event=>{
      const value=event.nativeEvent;
      if(value.measurementID!==current.current||!Number.isFinite(value.height)||value.height<=0
        ||!Number.isFinite(value.width)||value.width<=0||Math.abs(value.width-width)>=.5)return;
      setMeasured(previous=>previous?.id===value.measurementID&&Math.abs(previous.height-value.height)<=.01?previous:{id:value.measurementID,height:value.height});
    }}/>
}
