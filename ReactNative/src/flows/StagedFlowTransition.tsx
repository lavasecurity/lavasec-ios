import {useLayoutEffect,useRef,useState,type ReactNode} from 'react';
import {Animated,Easing,Keyboard,View} from 'react-native';
import {useWindowLayout} from '../window-layout';
import {useCrossFadePreference} from './ui';

/** Shared counterpart of LavaFlowTransition; outgoing content has no action or AX authority. */
export function StagedFlowTransition({stageID,direction,children,stretch=true}:{stageID:string;direction:'forward'|'backward';children:ReactNode;stretch?:boolean}){
  const crossFade=useCrossFadePreference();const {width}=useWindowLayout();
  const progress=useRef(new Animated.Value(1)).current;
  const previous=useRef({stageID,children});
  if(previous.current.stageID===stageID)previous.current.children=children;
  const [outgoing,setOutgoing]=useState<ReactNode>();const [measuredWidth,setMeasuredWidth]=useState(0);
  useLayoutEffect(()=>{
    const old=previous.current;previous.current={stageID,children};
    if(old.stageID===stageID)return;
    Keyboard.dismiss();setOutgoing(old.children);progress.setValue(0);
    const animation=Animated.timing(progress,{toValue:1,duration:crossFade?200:320,easing:crossFade?Easing.inOut(Easing.ease):Easing.out(Easing.cubic),useNativeDriver:true});
    animation.start(({finished})=>{if(finished)setOutgoing(undefined);});return()=>animation.stop();
  },[stageID]);
  const distance=(direction==='forward'?1:-1)*(measuredWidth||width);
  return <View onLayout={event=>setMeasuredWidth(event.nativeEvent.layout.width)} style={{...(stretch?{flex:1}:{}),overflow:'hidden'}}>
    {outgoing&&<Animated.View pointerEvents="none" accessibilityElementsHidden importantForAccessibility="no-hide-descendants" style={{position:'absolute',top:0,right:0,bottom:0,left:0,opacity:crossFade?progress.interpolate({inputRange:[0,1],outputRange:[1,0]}):1,transform:[{translateX:crossFade?0:progress.interpolate({inputRange:[0,1],outputRange:[0,-distance]})}]}}>{outgoing}</Animated.View>}
    <Animated.View style={{...(stretch?{flex:1}:{}),opacity:crossFade?progress:1,transform:[{translateX:crossFade?0:progress.interpolate({inputRange:[0,1],outputRange:[distance,0]})}]}}>{children}</Animated.View>
  </View>;
}
