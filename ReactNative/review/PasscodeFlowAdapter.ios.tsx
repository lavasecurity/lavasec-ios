import {useContext,useEffect,useState,useSyncExternalStore,useRef} from 'react';
import {View,AppState,PlatformColor,useColorScheme} from 'react-native';
import {useHeaderHeight} from '@react-navigation/elements';
import {SafeAreaProvider,useSafeAreaInsets} from 'react-native-safe-area-context';
import NativeAppearance from '../specs/NativeLavaAppearance';
import {AppearanceStore} from './appearance-store';
import NativeApp from '../specs/NativeLavaApp';
import Input from '../specs/LavaPasscodeInputNativeComponent';
import {PasscodeScreen} from '../src/flows/passcode/PasscodeScreen';
import type {PasscodeState} from '../src/flows/passcode/types';
import {PresentationContext,configurePresentation,localized,type Presentation} from '../app/presentation';
import {LavaAppearanceContext} from '../src/appearance';
import {Symbol} from './primitives';
import {nativeInlineHeader,toolbarAction,useToolbar} from './scaffold';
import {NativeFlowMetrics} from './NativeFlowMetrics.ios';
import {NativeTextRun} from './NativeTextRun.ios';
import {colors} from '../src/colors';

export function PasscodeFlowAdapter({state,nativeHeader=false}:{state:PasscodeState;nativeHeader?:boolean}){
  return <NativeFlowMetrics>{nativeHeader?<NativeHeaderPasscodeBody state={state}/>:<PasscodeFlowBody state={state}/>}</NativeFlowMetrics>;
}
/** The independent security host owns its system bar and already reduces the viewport. */
function NativeHeaderPasscodeBody({state}:{state:PasscodeState}){
  const insets=useSafeAreaInsets();
  const title=localized('Authentication'),cancelTitle=localized('Cancel');
  const [ready,setReady]=useState<{id:string;title:string;cancelTitle:string}>();
  useEffect(()=>{
    let mounted=true;
    void NativeApp?.command(JSON.stringify({type:'passcode.header',id:state.id,title,cancelTitle,showCancel:true})).then(()=>{
      if(mounted&&AppState.currentState==='active')setReady({id:state.id,title,cancelTitle});
    }).catch(()=>{});
    // The native request owns chrome teardown. Sending hide from a retired JS
    // mount could hide a newer mount of the same authentication request.
    return()=>{mounted=false;};
  },[state.id,title,cancelTitle]);
  if(ready?.id!==state.id||ready.title!==title||ready.cancelTitle!==cancelTitle)return <View style={{flex:1}}/>;
  return <PasscodeBody state={state} contentInsets={insets}/>;
}
function PasscodeFlowBody({state}:{state:PasscodeState}){
  const headerHeight=useHeaderHeight();
  const insets=useSafeAreaInsets();
  const cancel=()=>{void NativeApp?.command(JSON.stringify({type:'passcode.command',id:state.id,action:'cancel'})).catch(()=>{});};
  useToolbar({...nativeInlineHeader,title:state.authenticating?'Authentication':'Passcode',headerBackVisible:false,
    ...(state.authenticating?{headerLeft:()=>null,unstable_headerLeftItems:()=>[{type:'button' as const,label:localized('Cancel'),onPress:cancel}]}:
      {unstable_headerLeftItems:()=>[toolbarAction('Cancel','close',cancel)]})},[state.id,state.authenticating]);
  // The transparent native bar overlays plain RN content. Its measured height
  // includes any remaining top safe area; add only the other residual edges.
  // SwiftUI containment already owns the keyboard's reduced viewport.
  return <PasscodeBody state={state} contentInsets={{top:headerHeight,right:insets.right,bottom:insets.bottom,left:insets.left}}/>;
}
function PasscodeBody({state,contentInsets}:{state:PasscodeState;contentInsets:{top:number;right:number;bottom:number;left:number}}){
  // The original unframed Image uses its natural slot. A hosting controller's
  // rounded fitting size can add a physical pixel to every following element.
  const metric=useContext(PresentationContext).nativeSymbolMetrics?.passcodeLock;
  const lockMetric=metric&&Number.isFinite(metric.fontSize)&&Math.abs(metric.fontSize-44)<.001
    &&Number.isFinite(metric.width)&&metric.width>0&&Number.isFinite(metric.height)&&metric.height>0?metric:undefined;
  return <PasscodeScreen state={state} contentInsets={contentInsets}
    titleContent={<NativeTextRun testID="passcode.title" text={state.title} textStyle="title1" fontSize={28} fontWeight="bold" color={PlatformColor('label')} contentAlignment="center" multilineAlignment="leading"/>}
    subtitleContent={<NativeTextRun testID="passcode.subtitle" text={state.subtitle} textStyle="subheadline" fontSize={15} fontWeight="regular" color={colors.secondaryText} contentAlignment="center" multilineAlignment="center"/>}
    messageContent={state.message?<NativeTextRun testID="passcode.message" text={state.message} textStyle="footnote" fontSize={13} fontWeight="semibold" color={PlatformColor('systemRed')} contentAlignment="center" multilineAlignment="leading"/>:undefined}
    onRefocus={()=>{void NativeApp?.command(JSON.stringify({type:'passcode.command',id:state.id,action:'focus'})).catch(()=>{});}} glyph={<Symbol name="lock.shield.fill" size={lockMetric?.width??47} height={lockMetric?.height??154/3} pointSize={44} weight="semibold" responsive={false} tone="green"/>}
    digits={<Input ownerID={state.id} kind="digits" style={{width:114,height:18}}/>}
    input={<Input ownerID={state.id} kind="field" style={{width:1,height:1}}/>}/>;
}

/** An independent security surface must function while ordinary app read authority is withheld. */
export function PasscodeRuntime({ownerID,initialSnapshot,initialPresentation}:{ownerID:string;initialSnapshot?:string;initialPresentation?:Presentation}){
  const parse=(raw:string)=>{try{return JSON.parse(raw) as {revision?:number;passcode?:PasscodeState;presentation?:Presentation;look?:string};}catch{return {};}};
  const [snapshot,setSnapshot]=useState(()=>AppState.currentState==='active'?parse(initialSnapshot??'{}'):{});
  const latestRevision=useRef(snapshot.revision??-1);
  useEffect(()=>{
    let mounted=true,generation=0;
    const receive=(raw:string,expected=generation)=>{
      if(!mounted||expected!==generation||AppState.currentState!=='active')return;
      const next=parse(raw);if((next.revision??-1)<latestRevision.current)return;
      latestRevision.current=next.revision??latestRevision.current;setSnapshot(next);
    };
    const refresh=()=>{const expected=generation;void NativeApp?.getSnapshot().then(raw=>receive(raw,expected)).catch(()=>{});};
    const events=NativeApp?.onSnapshot(raw=>receive(raw));refresh();
    const lifecycle=AppState.addEventListener('change',state=>{++generation;if(state!=='active')setSnapshot({});else refresh();});
    return()=>{mounted=false;++generation;events?.remove();lifecycle.remove();};
  },[ownerID]);
  const [appearance]=useState(()=>new AppearanceStore(NativeAppearance));
  const settings=useSyncExternalStore(appearance.subscribe,appearance.getSnapshot);
  const systemScheme=useColorScheme();
  const dark=settings.snapshot?.preference==='dark'||settings.snapshot?.preference!=='light'&&systemScheme==='dark';
  useEffect(()=>appearance.connect(),[appearance]);
  const presentation=snapshot.presentation??initialPresentation??{locale:'en',textScales:null};
  configurePresentation(presentation);
  const state=snapshot.passcode?.id===ownerID?snapshot.passcode:undefined;
  return <PresentationContext.Provider value={presentation}><LavaAppearanceContext.Provider value={dark?'dark':'light'}><SafeAreaProvider>
    {state?<PasscodeFlowAdapter state={state} nativeHeader/>:<View style={{flex:1}}/>}
  </SafeAreaProvider></LavaAppearanceContext.Provider></PresentationContext.Provider>;
}
