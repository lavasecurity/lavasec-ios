import {useCallback,useEffect,useRef,useState,useSyncExternalStore} from 'react';
import {AppState,PlatformColor} from 'react-native';
import {mayInteractWithPresentation} from '../app/read-cache';
import {ImportFlow} from '../src/flows/import/ImportFlow';
import {importTitles,type ImportAction,type ImportState} from '../src/flows/import/contract';
import Scanner from '../specs/LavaImportScannerNativeComponent';
import {useReview} from './ReviewContext';
import {nativeInlineHeader,toolbarAction,useToolbar} from './scaffold';
import {NativeFlowMetrics} from './NativeFlowMetrics.ios';
import {useNativeFlowAlert} from './NativeFlowAlert.ios';
const noSubscribe=()=>()=>{};

/** iOS owns app authorization, system alerts, navigation chrome and camera. */
export function ImportFlowAdapter({id,state}:{id:string;state:ImportState}){
  return <NativeFlowMetrics><ImportFlowBody id={id} state={state}/></NativeFlowMetrics>;
}
function ImportFlowBody({id,state}:{id:string;state:ImportState}){
  const {app}=useReview();
  const showAlert=useNativeFlowAlert(app,{kind:'foreground',id,stageID:state.stageID});
  const alert=useRef('');
  const attempts=useRef({scope:'',count:0});
  const [alertRetry,setAlertRetry]=useState(0);
  const alertEpoch=useSyncExternalStore(app?.subscribe??noSubscribe,()=>app?.getReadEpoch?.()??0);
  const command=async(action:ImportAction)=>{
    if(!app||AppState.currentState!=='active'||!mayInteractWithPresentation(app))return;
    try{return await app.command({...action,id,stageID:state.stageID});}
    catch(error){if(action.type!=='import.code'&&mayInteractWithPresentation(app))showAlert('Lava',(error as Error).message);}
  };
  const measure=useCallback((height:number)=>{
    if(!app||AppState.currentState!=='active'||!Number.isFinite(height)||height<=0)return;
    // An outgoing stage keeps its own callback and cannot resize its successor.
    void app.command({type:'foreground.layout',id,stageID:state.stageID,height:Math.min(height,100_000)}).catch(()=>{});
  },[app,id,state.stageID]);
  const closes=state.closeAtRoot??state.stage==='chooseMethod';
  useToolbar({...nativeInlineHeader,title:importTitles[state.stage],headerShown:state.stage!=='applying',headerBackVisible:false,gestureEnabled:state.canDismiss,
    unstable_headerLeftItems:()=>state.stage==='completed'?[]:[toolbarAction(closes?'Close':'Back',closes?'close':'back',()=>void command({type:closes?'import.dismiss':'import.back'}),!state.canDismiss)],
    unstable_headerRightItems:()=>[]},[state.stage,state.stageID,state.canDismiss,closes]);
  useEffect(()=>{
    if(!mayInteractWithPresentation(app))return;
    const active=state.activeReplacement;
    const token=active?.id??(state.alert?state.alertID:'');
    if(!token||alert.current===token)return;
    const scope=`${token}:${alertEpoch}`;
    if(attempts.current.scope!==scope)attempts.current={scope,count:0};
    if(attempts.current.count>=3)return;
    ++attempts.current.count;alert.current=token;
    let mounted=true;let retry:ReturnType<typeof setTimeout>|undefined;
    const onRetire=()=>{
      if(alert.current===token)alert.current='';
      if(mounted&&mayInteractWithPresentation(app)&&attempts.current.count<3)retry=setTimeout(()=>setAlertRetry(value=>value+1),250);
    };
    const started=active?showAlert('Replace the filter in effect?',active.message,[{text:'Cancel',style:'cancel',onPress:()=>void command({type:'import.clearAlert'})},
      {text:'Replace active filter',style:'destructive',onPress:()=>void command({type:'import.confirmActive',confirmation:active.id})}],{tint:'confirmation',verbatimMessage:true,onRetire})
      :state.alert?showAlert(state.alert.title,state.alert.message,[{text:'OK',style:'cancel',onPress:()=>void command({type:'import.clearAlert'})}],{tint:state.alert.tint??'app',verbatimTitle:true,verbatimMessage:true,onRetire}):false;
    if(!started)onRetire();
    return()=>{mounted=false;if(retry!==undefined)clearTimeout(retry);};
  },[app,state.stageID,state.activeReplacement?.id,state.alertID,state.alert?.title,state.alert?.message,state.alert?.tint,alertEpoch,alertRetry]);
  return <ImportFlow state={state} labelColor={PlatformColor('label')} port={{command,measure,scanner:<Scanner key={state.stageID} ownerID={id} style={{flex:1}}/>}}/>;
}
