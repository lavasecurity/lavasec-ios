import {useEffect,useLayoutEffect,useRef,useState,useSyncExternalStore} from 'react';
import {PlatformColor,View} from 'react-native';
import {useNavigation} from '@react-navigation/native';
import {mayInteractWithPresentation} from '../app/read-cache';
import Credentials from '../specs/LavaBackupCredentialsNativeComponent';
import {AccountBackupFlow} from '../src/flows/account-backup/AccountBackupFlow';
import type {AccountBackupCommand,AccountBackupFlowState} from '../src/flows/account-backup/types';
import {useReview} from './ReviewContext';
import {nativeInlineHeader,toolbarAction,useToolbar} from './scaffold';
import {NativeFlowMetrics} from './NativeFlowMetrics.ios';
import {useNativeFlowAlert} from './NativeFlowAlert.ios';

const noSubscribe=()=>()=>{};

/** iOS auth/credential/navigation binding; the flow module depends on typed ports. */
export function AccountBackupFlowAdapter({id,state}:{id:string;state:AccountBackupFlowState}){
  return <NativeFlowMetrics><AccountBackupFlowBody id={id} state={state}/></NativeFlowMetrics>;
}
function AccountBackupFlowBody({id,state}:{id:string;state:AccountBackupFlowState}){
  const {app,live}=useReview();const navigation=useNavigation();const mounted=useRef(true);const pending=useRef(false);
  const showAlert=useNativeFlowAlert(app,{kind:'foreground',id});
  const current=useRef({id,app});current.current={id,app};
  const [height,setHeight]=useState(state.kind==='backupSetup'?196:370);
  useEffect(()=>{mounted.current=true;return()=>{mounted.current=false;};},[]);
  const scopedState=()=>{
    if(!mayInteractWithPresentation(app))return undefined;
    // App-unlock admission can outlive this app-settings projection. Never let
    // retained props or context replace a missing native scoped read.
    const snapshot=app?.getSnapshot?app.getSnapshot().snapshot:live;
    const flow=snapshot?.foregroundFlow;
    return flow?.id===id&&flow.kind===state.kind&&flow.accountBackup?.kind===state.kind?flow.accountBackup:undefined;
  };
  const blocksClose=()=>{const scoped=scopedState();return !!scoped&&(scoped.busy||!scoped.canClose);};
  // A concealed projection can retain busy after native work has finished.
  // Only native admission may decide whether that retained visit can retire.
  const canClose=!useSyncExternalStore(app?.subscribe??noSubscribe,blocksClose);
  const close=async()=>{
    if(!app||!mounted.current||current.current.id!==id||current.current.app!==app||blocksClose())return;
    // The existing cleanup command cannot authorize reads or invoke services;
    // native admission still owns exact visit/account identity and busy guards.
    try{await app.command({type:'foreground.dismiss',id});}catch{}
  };
  const run=async(command:AccountBackupCommand)=>{
    if(command.action==='close'){await close();return;}
    if(!app||pending.current||!scopedState())return;
    const visit=id,epoch=app.getReadEpoch?.();pending.current=true;
    try{await app.command({type:'accountBackup.command',id,command});}
    catch(error){if(mounted.current&&current.current.id===visit&&mayInteractWithPresentation(app)&&app.getReadEpoch?.()===epoch&&(error as Error).message!=='Authentication cancelled.')showAlert('Lava',(error as Error).message);}
    finally{pending.current=false;}
  };
  useToolbar({...nativeInlineHeader,headerShown:!state.success,title:state.title,headerBackVisible:false,
    ...(state.kind==='account'?{unstable_headerRightItems:()=>[]}:
      {unstable_headerLeftItems:()=>state.canBack?[toolbarAction('Back','back',()=>void run({action:'back'}),state.busy)]:[]}),
  },[id,state.title,state.success,state.kind,state.busy,state.canBack,state.canClose]);
  // Like QA cleanup chrome, Close stays available above the concealed body.
  // The ordinary toolbar continues to guard Back and every protected action.
  useLayoutEffect(()=>{
    let active=true;
    const side=state.kind==='account'?'unstable_headerLeftItems':'unstable_headerRightItems';
    navigation.setOptions({[side]:()=>[toolbarAction('Close','close',()=>{if(active)void close();},!canClose)]});
    return()=>{active=false;navigation.setOptions({[side]:undefined});};
  },[navigation,app,id,state.kind,state.busy,state.canClose,canClose]);
  const confirmDeletion=()=>{
    if(!scopedState())return;
    const epoch=app?.getReadEpoch?.();
    showAlert('Delete your Lava account?',"This deletes the signed-in Lava account and its encrypted backup from Lava's servers. Local protection settings stay on this device.",[
      {text:'Cancel',style:'cancel'},
      {text:'Delete',style:'destructive',onPress:()=>{if(current.current.id===id&&mayInteractWithPresentation(app)&&app?.getReadEpoch?.()===epoch)void run({action:'account.delete'});}},
    ],{tint:'confirmation'});
  };
  const credentials=<View style={{height}}><Credentials ownerID={id} mode={state.kind==='backupSetup'?'display':'entry'} style={{flex:1}}
    onSizeChange={event=>{const next=event.nativeEvent.height;if(next>0&&mounted.current)setHeight(old=>Math.abs(old-next)>.5?next:old);}}/></View>;
  return <AccountBackupFlow state={state} command={run} credentials={credentials} confirmAccountDeletion={confirmDeletion} labelColor={PlatformColor('label')} secondaryColor={PlatformColor('secondaryLabel')} labelSymbolTone="label"/>;
}
