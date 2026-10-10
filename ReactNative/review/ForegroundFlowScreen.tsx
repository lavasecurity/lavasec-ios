import {useCallback,useEffect,useRef,useState,useSyncExternalStore} from 'react';
import {useRoute,type RouteProp} from '@react-navigation/native';
import {AppState,Keyboard,StyleSheet,View} from 'react-native';
import {LavaActionButton} from '../src';
import {colors} from '../src/colors';
import {foundation} from '../src/foundation';
import {Alert,Text,localized} from '../app/presentation';
import type {AppCommand,ForegroundFlow} from '../app/contract';
import {domainReviewPrivacyScope,mayInteractWithPresentation} from '../app/read-cache';
import {usePresentationAuthority,usePresentationReadiness} from '../app/use-presentation-readiness';
import {useReview} from './ReviewContext';
import type {ReviewRoutes} from './navigation';
import {Copy,Section,Symbol} from './primitives';
import {Group,ListRow,nativeInlineHeader,toolbarButton,useToolbar} from './scaffold';
import {FlowSheet,FormDivider,FormField,FormPanel,LicenseReader} from './form-scaffold';
import {AutoSwitchContent} from './HelpScreens';
import {FeedbackFlow} from './FeedbackFlow';
import {VPNEditorFlow} from './VPNEditorFlow';
import Input from '../specs/LavaTextFieldNativeComponent';
import {InputRow} from './scaffold';
import {useTextScale} from '../app/text-metrics';
import {PresentationCover} from './PresentationCover';

const titles={createFilter:'New filter',renameFilter:'Rename filter',deleteFilters:'Review',automation:'Auto-switch filters',licenses:'Full License Texts',feedback:'Feedback',vpnConfiguration:'WireGuard Configuration'};
export function ForegroundFlowScreen(){
  const {app,live}=useReview();const route=useRoute<RouteProp<ReviewRoutes,'Foreground'>>();
  const projection=live?.foregroundFlow?.id===route.params.id?live.foregroundFlow:undefined;
  const retained=useRef(projection);if(projection)retained.current=projection;
  const retainedVPN=useRef(projection?.vpnEditor??undefined);if(projection?.vpnEditor)retainedVPN.current=projection.vpnEditor;
  const retainedAuthority=useRef<string|undefined>(undefined);if(projection&&live)retainedAuthority.current=domainReviewPrivacyScope(live);
  const flow=projection??retained.current;
  const presentationAuthority=usePresentationAuthority(app);
  // Closing is a native owner acknowledgment, not a replacement read grant.
  // Keep only its already-painted, inert frame through UIKit's dismissal while
  // the same active authorization/owner remains current. Confidential Content
  // is still retired by the native editor before the sheet starts closing.
  const closing=!!live?.foregroundClosing?.includes(route.params.id)&&presentationAuthority&&AppState.currentState==='active'
    &&!!live&&retainedAuthority.current===domainReviewPrivacyScope(live);
  const scope=JSON.stringify([route.params.id,live?domainReviewPrivacyScope(live):null]);
  const [entryFailure,setEntryFailure]=useState<{scope:string;message:string}>();
  const currentScope=useRef(scope);currentScope.current=scope;
  const mounted=useRef(true);useEffect(()=>{mounted.current=true;return()=>{mounted.current=false;};},[]);
  const enteringMissingFlow=useRef(false);
  const entryPause=useRef(0);const [entrySettlement,setEntrySettlement]=useState(0);
  useEffect(()=>{const subscription=AppState.addEventListener('change',value=>{if(value!=='active')++entryPause.current;});return()=>subscription.remove();},[]);
  const failed=entryFailure?.scope===scope;
  const entryFailed=(error:unknown)=>{if(mounted.current&&currentScope.current===scope)setEntryFailure({scope,message:(error as Error).message});};
  usePresentationReadiness(app,!!app,closing||!!projection&&(projection.kind!=='vpnConfiguration'||!!projection.vpnEditor)||failed,scope);
  // The native library grant may expire before the first React projection.
  // Read-only sheets have no child reentry. Their retained shell cannot prove
  // current authorization; editable children still own their scoped admission.
  const readOnly=flow?.kind==='automation'||flow?.kind==='licenses';
  const needsMissingEntry=!projection&&!closing&&(!flow||readOnly);
  const enterMissingFlow=()=>{if(!app||!needsMissingEntry||!presentationAuthority||AppState.currentState!=='active'||enteringMissingFlow.current)return;
    const pause=entryPause.current;enteringMissingFlow.current=true;
    void app.command({type:'foreground.enter',id:route.params.id}).catch(error=>{if(pause===entryPause.current)entryFailed(error);}).finally(()=>{
      enteringMissingFlow.current=false;
      // A newer grant can arrive while the previous request still owns the
      // flight slot. Reconsider that grant once the obsolete request finishes.
      if(mounted.current&&(pause!==entryPause.current||currentScope.current!==scope))setEntrySettlement(value=>value+1);
    });};
  useEffect(()=>{if(!failed)enterMissingFlow();},[app,route.params.id,needsMissingEntry,presentationAuthority,live?.security?.readRevision,entrySettlement]);
  const vpnConcealed=flow?.kind==='vpnConfiguration'&&!projection?.vpnEditor&&!closing;
  const foregroundConcealed=!!flow&&!projection&&!closing&&['createFilter','renameFilter','deleteFilters','automation','licenses'].includes(flow.kind);
  useEffect(()=>{if(vpnConcealed||foregroundConcealed)Keyboard.dismiss();},[vpnConcealed,foregroundConcealed]);
  if(!flow)return <PresentationCover testID="foreground-flow-privacy-cover">{failed&&entryFailure.message!=='Authentication cancelled.'&&<Copy role="supporting" center>{entryFailure.message}</Copy>}<LavaActionButton title="Unlock Lava" role="secondary" onPress={()=>{setEntryFailure(undefined);enterMissingFlow();}}/></PresentationCover>;
  // Keep transient input under the native/root privacy covers. Revoked library
  // projections have no paint/input authority; UIKit dismissal may retain only
  // the already-delivered outgoing frame identified by the native owner.
  return <View style={{flex:1}}><View style={{flex:1,opacity:!vpnConcealed&&(projection||closing)?1:0}} pointerEvents={projection&&!vpnConcealed?'auto':'none'}
    accessibilityElementsHidden={!projection||vpnConcealed} importantForAccessibility={!projection||vpnConcealed?'no-hide-descendants':'auto'}>
    {flow.kind==='feedback'&&flow.feedback?<FeedbackFlow id={flow.id} state={flow.feedback} dismissAttempt={flow.dismissAttempt}/>
      :flow.kind==='vpnConfiguration'?<VPNEditorFlow id={flow.id} state={projection?.vpnEditor??{...retainedVPN.current,name:retainedVPN.current?.name??'',nameResetRevision:retainedVPN.current?.nameResetRevision??0,dirty:retainedVPN.current?.dirty??false,hasContent:retainedVPN.current?.hasContent??false,concealed:true,reading:false,canEdit:false,canSave:false,error:''}} dismissAttempt={flow.dismissAttempt} onEntryFailed={entryFailed}/>
      :<LibraryForegroundFlow flow={flow} onEntryFailed={entryFailed}/>}
  </View>{(vpnConcealed||foregroundConcealed)&&<View style={StyleSheet.absoluteFill}><PresentationCover testID={vpnConcealed?'vpn-editor-privacy-cover':'foreground-flow-privacy-cover'}>{failed&&entryFailure.message!=='Authentication cancelled.'&&<Copy role="supporting" center>{entryFailure.message}</Copy>}<LavaActionButton title="Unlock Lava" role="secondary" onPress={()=>{setEntryFailure(undefined);if(readOnly){enterMissingFlow();return;}void app?.command({type:vpnConcealed?'vpnEditor.enter':'foreground.enter',id:flow.id}).catch(entryFailed);}}/></PresentationCover></View>}</View>;
}
function LibraryForegroundFlow({flow,onEntryFailed}:{flow:ForegroundFlow;onEntryFailed?:(error:unknown)=>void}){
  const {app,live}=useReview();
  const presentationAuthority=usePresentationAuthority(app);
  const scale=useTextScale();
  // A revoked private projection does not replace this modal's local draft.
  const initial=useRef(flow);const [name,setName]=useState(initial.current?.name??'');const [emoji,setEmoji]=useState(initial.current?.emoji??'🌿');
  const [template,setTemplate]=useState<string>();const [busy,setBusy]=useState(false);const [message,setMessage]=useState('');
  const [identity,setIdentity]=useState({valid:true,dirty:false,message:''});
  const pending=useRef(false);const mounted=useRef(true);const validation=useRef(0);
  const id=flow.id;const kind=initial.current?.kind;const attempt=useRef(flow.dismissAttempt);
  const current=useRef({app,id});current.current={app,id};
  const pauseRevision=useRef(0);
  const subscribeDirtyAdmission=useCallback((listener:()=>void)=>{
    const unsubscribe=app?.subscribe?.(listener);
    const lifecycle=AppState.addEventListener('change',state=>{
      if(state!=='active')++pauseRevision.current;
      listener();
    });
    return()=>{unsubscribe?.();lifecycle.remove();};
  },[app]);
  const dirtyAdmissionKey=()=>{
    if(kind!=='renameFilter'||AppState.currentState!=='active'||!mayInteractWithPresentation(app))return null;
    const snapshot=app?.getSnapshot?.().snapshot;
    const owner=app?.getSnapshot?snapshot?.foregroundFlow:live?.foregroundFlow;
    if(owner?.id!==id||owner.kind!=='renameFilter')return null;
    const currentSnapshot=snapshot??live;
    // A hint's own ACK advances sourceRevision/readEpoch. Key only native
    // authority and resume readiness, plus pauses that React may batch away.
    return JSON.stringify([currentSnapshot?domainReviewPrivacyScope(currentSnapshot):null,
      app?.getPresentationHydration?.().epoch??0,pauseRevision.current]);
  };
  const dirtyAdmission=useSyncExternalStore(subscribeDirtyAdmission,dirtyAdmissionKey);
  const dismiss=()=>{if(!pending.current)void app?.command({type:'foreground.dismiss',id}).catch(()=>{});};
  const dirty=kind==='renameFilter'&&(name!==initial.current?.name||emoji!==initial.current?.emoji);
  const close=()=>{if(pending.current)return;if(dirty)Alert.alert('Discard changes?','',[
    {text:'Keep Editing',style:'cancel'},{text:'Discard Changes',style:'destructive',onPress:dismiss}]);else dismiss();};
  useEffect(()=>{mounted.current=true;return()=>{mounted.current=false;++validation.current;};},[]);
  useEffect(()=>{if(app&&presentationAuthority&&['createFilter','renameFilter','deleteFilters'].includes(flow.kind)&&AppState.currentState==='active')void app.command({type:'foreground.enter',id}).catch(error=>onEntryFailed?.(error));},[app,id,live?.security.readRevision,presentationAuthority]);
  useEffect(()=>{
    const readEpoch=app?.getReadEpoch?.();
    if(!app||!mounted.current||current.current.app!==app||current.current.id!==id||dirtyAdmission===null
      ||dirtyAdmissionKey()!==dirtyAdmission||app.getReadEpoch?.()!==readEpoch)return;
    void app.command({type:'foreground.dirty',id,dirty}).catch(()=>{});
  },[app,id,dirty,dirtyAdmission]);
  useEffect(()=>{if(flow&&attempt.current!==flow.dismissAttempt){attempt.current=flow.dismissAttempt;close();}},[flow?.dismissAttempt]);
  useEffect(()=>{
    if(!app||kind!=='renameFilter')return;const request=++validation.current;
    void app.command<typeof identity>({type:'foreground.identity',id,name,emoji}).then(result=>{if(mounted.current&&request===validation.current)setIdentity(result);}).catch(()=>{});
  },[app,id,kind,name,emoji]);
  const submit=async()=>{
    if(!app||pending.current||!flow||!mayInteractWithPresentation(app))return;pending.current=true;setBusy(true);setMessage('');
    try{await app.command({type:'foreground.submit',id,...(kind==='createFilter'?{template}:kind==='renameFilter'?{name,emoji}:{})});}
    catch(error){if(mounted.current&&(error as Error).message!=='Authentication cancelled.')setMessage((error as Error).message);}
    finally{pending.current=false;if(mounted.current)setBusy(false);}
  };
  useToolbar({...nativeInlineHeader,title:kind?titles[kind]:'',headerBackVisible:false,
    unstable_headerLeftItems:()=>[toolbarButton(kind==='renameFilter'||kind==='deleteFilters'?'Cancel':'Close','xmark',close,busy)],
    unstable_headerRightItems:()=>kind==='renameFilter'?[toolbarButton('Save','checkmark',()=>void submit(),busy||!identity.valid)]:[]},[kind,busy,identity.valid,dirty,name,emoji,template]);
  if(kind==='licenses')return <LicenseReader text={flow.notices??''}/>;
  return <FlowSheet footer={kind==='createFilter'?<LavaActionButton title="Create" disabled={busy||!flow.canCreate} onPress={()=>void submit()}/>
    :kind==='deleteFilters'?<LavaActionButton title="Confirm changes" disabled={busy||!!message} onPress={()=>void submit()}/>:undefined}>
    {kind==='createFilter'&&<Section title="Start from"><View style={{gap:foundation.space.md}}>
      <Group><ListRow title="Create new" selected={!template} onPress={()=>setTemplate(undefined)} disabled={busy}/></Group>
      <Group>{flow.templates.map(row=><ListRow key={row.id} title={row.name} verbatimTitle selected={template===row.id} onPress={()=>setTemplate(row.id)} disabled={busy}/>)}</Group>
    </View></Section>}
    {kind==='renameFilter'&&<><FormPanel>
      <View testID="filter.identity.emoji.row" pointerEvents={busy?'none':'auto'}><InputRow title="Emoji" labelTestID="filter.identity.emoji.label"><Input kind="emoji" ownerID={id} value={emoji} inputLabel={localized('Emoji')} placeholder="" resetRevision={0} fontPointSize={22*scale} style={{height:44}} onChange={event=>setEmoji(event.nativeEvent.text)}/></InputRow></View>
      <FormDivider/><View testID="filter.identity.name.row"><FormField title="Name" labelTestID="filter.identity.name.label" placeholder="Filter name" value={name} onChangeText={setName} minHeight={44} editable={!busy} autoCapitalize="words" returnKeyType="done" onSubmitEditing={()=>void submit()}/></View>
    </FormPanel>{!!identity.message&&<Copy role="supporting" color={colors.errorText}>{identity.message}</Copy>}</>}
    {kind==='deleteFilters'&&<>{flow.groups?.map((group,index)=><Section key={index} title={group.title}><Group>
      {[...group.added.map(title=>({title,added:true})),...group.removed.map(title=>({title,added:false}))].map((row,ordinal)=><View key={ordinal} accessible accessibilityLabel={localized(row.added?'Added':'Removed')} accessibilityValue={{text:row.title}}>
        <ListRow verbatimTitle title={row.title} leading={<Symbol name={row.added?'plus':'minus'} tone={row.added?'green':'error'}/>}/>
      </View>)}
    </Group></Section>)}{flow.hasDeletions&&<Copy role="supporting">Deleting removes these filters and their custom changes. Restoring defaults recreates the original filters.</Copy>}</>}
    {kind==='automation'&&<AutoSwitchContent/>}
    {!!message&&<Copy role="supporting" color={colors.errorText}>{message}</Copy>}
  </FlowSheet>;
}
