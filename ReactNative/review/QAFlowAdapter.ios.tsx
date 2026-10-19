import {useEffect,useLayoutEffect,useRef,useState,useSyncExternalStore,type ReactNode} from 'react';
import {AppState,Modal,PlatformColor,StyleSheet,View} from 'react-native';
import {NavigationContainer,NavigationIndependentTree,DefaultTheme,DarkTheme,useNavigation,useNavigationContainerRef,usePreventRemove} from '@react-navigation/native';
import {createNativeStackNavigator,type NativeStackHeaderItem} from '@react-navigation/native-stack';
import {SafeAreaProvider} from 'react-native-safe-area-context';
import {QAScreen,QADetailScreen,type QAPort} from '../src/flows/qa/QAScreens';
import type {QAAction,QADetail} from '../src/flows/qa/contract';
import Configuration from '../specs/LavaQAConfigurationNativeComponent';
import {useReview} from './ReviewContext';
import {domainReviewPrivacyScope,mayInteractWithPresentation} from '../app/read-cache';
import {usePresentationAuthority,usePresentationReadiness,usePresentationNativeLayout} from '../app/use-presentation-readiness';
import {useLavaColorScheme} from '../src/appearance';
import {useTextScale} from '../app/text-metrics';
import {localized} from '../app/presentation';
import {LavaActionButton} from '../src';
import {colors} from '../src/colors';
import {Copy,Symbol} from './primitives';
import {PresentationCover} from './PresentationCover';
import {nativeInlineHeader,Search,toolbarAction,useToolbar} from './scaffold';
import {useOrdinaryPushPresentation} from './navigation-scaffold';
import {NativeFlowMetrics} from './NativeFlowMetrics.ios';
import {useNativeFlowAlert} from './NativeFlowAlert.ios';

const Stack=createNativeStackNavigator();
const noSubscribe=()=>()=>{};
function resultToolbarButton(onPress:()=>void,disabled:boolean):NativeStackHeaderItem {
  return {type:'button',label:localized('View QA result'),accessibilityLabel:localized('View QA result'),identifier:'lava.toolbar.qa.result',
    icon:{type:'sfSymbol',name:'info.circle'},tintColor:colors.navigationForeground,variant:'plain',sharesBackground:true,onPress,disabled};
}
type QABodyState={active:boolean;visible:boolean;cover:()=>ReactNode};
/** Only local native-chrome cleanup bypasses private read authority. The native
 * visit/detail owner still rejects stale callbacks; services use the usual port. */
function useQACleanupHeader(title:string,kind:'back'|'close',action:()=>void,enabled=true){
  const navigation=useNavigation();
  useLayoutEffect(()=>{
    if(!enabled)return;
    let mounted=true;
    navigation.setOptions({title,headerBackVisible:false,unstable_headerLeftItems:()=>[toolbarAction(kind==='back'?'Back':'Close',kind,()=>{if(mounted)action();})]});
    return()=>{mounted=false;navigation.setOptions({unstable_headerLeftItems:undefined});};
  },[navigation,title,kind,action,enabled]);
}
export function QAFlowAdapter({id,sheet=false}:{id:string;sheet?:boolean}){
  return <NativeFlowMetrics><QAFlowBody id={id} sheet={sheet}/></NativeFlowMetrics>;
}
function QAFlowBody({id,sheet=false}:{id:string;sheet?:boolean}){
  const {app,live}=useReview();const state=live?.qa?.id===id?live.qa:undefined;
  const retained=useRef(state);if(state)retained.current=state;
  const presentation=state??retained.current;
  const [localDetail,setLocalDetail]=useState<{sourceID:string;value:QADetail|null}>();
  const baseDetail=presentation?.detail;
  const detail=localDetail?.sourceID===baseDetail?.id?localDetail?.value:baseDetail;
  const showAlert=useNativeFlowAlert(app,{kind:'qa',id,...(detail?{detailID:detail.id}:{})});
  const detailPresentation=useRef(detail);detailPresentation.current=detail;
  const observedDetail=useRef<{visitID:string;detailID?:string}|undefined>(undefined);
  // Unrelated native snapshots deserialize a fresh detail object, and privacy
  // suspension temporarily removes state. Neither changes the native identity.
  useEffect(()=>{
    if(!state)return;
    const next={visitID:state.id,detailID:state.detail?.id};
    if(observedDetail.current?.visitID!==next.visitID||observedDetail.current?.detailID!==next.detailID)setLocalDetail(undefined);
    observedDetail.current=next;
  },[state?.id,state?.detail?.id]);
  const [foreground,setForeground]=useState(AppState.currentState==='active');
  const [entryError,setEntryError]=useState('');const entering=useRef(false);const mounted=useRef(true);
  const dark=useLavaColorScheme()==='dark';const scale=useTextScale();const footnoteScale=useTextScale('footnote');const detailScale=useTextScale('title3');
  const authority=usePresentationAuthority(app);
  const interactive=useSyncExternalStore(app?.subscribe??noSubscribe,()=>!!app&&mayInteractWithPresentation(app));
  const scope=JSON.stringify([id,live?domainReviewPrivacyScope(live):null]);
  usePresentationReadiness(app,!!app,!!state||!!entryError,scope);
  const onLayout=usePresentationNativeLayout();
  const enter=async()=>{
    if(!app||!foreground||!authority||entering.current)return;
    entering.current=true;setEntryError('');
    try{await app.command({type:'qa.command',id,action:'enter'});}
    catch(error){if(mounted.current)setEntryError((error as Error).message);}
    finally{entering.current=false;}
  };
  useEffect(()=>{
    mounted.current=true;const listener=AppState.addEventListener('change',value=>setForeground(value==='active'));
    return()=>{mounted.current=false;listener.remove();void app?.command({type:'qa.command',id,action:'leave'}).catch(()=>{});};
  },[app,id]);
  useEffect(()=>{if(!state&&!entryError)void enter();},[app,id,!!state,foreground,authority,live?.security.readRevision]);
  const portFor=(detail?:QADetail):QAPort=>({
    // Freeze the rendered detail identity. A callback from an old check never
    // obtains the new check's token by consulting a mutable current-state ref.
    send:action=>{
      const current=app?.getSnapshot?.().snapshot?.qa;
      const cleanup=action.action==='detail.close'||action.action==='detail.back';
      if(!app)return;
      if(cleanup){
        if(!detail||detailPresentation.current?.id!==detail.id)return;
        if(action.action==='detail.back'&&!detail.parent)return;
        setLocalDetail({sourceID:baseDetail?.id??detail.id,value:action.action==='detail.back'?detail.parent??null:null});
      }else if(!mayInteractWithPresentation(app)||current?.id!==id||current.detail?.id!==detail?.id)return;
      void app.command({type:'qa.command',id,...(detail?{detail:detail.id}:{}),...action}).catch(error=>{
        if(mounted.current&&(error as Error).message!=='Read access changed.'&&(error as Error).message!=='Authentication cancelled.')showAlert('Lava',(error as Error).message);
      });
    },
    configuration:<Configuration fontSize={13*footnoteScale} testID="qa-native-configuration" ownerID={id} style={{height:150}}/>,
    glyph:(name,destructive,kind)=><Symbol name={name} tone={destructive?'error':'green'} size={kind==='detail'?28:24} pointSize={kind==='detail'?20*detailScale:17*scale} weight={kind==='detail'?'semibold':'regular'} responsive={false} nativeLayout="swiftui"/>,
    fieldBackground:PlatformColor('tertiarySystemFill'),
    labelColor:PlatformColor('label'),
    searchField:props=><Search {...props} surface="localLog"/>,
    onLayout,localize:localized,textScale:scale,
  });
  const rootPort=portFor();
  // native-stack narrows this option to strings, while its screens titleColor
  // prop uses RN's native ColorValue resolver, including semantic system colors.
  const systemTitleColor=PlatformColor('label') as unknown as string;
  useToolbar({title:'Device QA',...(sheet?nativeInlineHeader:{headerTitleStyle:{color:systemTitleColor},headerLargeTitleStyle:{color:systemTitleColor}}),unstable_headerRightItems:()=>[resultToolbarButton(()=>rootPort.send({action:'result'}),!state?.hasResult)]},[sheet,!!state?.hasResult,id,scope]);
  useQACleanupHeader(localized('Device QA'),'close',()=>{if(app)void app.command({type:'qa.command',id,action:'close'}).catch(()=>{});},sheet);
  const active=!!state&&authority&&foreground&&interactive;
  const retainInactive=!foreground&&app?.getSnapshot?.().privacyCoverRequired===false;
  const visible=!!state||retainInactive;
  const cover=()=> <PresentationCover testID="qa.privacy-cover">{entryError&&entryError!=='Authentication cancelled.'?<Copy role="supporting">{entryError}</Copy>:null}<LavaActionButton title="Unlock Lava" role="secondary" onPress={()=>void enter()}/></PresentationCover>;
  return <View testID="device-qa-page" style={{flex:1}}>
    {presentation&&<View testID="qa.surface" style={{flex:1,opacity:visible?1:0}} pointerEvents={active?'auto':'none'} accessibilityElementsHidden={!active} importantForAccessibility={active?'auto':'no-hide-descendants'}>
      <QAScreen state={presentation} port={rootPort}/>
    </View>}
    {!visible&&<View style={StyleSheet.absoluteFill}>{cover()}</View>}
    <Modal visible={!!detail} presentationStyle="pageSheet" animationType="slide" onRequestClose={()=>{if(detail)portFor(detail).send({action:'detail.close'});}}>
      <SafeAreaProvider><View style={{flex:1}}><NavigationIndependentTree>{detail&&<QADetailNavigation detail={detail} portFor={portFor} dark={dark} body={{active,visible,cover}}/>}</NavigationIndependentTree></View></SafeAreaProvider>
    </Modal>
  </View>;
}
function QADetailNavigation({detail,portFor,dark,body}:{detail:QADetail;portFor:(detail:QADetail)=>QAPort;dark:boolean;body:QABodyState}){
  const navigation=useNavigationContainerRef<{QARoot:undefined;QACheck:undefined}>();
  const [ready,setReady]=useState(false);
  const push=useOrdinaryPushPresentation();
  const retainedCheck=useRef(detail.kind==='check'?detail:undefined);if(detail.kind==='check')retainedCheck.current=detail;
  const parent=detail.parent??detail;
  // The stack is retained while native state moves between suite and check. A
  // real native push/pop supplies the same transitions as the former NavigationLink.
  useEffect(()=>{
    if(!ready||!navigation.isReady())return;
    const route=navigation.getCurrentRoute()?.name;
    if(detail.canBack&&route!=='QACheck')navigation.navigate('QACheck');
    else if(!detail.canBack&&route==='QACheck'&&navigation.canGoBack())navigation.goBack();
  },[detail.id,detail.canBack,ready]);
  return <NavigationContainer ref={navigation} onReady={()=>setReady(true)} theme={dark?DarkTheme:DefaultTheme}><Stack.Navigator screenOptions={{...nativeInlineHeader,...push}} initialRouteName="QARoot">
    <Stack.Screen name="QARoot">{()=> <QADetailAdapter state={parent} port={portFor(parent)} body={body}/>}</Stack.Screen>
    <Stack.Screen name="QACheck" options={{gestureEnabled:true}}>{()=>retainedCheck.current?<QACheckAdapter state={retainedCheck.current} canReturn={!!detail.canBack} port={portFor(retainedCheck.current)} body={body}/>:<View/>}</Stack.Screen>
  </Stack.Navigator></NavigationContainer>;
}
function QACheckAdapter({state,canReturn,port,body}:{state:QADetail;canReturn:boolean;port:QAPort;body:QABodyState}){
  usePreventRemove(canReturn,()=>port.send({action:'detail.back'}));
  return <QADetailAdapter state={state} port={port} body={body}/>;
}
function QADetailAdapter({state,port,body}:{state:QADetail;port:QAPort;body:QABodyState}){
  useQACleanupHeader(state.title,state.canBack?'back':'close',()=>port.send({action:state.canBack?'detail.back':'detail.close'}));
  return <View style={{flex:1}}><View testID="qa.detail-surface" style={{flex:1,opacity:body.visible?1:0}} pointerEvents={body.active?'auto':'none'} accessibilityElementsHidden={!body.active} importantForAccessibility={body.active?'auto':'no-hide-descendants'}><QADetailScreen state={state} port={port}/></View>{!body.visible&&<View style={StyleSheet.absoluteFill}>{body.cover()}</View>}</View>;
}
