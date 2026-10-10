import {useEffect,useState} from 'react';
import {AccessibilityInfo,AppState,Platform} from 'react-native';
import type {NativeStackNavigationOptions} from '@react-navigation/native-stack';
import type {NativeBottomTabNavigationOptions} from '@react-navigation/bottom-tabs/unstable';

/** Title size does not determine whether scrolling content can extend under the native bar. */
export function ordinaryPageHeader():NativeStackNavigationOptions {
  if(Platform.OS!=='ios')return {};
  return {
    headerTransparent:true,
    headerStyle:{backgroundColor:'transparent'},
    // iOS 26 supplies its own scroll edge effect. Earlier systems use native
    // navigation chrome material; adding that blur on 26 would double the effect.
    headerBlurEffect:parseInt(String(Platform.Version),10)<26?'systemChromeMaterial':undefined,
  };
}

export function floatingTabMinimizeBehavior():NativeBottomTabNavigationOptions['tabBarMinimizeBehavior'] {
  if(Platform.OS!=='ios')return undefined;
  const major=parseInt(String(Platform.Version),10);
  // Nested native stacks do not expose their scroll view to UIKit minimization
  // on iOS 26 (react-native-screens #4145). Keep that bar expanded; enable the
  // native effect from iOS 27, where our nested-stack UI regressions pass.
  if(major>=27)return 'onScrollDown';
  return major===26?'none':undefined;
}

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
