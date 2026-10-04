import {useEffect,useState} from 'react';
import {PixelRatio,Text,View,type LayoutChangeEvent} from 'react-native';
import {localized} from '../app/presentation';
import Decoration from '../specs/LavaDecorationNativeComponent';
import Surface from '../specs/LavaShareCardSurfaceNativeComponent';
import QR from '../specs/LavaShareQrNativeComponent';

/** Native owns this immutable payload witness. Names and recipient tier never enter the image. */
export interface ShareCardContent {
  token:string;
  payload:string;
  moduleCount:number;
  labels:string[];
}

export const shareCardPixels={width:1080,height:1350,scale:3} as const;

/** Allocate whole export pixels per module, including four white modules on every side. */
export function shareCardQrSide(moduleCount:number,availablePixels:number):number {
  if(!Number.isInteger(moduleCount)||moduleCount<21||moduleCount>177||!Number.isFinite(availablePixels))return 0;
  const total=moduleCount+8;
  const module=Math.floor(Math.min(882,availablePixels)/total);
  return module>=3?module*total:0;
}

/** One recipient-card composition on iOS and Android. Native leaves draw only the QR and mascot.
 * Layout uses export pixels rather than the sender's text scale or screen density. The offscreen
 * tree remains mounted for the native snapshot port, but is absent from interaction/accessibility.
 */
export function FilterShareCard({content,onReady}:{content:ShareCardContent;onReady?:(ready:boolean)=>void}) {
  const density=PixelRatio.get();
  const p=shareCardPixels.scale/density;
  const [field,setField]=useState({width:0,height:0});
  const side=shareCardQrSide(content.moduleCount,Math.min(field.width,field.height));
  const [ready,setReady]=useState(false);
  useEffect(()=>{
    setReady(false);onReady?.(false);
    if(!side)return;
    let second=0;
    const first=requestAnimationFrame(()=>{second=requestAnimationFrame(()=>{setReady(true);onReady?.(true);});});
    return()=>{cancelAnimationFrame(first);if(second)cancelAnimationFrame(second);onReady?.(false);};
  },[content.token,side,onReady]);
  const fieldLayout=(event:LayoutChangeEvent)=>{
    const {width,height}=event.nativeEvent.layout;
    const next={width:Math.round(width*density),height:Math.round(height*density)};
    setField(previous=>previous.width===next.width&&previous.height===next.height?previous:next);
  };
  const text={allowFontScaling:false} as const;
  return <View pointerEvents="none" accessible={false} accessibilityElementsHidden importantForAccessibility="no-hide-descendants"
    style={{position:'absolute',left:-10000,top:0,width:1080/density,height:1350/density}}>
    <Surface testID="share-card-export" token={content.token} payload={content.payload} ready={ready}
      accessible={false} accessibilityElementsHidden importantForAccessibility="no-hide-descendants"
      style={{width:1080/density,height:1350/density,backgroundColor:'#FFFFFF'}}>
      <View style={{height:4*p,backgroundColor:'#F2572E'}}/>
      <View style={{flex:1,paddingHorizontal:33*p}}>
        <View style={{paddingTop:8*p,flexShrink:0,flexDirection:'row',alignItems:'center',minHeight:42*p,gap:8*p}}>
          <View style={{paddingHorizontal:8*p}}><Decoration mood="awake" look="original" colorScheme="light" staticExport
            accessible={false} style={{width:42*p,height:42*p}}/></View>
          <View style={{flex:1,gap:5*p}}>
            <Text {...text} style={{includeFontPadding:false,fontSize:13*p,lineHeight:16*p,fontWeight:'600',color:'#14120F'}}>
              <Text style={{color:'#F2572E'}}>Lava Security </Text>{localized('Shared filter')}
            </Text>
            {!!content.labels.length&&<View style={{alignSelf:'flex-start',paddingHorizontal:7*p,paddingVertical:3.5*p,borderRadius:30*p,backgroundColor:'#F4F0EB',gap:2*p}}>
              {Array.from({length:Math.ceil(content.labels.length/2)},(_,index)=><Text key={index} {...text}
                style={{includeFontPadding:false,fontSize:9*p,lineHeight:11*p,fontWeight:'600',color:'#544D47'}}>
                {content.labels.slice(index*2,index*2+2).join(' · ')}
              </Text>)}
            </View>}
          </View>
        </View>
        <View testID="share-card-qr-field" onLayout={fieldLayout} style={{flex:1,minHeight:0}}>
          {!!side&&<QR testID="share-card-export-qr" payload={content.payload} moduleCount={content.moduleCount}
            style={{position:'absolute',left:Math.floor((field.width-side)/2)/density,top:Math.floor((field.height-side)/2)/density,width:side/density,height:side/density}}/>}
        </View>
        <Text {...text} style={{includeFontPadding:false,flexShrink:0,fontSize:12*p,lineHeight:15*p,fontWeight:'600',color:'#14120F',textAlign:'center'}}>
          {localized('Scan to import — or to get Lava first')}
        </Text>
        <Text {...text} style={{includeFontPadding:false,flexShrink:0,fontSize:9.5*p,lineHeight:12*p,color:'#5E5952',textAlign:'center',marginTop:4*p}}>
          {localized('New? Install, finish setup, then scan again.')}
        </Text>
        <View style={{height:14*p,flexShrink:0}}/>
        <Text {...text} style={{includeFontPadding:false,flexShrink:0,fontSize:8*p,lineHeight:10*p,color:'#6B635C',textAlign:'center',paddingBottom:7*p}}>
          {localized('Shared by another person. Not reviewed by Lava Security.')}
        </Text>
      </View>
    </Surface>
  </View>;
}
