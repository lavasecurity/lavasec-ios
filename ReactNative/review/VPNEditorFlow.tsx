import {useEffect,useRef,useState,useSyncExternalStore,type ComponentRef} from 'react';
import {AppState,View} from 'react-native';
import {LavaActionButton} from '../src';
import {localized,Alert} from '../app/presentation';
import {useTextScale} from '../app/text-metrics';
import {domainReviewPrivacyScope,mayInteractWithPresentation} from '../app/read-cache';
import {usePresentationAuthority} from '../app/use-presentation-readiness';
import type {VPNEditorState} from '../app/contract';
import Input from '../specs/LavaTextFieldNativeComponent';
import {useReview} from './ReviewContext';
import {FlowSheet,FormPanel,FormField,FormDivider,FormActions,useSheetEditorViewport} from './form-scaffold';
import {Info,InputRow,Quiet,toolbarButton,useToolbar} from './scaffold';

const noSubscribe=()=>()=>{};

export function VPNEditorFlow({id,state,dismissAttempt,onEntryFailed}:{id:string;state:VPNEditorState;dismissAttempt:number;onEntryFailed?:(error:unknown)=>void}){
  const {app,live}=useReview();const [name,setName]=useState(state.name);const [saving,setSaving]=useState(false);
  const [nameResetRevision,setNameResetRevision]=useState(state.nameResetRevision);const reset=useRef(state.nameResetRevision);
  const presentationAuthority=usePresentationAuthority(app);
  const currentOwnerMayEdit=()=>{
    if(!mayInteractWithPresentation(app))return false;
    if(!app?.getSnapshot)return true;
    const flow=app.getSnapshot().snapshot?.foregroundFlow;
    return flow?.id===id&&flow.kind==='vpnConfiguration'&&flow.vpnEditor?.canEdit===true;
  };
  const nameAuthority=useSyncExternalStore(app?.subscribe??noSubscribe,currentOwnerMayEdit);
  const nameReadEpoch=app?.getReadEpoch?.();
  const authorizing=useRef(false);
  const pauseRevision=useRef(0);
  const pending=useRef(false);const mounted=useRef(true);const attempt=useRef(dismissAttempt);const scale=useTextScale();
  const dismissRequest=useRef(0);const discardPrompt=useRef<number|null>(null);const promptRevision=useRef(0);
  const current=useRef({id,state,saving,app});current.current={id,state,saving,app};
  useEffect(()=>{if(state.nameResetRevision!==reset.current){reset.current=state.nameResetRevision;setName(state.name);setNameResetRevision(state.nameResetRevision);}},[state.name,state.nameResetRevision]);
  const changeName=(value:string)=>{
    // A retained frame carries an old canEdit projection. Check current owner
    // authority before either the local buffer or the native command changes.
    if(!mounted.current||current.current.id!==id||!current.current.state.canEdit||pending.current||current.current.saving
      ||app?.getReadEpoch?.()!==nameReadEpoch||!currentOwnerMayEdit())return;
    setName(value);void app?.command({type:'vpnEditor.name',id,name:value}).catch(report);
  };
  const report=(error:unknown)=>{if(mounted.current&&mayInteractWithPresentation(app))Alert.alert('Lava',(error as Error).message);};
  const currentVisit=()=>mounted.current&&current.current.id===id&&current.current.app===app;
  const mayConfirmDiscard=()=>{
    if(!currentVisit()||!mayInteractWithPresentation(app))return false;
    if(!app?.getSnapshot)return true;
    const flow=app.getSnapshot().snapshot?.foregroundFlow;
    return flow?.id===id&&flow.kind==='vpnConfiguration'&&flow.vpnEditor!=null;
  };
  const discardConsent=()=>{
    if(!mayConfirmDiscard())return null;
    const snapshot=app?.getSnapshot?.().snapshot;
    // Mutation ACKs advance sourceRevision/readEpoch, without changing consent.
    // Native authority, hydration and even a batched lifecycle pause still fence it.
    return JSON.stringify([snapshot?domainReviewPrivacyScope(snapshot):null,
      app?.getPresentationHydration?.().epoch??0,pauseRevision.current]);
  };
  const dismiss=async(discardConfirmed=false)=>{
    const consent=discardConsent();
    if(!app||pending.current||discardPrompt.current||consent===null)return;
    const request=++dismissRequest.current;pending.current=true;let needsConfirmation=false;
    try{
      // The native-only Content buffer may be newer than state.dirty. A clean
      // Close is a native probe; false preserves the owner and requests Discard.
      const result=await app.command<boolean|null>({type:'foreground.dismiss',id,...(discardConfirmed?{discardConfirmed:true}:{})});
      needsConfirmation=result===false&&!discardConfirmed;
    }catch(error){if(request===dismissRequest.current&&discardConsent()===consent)report(error);}
    finally{if(request===dismissRequest.current)pending.current=false;}
    if(needsConfirmation&&request===dismissRequest.current&&discardConsent()===consent)confirmDiscard();
  };
  const confirmDiscard=()=>{
    const consent=discardConsent();if(pending.current||discardPrompt.current||consent===null)return;
    const prompt=++promptRevision.current;discardPrompt.current=prompt;
    const clearPrompt=()=>{if(discardPrompt.current===prompt)discardPrompt.current=null;};
    Alert.alert('Discard changes?','Your saved VPN settings will stay active.',[
      {text:'Cancel',style:'cancel',onPress:clearPrompt},
      {text:'Discard',style:'destructive',onPress:()=>{
        if(discardPrompt.current!==prompt)return;
        clearPrompt();if(discardConsent()===consent)void dismiss(true);
      }}],{onDismiss:clearPrompt});
  };
  const close=()=>{if(pending.current||discardPrompt.current||!mayConfirmDiscard())return;
    if(state.dirty||name!==state.name)confirmDiscard();else void dismiss();};
  useEffect(()=>{mounted.current=true;return()=>{mounted.current=false;++dismissRequest.current;discardPrompt.current=null;};},[]);
  useEffect(()=>{const authorize=()=>{if(!app||!presentationAuthority||AppState.currentState!=='active'||authorizing.current)return;
    authorizing.current=true;void app.command({type:'vpnEditor.enter',id}).catch(error=>{onEntryFailed?.(error);report(error);}).finally(()=>{authorizing.current=false;});};
    authorize();const lifecycle=AppState.addEventListener('change',value=>{
      if(value!=='active')++pauseRevision.current;else authorize();
    });return()=>lifecycle.remove();
  },[app,id,live?.security.readRevision,presentationAuthority]);
  useEffect(()=>{if(attempt.current!==dismissAttempt){attempt.current=dismissAttempt;close();}},[dismissAttempt]);
  useToolbar({title:'WireGuard Configuration',headerBackVisible:false,unstable_headerLeftItems:()=>[toolbarButton('Cancel','xmark',close,saving)],unstable_headerRightItems:()=>[]},[saving,state.dirty,name]);
  const save=async()=>{if(!app||pending.current||!state.canSave||!currentOwnerMayEdit())return;pending.current=true;setSaving(true);
    try{await app.command({type:'vpnEditor.name',id,name});await app.command({type:'vpnEditor.save',id});}
    catch(error){report(error);}finally{pending.current=false;if(mounted.current)setSaving(false);}
  };
  const saveTitle=saving?'Saving…':'Save';
  return <FlowSheet nativeKeyboardAvoidance footer={<FormActions titles={['Choose File',saveTitle]} children={[
    <LavaActionButton title="Choose File" role="secondary" disabled={!state.canEdit||saving} onPress={()=>{if(currentOwnerMayEdit())void app?.command({type:'vpnEditor.file',id}).catch(report);}}/>,
    <LavaActionButton title={saveTitle} disabled={!state.canSave||saving} onPress={()=>void save()}/>]}/> }>
    <FormPanel><FormField title="Name" placeholder="Configuration name" value={name} resetRevision={nameResetRevision} onChangeText={changeName} editable={nameAuthority&&state.canEdit&&!saving} nativeKind="wireGuardName" ownerID={id}/>
      <FormDivider/><ConfigurationInput id={id} scale={scale}/>
    </FormPanel><Quiet>After saving, your private key stays in this device's Keychain and isn't shown again.</Quiet>
    {!!state.error&&<Info title="Can't save this configuration" description={state.error} icon="exclamationmark.triangle"/>}
  </FlowSheet>;
}

function ConfigurationInput({id,scale}:{id:string;scale:number}){
  const input=useRef<ComponentRef<typeof Input>>(null);const [focused,setFocused]=useState(false);
  const height=useSheetEditorViewport(input,focused,184);
  return <InputRow title="Content"><Input ref={input} kind="wireGuard" ownerID={id} inputLabel={localized('Content')}
    placeholder={localized('Paste a WireGuard .conf, or use Choose File.')} resetRevision={0} fontPointSize={17*scale}
    onFocusChange={event=>setFocused(event.nativeEvent.focused)} style={{height}}/></InputRow>;
}
