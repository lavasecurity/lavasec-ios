import {useEffect,useState} from 'react';
import {AccessibilityInfo,AppState,Platform} from 'react-native';
import type {NativeStackNavigationOptions} from '@react-navigation/native-stack';

/** UIKit owns ordinary page and navigation-bar transitions together. */
export function ordinaryPushPresentation(crossFade:boolean):NativeStackNavigationOptions {
  return {
    // simple_push omits the native header transition. Use UIKit's default
    // animator so titles and bar items travel with the page, including cancelled pops.
    // Preserve the explicit system cross-fade preference.
    animation:crossFade?'fade':Platform.OS==='ios'?'default':'slide_from_right',
    animationMatchesGesture:crossFade,
    // Horizontal controls keep their own gestures; native back starts at the edge.
    fullScreenGestureEnabled:false,
  };
}

export function useReducedMotionPreference():boolean {
  // Avoid introducing motion before the system accessibility preference arrives.
  const [reduceMotion,setReduceMotion]=useState(true);
  useEffect(()=>{
    let mounted=true;let changed=false;
    const subscription=AccessibilityInfo.addEventListener('reduceMotionChanged',enabled=>{
      changed=true;setReduceMotion(enabled);
    });
    void AccessibilityInfo.isReduceMotionEnabled().then(enabled=>{
      if(mounted&&!changed)setReduceMotion(enabled);
    }).catch(()=>{});
    return()=>{mounted=false;subscription.remove();};
  },[]);
  return reduceMotion;
}

export function useOrdinaryPushPresentation():NativeStackNavigationOptions {
  return ordinaryPushPresentation(useCrossFadePreference());
}

export function useCrossFadePreference():boolean {
  const [crossFade,setCrossFade]=useState(false);
  useEffect(()=>{
    let mounted=true;let epoch=0;
    const read=()=>{const request=++epoch;
      const preference=Platform.OS==='ios'?AccessibilityInfo.prefersCrossFadeTransitions():AccessibilityInfo.isReduceMotionEnabled();
      void preference.then(value=>{if(mounted&&request===epoch)setCrossFade(value);}).catch(()=>{});
    };
    read();
    const motion=AccessibilityInfo.addEventListener('reduceMotionChanged',read);
    const state=AppState.addEventListener('change',value=>{if(value==='active')read();});
    return()=>{mounted=false;motion.remove();state.remove();};
  },[]);
  return crossFade;
}
