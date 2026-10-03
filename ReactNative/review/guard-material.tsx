import {useEffect,useRef,useState,type PropsWithChildren} from 'react';
import {Animated,AppState,StyleSheet,View,type LayoutRectangle} from 'react-native';
import {colors} from '../src/colors.ios';
import {foundation} from '../src/foundation';
import {useReducedMotionPreference} from './navigation-scaffold';

export type GuardMaterialIntent='rest'|'affirmed'|'unresolved'|'stopping'|'recovery'|'paused'|'unknown';
type Surface='rest'|'affirmed'|'neutral';
export function guardSurface(intent:GuardMaterialIntent,previous?:Surface):Surface {
  if(intent==='affirmed'||intent==='rest')return intent;
  if(intent==='stopping')return previous??'neutral';
  if(intent==='unresolved')return !previous||previous==='rest'?'rest':'neutral';
  return 'neutral';
}
export function guardDuration(intent:GuardMaterialIntent,from:Surface,to:Surface):number {
  if(from===to)return 0;
  if(to==='affirmed')return 500;
  if(to==='rest')return 550;
  return intent==='paused'?400:intent==='unknown'?300:240;
}

/** Endpoint material follows service truth immediately; only its paint is animated. */
export function GuardMaterial({intent='rest',active=true,action,children}:{intent?:GuardMaterialIntent;active?:boolean;action?:LayoutRectangle}&PropsWithChildren) {
  const initial=guardSurface(intent);
  const previous=useRef<Surface>(initial);
  const green=useRef(new Animated.Value(initial==='neutral'?0:1)).current;
  const greenOpacity=useRef(new Animated.Value(initial==='affirmed'?1:0)).current;
  const neutral=useRef(new Animated.Value(initial==='neutral'?1:0)).current;
  const animation=useRef<Animated.CompositeAnimation|undefined>(undefined);
  const generation=useRef(0);
  const foreground=useRef(AppState.currentState==='active');
  const reduceMotion=useReducedMotionPreference();
  const [size,setSize]=useState({width:1,height:1});
  const latest=useRef(initial);latest.current=guardSurface(intent,previous.current);
  useEffect(()=>{const subscription=AppState.addEventListener('change',state=>{
    foreground.current=state==='active';generation.current++;animation.current?.stop();
    green.setValue(latest.current==='neutral'?0:1);greenOpacity.setValue(latest.current==='affirmed'?1:0);neutral.setValue(latest.current==='neutral'?1:0);
  });return()=>{subscription.remove();generation.current++;animation.current?.stop();};},[green,greenOpacity,neutral]);
  useEffect(()=>{
    const next=guardSurface(intent,previous.current);
    const reconcile=!foreground.current||!active;
    // A semantic update to the same endpoint is Hold, including Turning Off while
    // Engage is still settling. Do not cancel that paint and snap to its target.
    if(next===previous.current&&!reconcile)return;
    const from=previous.current;
    const duration=reconcile?0:guardDuration(intent,from,next);
    previous.current=next;
    const epoch=++generation.current;animation.current?.stop();
    if(reconcile){green.setValue(next==='neutral'?0:1);greenOpacity.setValue(next==='affirmed'?1:0);neutral.setValue(next==='neutral'?1:0);return;}
    const timing={duration:reduceMotion?Math.min(duration,150):duration,useNativeDriver:true};
    const motions=[
      Animated.timing(greenOpacity,{...timing,toValue:next==='affirmed'?1:0}),
      Animated.timing(neutral,{...timing,toValue:next==='neutral'?1:0}),
    ];
    // Engage, release and neutral fades all cross-fade optically at the current radius;
    // only a restore from the neutral panel grows the fill from the button origin.
    // Reduce Motion keeps that same fill but never grows or moves it.
    if(from==='neutral'&&next==='affirmed'){if(reduceMotion)green.setValue(1);else motions.push(Animated.timing(green,{...timing,toValue:1}));}
    if(from==='rest'&&next==='affirmed')green.setValue(1);
    animation.current=Animated.parallel(motions);
    animation.current.start(({finished})=>{
      // Once invisible, prepare the next restore at its button origin. An old
      // completion can never reset a newer engage or release.
      if(finished&&generation.current===epoch&&previous.current==='neutral')green.setValue(0);
    });
  },[intent,active,green,greenOpacity,neutral,reduceMotion]);
  // Enabling Reduce Motion mid-paint must stop the spatial front immediately: snap the
  // material to its current surface instead of letting a restore finish growing.
  useEffect(()=>{
    if(!reduceMotion)return;
    animation.current?.stop();
    generation.current++;
    green.setValue(previous.current==='neutral'?0:1);
    greenOpacity.setValue(previous.current==='affirmed'?1:0);
    neutral.setValue(previous.current==='neutral'?1:0);
  },[reduceMotion,green,greenOpacity,neutral]);
  const diameter=Math.hypot(size.width,size.height)*2.7;
  const x=action? action.x+action.width/2:size.width/2;
  const y=action? action.y+action.height/2:size.height/2;
  return <View testID="guard.material" onLayout={event=>setSize(event.nativeEvent.layout)} style={[s.panel,{borderColor:latest.current==='neutral'?'transparent':colors.softGreen}]}>
    <View pointerEvents="none" accessibilityElementsHidden style={StyleSheet.absoluteFill}>
      <Animated.View style={[StyleSheet.absoluteFill,{backgroundColor:colors.cardBackground,opacity:neutral}]}/>
      <Animated.View style={{position:'absolute',left:x-diameter/2,top:y-diameter/2,width:diameter,height:diameter,opacity:greenOpacity,transform:[{scale:green}]}}>
        {Array.from({length:12},(_,index)=>{const inset=index*diameter*.009;const drift=Math.sin(index*.6)*diameter*.006;return <View key={index} style={{position:'absolute',left:inset+drift,right:inset-drift,top:inset-drift/2,bottom:inset+drift/2,borderRadius:diameter/2,backgroundColor:colors.softGreen,opacity:index===11?1:.13}}/>;})}
      </Animated.View>
    </View>
    <View style={s.inset}>{children}</View>
  </View>;
}
const s=StyleSheet.create({panel:{borderRadius:foundation.radius.surface,borderCurve:'continuous',overflow:'hidden',borderWidth:1,borderColor:colors.softGreen},inset:{padding:foundation.space.lg+foundation.space.xs,gap:foundation.space.lg}});
