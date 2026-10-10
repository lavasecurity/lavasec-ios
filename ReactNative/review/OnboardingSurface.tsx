import {useEffect,useRef,useState,type ComponentRef,type PropsWithChildren} from 'react';
import {View} from 'react-native';
import {NavigationContainer,NavigationIndependentTree,createNavigationContainerRef} from '@react-navigation/native';
import {createNativeStackNavigator} from '@react-navigation/native-stack';
import {SafeAreaProvider} from 'react-native-safe-area-context';
import type {OnboardingSetup} from '../app/contract';
import {useReview} from './ReviewContext';
import {nativeFlowHeader,onboardingHeaderOptions} from './scaffold';
import {useLavaColorScheme} from '../src/appearance';
import {OnboardingFlow} from './OnboardingFlow';
import {OnboardingGeometryContext,useOnboardingMeasurements} from './onboarding-geometry';

type SurfaceRoutes={Runtime:undefined;Onboarding:undefined};
const Stack=createNativeStackNavigator<SurfaceRoutes>();

/** One RN tree measures both setup and its real Guard destination. The native
 * stack owns the full-window modal, safe areas, touch delivery and status bar. */
export function OnboardingSurface({children,enabled=true}:PropsWithChildren<{enabled?:boolean}>){
  const {live,onboardingPreview}=useReview();const scheme=useLavaColorScheme();
  const retained=useRef<OnboardingSetup|undefined>(undefined);
  if(live)retained.current=live.onboardingSetup?.mock===!!onboardingPreview?live.onboardingSetup:undefined;
  const setup=enabled?retained.current:undefined;
  const [navigation]=useState(()=>createNavigationContainerRef<SurfaceRoutes>());
  const [ready,setReady]=useState(false);
  const initialState=useRef({index:setup?1:0,routes:setup?[{name:'Runtime'},{name:'Onboarding'}]:[{name:'Runtime'}]}).current;
  useEffect(()=>{
    if(!ready)return;const current=navigation.getCurrentRoute()?.name;
    if(setup&&current!=='Onboarding')navigation.navigate('Onboarding');
    else if(!setup&&current==='Onboarding'&&navigation.canGoBack())navigation.goBack();
  },[ready,setup?.id,navigation]);
  const panel=useRef<ComponentRef<typeof View>>(null),mascot=useRef<ComponentRef<typeof View>>(null),action=useRef<ComponentRef<typeof View>>(null),source=useRef<ComponentRef<typeof View>>(null),root=useRef<ComponentRef<typeof View>>(null);
  const [size,setSize]=useState({width:0,height:0});
  const {origin,frames,sourceFrame}=useOnboardingMeasurements(setup?.id,{root,source,panel,mascot,action});
  return <OnboardingGeometryContext.Provider value={{panel,mascot,action,source,root,frames,sourceFrame,origin,size,setup}}>{enabled?<NavigationIndependentTree><NavigationContainer ref={navigation} initialState={initialState} onReady={()=>setReady(true)}>
    <Stack.Navigator screenOptions={{headerShown:false,animation:'none'}}>
      <Stack.Screen name="Runtime">{()=> <NavigationIndependentTree><View style={{flex:1}} pointerEvents={setup?'none':'auto'} accessibilityElementsHidden={!!setup} importantForAccessibility={setup?'no-hide-descendants':'auto'}>{children}</View></NavigationIndependentTree>}</Stack.Screen>
      <Stack.Screen name="Onboarding" options={{...nativeFlowHeader(scheme==='dark'),...onboardingHeaderOptions,headerShown:true,presentation:'transparentModal',gestureEnabled:false,statusBarStyle:setup?.page===0||scheme==='dark'?'light':'dark'}}>
        {()=> <SafeAreaProvider><View ref={root} collapsable={false} style={{flex:1}} onLayout={event=>setSize(event.nativeEvent.layout)} testID="onboarding.surface"><OnboardingFlow/></View></SafeAreaProvider>}
      </Stack.Screen>
    </Stack.Navigator>
  </NavigationContainer></NavigationIndependentTree>:children}</OnboardingGeometryContext.Provider>;
}
