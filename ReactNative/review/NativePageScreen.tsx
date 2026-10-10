import {usePresentationNativeLayout} from '../app/use-presentation-readiness';
import {usePlusEntry} from './plus-entry';
import {useEffect,useRef,useState} from 'react';
import {View} from 'react-native';
import {Alert} from '../app/presentation';
import type {VPNDraft} from '../app/contract';
import {LavaActionButton,LavaIconButton,LavaToggleControl} from '../src';
import {Screen,Section,Symbol} from './primitives';
import {AccessorySlot,Group,ListRow,Quiet,QuietFooter,Toggle} from './scaffold';
import {OrderedListAction,SettingsIntro,useSettingsEditToolbar} from './settings-scaffold';
import {nativeInlineHeader,toolbarButton,useToolbar} from './scaffold';
import {useDiscoveryVisit} from './discovery';
import {useIsFocused,useNavigation,useRoute,type RouteProp} from '@react-navigation/native';
import NativePage from '../specs/LavaNativePageNativeComponent';
import {useReview,useRouteBodyConcealed} from './ReviewContext';
import {useReviewNavigation,type ReviewRoutes} from './navigation';
import {FeedbackScreen} from './FeedbackScreen';
import {AutoSwitchPage} from './HelpScreens';
import {useVPNPageAdmission} from './vpn-page-admission';
import {PresentationCover} from './PresentationCover';

let vpnVisitSerial=0;
export function VPNChainingScreen() {
  const upgrade=usePlusEntry();
  const {app,live}=useReview();const route=useRoute<RouteProp<ReviewRoutes,'VPNChaining'>>();
  const nav=useReviewNavigation(route.params);
  const admission=useVPNPageAdmission();
  // Only profiles belong to the editor. Ordinary settings switches use their own
  // immediate command path, just like the other Settings pages.
  const [{draft,busy},setMode]=useState<{draft?:VPNDraft;busy:boolean}>({busy:false});
  const draftRef=useRef<VPNDraft|undefined>(undefined);const pending=useRef(false);
  const opening=useRef<Promise<string>|undefined>(undefined);const mounted=useRef(true);
  const togglePending=useRef(false);
  const vpn=live?.vpn;const editing=!!draft;
  useEffect(()=>{mounted.current=true;return()=>{mounted.current=false;const id=draftRef.current?.id;draftRef.current=undefined;
    if(id)void app?.command({type:'vpn.cancel',id}).catch(()=>{});};},[app]);
  const nativeDraft=draft&&vpn?.draft?.id===draft.id&&vpn.draft.revision>=draft.revision?vpn.draft:draft;
  const latestDraft=useRef(nativeDraft);latestDraft.current=nativeDraft;
  const rows=nativeDraft?.rows??vpn?.rows??[];
  const needsPlus=live?.plus?.enabled===false||!!vpn?.needsPlus;
  // Renewal must not revive a begin request that crossed an entitlement loss.
  const access=useRef({needsPlus,epoch:0});
  if(access.current.needsPlus!==needsPlus)access.current={needsPlus,epoch:access.current.epoch+1};
  // Keep the prerequisite visible, but don't disclose paid setup until Plus is
  // confirmed. A saved ON preference can survive an expired subscription.
  const setup=!!vpn?.setup&&!needsPlus;
  useEffect(()=>{
    const id=draftRef.current?.id;if(!needsPlus||!id)return;
    draftRef.current=undefined;setMode({busy:false});
    void app?.command({type:'vpn.cancel',id}).catch(()=>{});
  },[app,needsPlus]);
  const enabled=!!vpn?.enabled;
  // Fallback and enablement always describe SAVED profiles, never uncommitted rows.
  const canChangeFallback=!!vpn?.canChangeFallback;
  const locked=busy||!!vpn?.busy;
  const report=(error:unknown)=>{if((error as Error).message!=='Authentication cancelled.')Alert.alert('Lava',(error as Error).message);};
  const stage=(value:VPNDraft,begin=false)=>{
    if(!mounted.current||access.current.needsPlus||!begin&&draftRef.current?.id!==value.id)return;
    draftRef.current=value;setMode(mode=>({...mode,draft:value}));
  };
  const ensureDraft=():Promise<string>=>{
    if(access.current.needsPlus)return Promise.reject(new Error('Authentication cancelled.'));
    if(opening.current)return opening.current;
    if(draftRef.current)return Promise.resolve(draftRef.current.id);
    if(!app)return Promise.reject(new Error("VPN chaining isn't available. Review its settings."));
    const id=`vpn-${Date.now()}-${++vpnVisitSerial}`;
    const epoch=access.current.epoch;
    const request=app.command<VPNDraft>({type:'vpn.begin',id,generation:vpn?.generation??''}).then(value=>{
      if(!mounted.current||access.current.needsPlus||access.current.epoch!==epoch){void app.command({type:'vpn.cancel',id}).catch(()=>{});throw new Error('Authentication cancelled.');}
      stage(value,true);return id;
    }).finally(()=>{if(opening.current===request)opening.current=undefined;});
    opening.current=request;return request;
  };
  // Presenting a sheet must not dim/rebuild the page's toolbar or row panel.
  const run=async(action:(id:string)=>Promise<void>)=>{if(!admission.isAdmitted()||!app||pending.current||access.current.needsPlus)return;pending.current=true;
    try{await action(await ensureDraft());}catch(error){report(error);}finally{pending.current=false;}};
  const toggle=async(key:'setup'|'enabled'|'fallback',value:boolean)=>{
    if(!admission.isAdmitted()||!app||togglePending.current||busy)return;
    if(key==='setup'&&value&&needsPlus){
      upgrade('vpn',async()=>{await app.command({type:'vpn.toggle',key:'setup',value:true});});
      return;
    }
    togglePending.current=true;
    try{await app.command({type:'vpn.toggle',key,value});}catch(error){report(error);}
    finally{togglePending.current=false;}
  };
  const toggleRow=async(index:number,value:boolean)=>{
    if(!admission.isAdmitted()||!app||editing||togglePending.current||busy)return;
    togglePending.current=true;
    try{await app.command({type:'vpn.rowToggle',generation:vpn?.generation??'',index,value});}catch(error){report(error);}
    finally{togglePending.current=false;}
  };
  const open=(index:number)=>{if(!admission.isAdmitted())return;if(vpn?.needsPlus){upgrade('vpn',async()=>{await app!.command({type:'vpn.edit',id:await ensureDraft(),index});});return;}void run(async id=>{await app!.command({type:'vpn.edit',id,index});});};
  const remove=(index:number)=>{if(!admission.isAdmitted())return;if(vpn?.needsPlus){upgrade('vpn');return;}void run(async id=>stage(await app!.command<VPNDraft>({type:'vpn.remove',id,index})));};
  const swap=()=>{if(!admission.isAdmitted())return;if(vpn?.needsPlus){upgrade('vpn');return;}void run(async id=>stage(await app!.command<VPNDraft>({type:'vpn.swap',id})));};
  const reset=()=>void run(async id=>stage(await app!.command<VPNDraft>({type:'vpn.reset',id})));
  const discard=()=>{if(!admission.isAdmitted()||pending.current)return;const id=draftRef.current?.id;draftRef.current=undefined;setMode({busy:false});
    if(id)void app?.command({type:'vpn.cancel',id}).catch(report);};
  const cancel=()=>{if(!admission.isAdmitted())return;if(nativeDraft?.changed)Alert.alert('Discard changes?','Your saved VPN settings will stay active.',[
    {text:'Cancel',style:'cancel'},{text:'Discard',style:'destructive',onPress:discard}]);else discard();};
  const commit=async()=>{
    if(!admission.isAdmitted()||!app||access.current.needsPlus||pending.current||togglePending.current||!draftRef.current)return;
    // Visiting edit mode alone is not a settings mutation or a saving animation.
    if(!latestDraft.current?.changed){discard();return;}
    // The native sheet can advance the draft without calling stage(). Freeze that
    // newest metadata through commit: native clears its draft before the command
    // Promise resolves, so falling back to the original page draft drops new rows.
    const committing=latestDraft.current!;draftRef.current=committing;
    pending.current=true;setMode({draft:committing,busy:true});
    try{await app.command({type:'vpn.commit',id:draftRef.current.id});draftRef.current=undefined;setMode({busy:false});}
    catch(error){report(error);setMode(mode=>({...mode,busy:false}));}finally{pending.current=false;}
  };
  // An accepted all-off parent keeps its bar's paint below the native modal;
  // every callback still requires its own current interactive admission.
  useSettingsEditToolbar({editing,busy:locked||admission.coverRequired,canEdit:setup&&!admission.coverRequired,onEdit:()=>{if(admission.isAdmitted())void ensureDraft().catch(report);},onCancel:cancel,onSave:()=>void commit()});
  const openDNS=()=>{if(!admission.isAdmitted())return;const state=nav.getState();const previous=state.routes[state.index-1];
    if(route.params?.returnTo==='DNS'&&previous?.name==='DNS'&&previous.key===route.params.returnKey)nav.goBack();else nav.navigate('DNS');};
  if(!app)return null;
  return <View style={{flex:1}}><View testID="vpn-page-content" style={{flex:1}} pointerEvents={admission.canInteract?'auto':'none'} accessibilityElementsHidden={!admission.canInteract} importantForAccessibility={admission.canInteract?'auto':'no-hide-descendants'}><Screen><SettingsIntro summary="Lava filters first, then sends allowed DNS requests through your WireGuard VPN."/>
    <Section title="Prerequisite" footer="Get a WireGuard config from your VPN provider."><Group>
      <Toggle testID="vpn.setup-toggle" title="I have a WireGuard configuration" value={setup} disabled={locked} onChange={value=>toggle('setup',value)}/>
    </Group></Section>
    {setup&&<>
      <Section title="WireGuard Configuration"><Group testID="vpn.configuration-panel" footer={editing&&(vpn?.canEdit||vpn?.needsPlus)&&!vpn?.unavailable&&!vpn?.needsRepair?<OrderedListAction count={rows.length} addTitle="Add configuration" disabled={locked} onAdd={()=>open(rows.length)} onSwap={swap}/>:undefined}>
        {rows.length?rows.map((row,index)=><ListRow key={index} testID={index===0?"vpn.configuration-row":"vpn.configuration-row.2"} verbatimTitle separateTrailing title={row.name} metadata={row.mode}
          leading={<Symbol name={`${index+1}.circle`} tone="primary"/>} disabled={locked||!vpn?.canEdit&&!vpn?.needsPlus} onPress={editing?()=>open(index):vpn?.needsPlus?()=>upgrade('vpn'):undefined}
          trailing={<AccessorySlot switchable>{editing?<LavaIconButton title="Remove" item={row.name} icon="remove" role="destructive" disabled={locked} onPress={()=>remove(index)}/>
            :<LavaToggleControl verbatimTitle title={row.name} testID={`vpn.row-toggle.${index}`} value={enabled&&row.isEnabled!==false} disabled={locked||!vpn?.canEdit&&!vpn?.needsPlus} onValueChange={value=>{if(vpn?.needsPlus)upgrade('vpn');else void toggleRow(index,value);}}/>}</AccessorySlot>}/>)
          :<ListRow title={vpn?.unavailable?'Saved configuration unavailable':'No configurations'} leading={<Symbol name="doc.text" tone="primary"/>}/>}
      </Group>
        {editing&&vpn?.needsRepair&&<QuietFooter note="" title="Delete configuration" onPress={reset}/>}
      </Section>
      <Quiet>The order determines which VPN your traffic uses and when it uses both.</Quiet>
      {!!vpn?.restriction&&!(rows.length&&nativeDraft?.changed)&&<Quiet>{vpn.restriction}</Quiet>}
      {vpn?.needsPlus&&<QuietFooter note="" title="See Lava Security Plus" onPress={()=>{if(admission.isAdmitted())upgrade('vpn');}}/>}
      {!!vpn?.rotationNote&&<Quiet>{vpn.rotationNote}</Quiet>}
      {!!vpn?.error&&<Quiet>{vpn.error}</Quiet>}
      <Section title="DNS fallback"><Group>
        <Toggle testID="vpn.fallback-toggle" title="Use Lava DNS settings as fallback" value={canChangeFallback&&!!vpn?.fallback} disabled={locked||!canChangeFallback} onChange={value=>toggle('fallback',value)}/>
      </Group>
        {canChangeFallback?<QuietFooter note="Split-tunnel VPNs only. These lookups leave the VPN tunnel and go to your selected DNS providers." title="Review DNS settings" onPress={openDNS}/>
          :<Quiet>DNS fallback is unavailable with an active full-tunnel VPN.</Quiet>}
      </Section>
    </>}
  </Screen></View>{admission.coverRequired&&<View style={{position:'absolute',top:0,bottom:0,left:0,right:0}} accessibilityElementsHidden={admission.coverAccessibilityHidden} importantForAccessibility={admission.coverAccessibilityHidden?'no-hide-descendants':'auto'}><PresentationCover testID="vpn-page-privacy-cover">{admission.canRetry&&<LavaActionButton title="Unlock Lava" role="secondary" onPress={admission.retry}/>}</PresentationCover></View>}</View>;
}

export function AutoSwitchScreen() {
  return <AutoSwitchPage/>;
}

export function DNSPatchScreen() {
  const {app}=useReview();
  if(!app)return null;
  return <NativeSettingsPage page="dnsPatch" testID="dns-patch-page"/>;
}

// Native content shares the enclosing stack's bar, transition and destination
// authentication. Its configuration editor is presented by the app's native flow
// host, not declared inside this embedded page.
function NativeSettingsPage({page,testID}:{page:'vpnChaining'|'automation'|'dnsPatch';testID:string}) {
  const route=useRoute<RouteProp<ReviewRoutes,'VPNChaining'>>();
  const focused=useIsFocused();
  const onLayout=usePresentationNativeLayout();
  const navigation=useReviewNavigation(route.params);
  useDiscoveryVisit(page==='dnsPatch'?'ios27Patch.page':undefined);
  const open=(destination:string)=>{
    if(destination!=='DNS'&&destination!=='Upgrade'&&!(page==='dnsPatch'&&destination==='VPNChaining'))return;
    const state=navigation.getState();const previous=state.routes[state.index-1];
    if(destination===route.params?.returnTo&&route.params.returnKey&&previous?.name===destination&&previous.key===route.params.returnKey)navigation.goBack();
    else navigation.navigate(destination);
  };
  return <NativePage page={page} focused={focused} testID={testID} onLayout={onLayout} style={{flex:1}}
    onBack={()=>navigation.goBack()} onNavigate={event=>open(event.nativeEvent.destination)}/>;
}

export {CustomEntryScreen} from './CustomEntryScreen';

// Preview-only route. Full-app feedback is the shared native-authorized flow.
export function FeedbackSettingsScreen() { return <FeedbackScreen/>; }

export function DeviceQAScreen() {
  const {app, live} = useReview();
  const available=useRef(false);
  // PhoneQAView owns an unpublished configuration buffer. A temporary missing
  // projection conceals that same native host; only explicit availability loss
  // or the enclosing owner boundary retires it.
  if(live)available.current=live.qaTools;
  if (!app || !available.current) return null;
  return <DeviceQANativePage/>;
}

// Only an admitted host owns a viewport ticket. Availability/owner retirement
// disposes its measurement; temporary revocation keeps that same native layout.
function DeviceQANativePage() {
  const navigation=useNavigation();
  const focused=useIsFocused();
  const concealed=useRouteBodyConcealed();
  const onLayout=usePresentationNativeLayout();
  return <NativePage page="phoneQA" focused={focused} testID="device-qa-page" onLayout={onLayout}
    pointerEvents={concealed?'none':'auto'} accessibilityElementsHidden={concealed}
    importantForAccessibility={concealed?'no-hide-descendants':'auto'} style={{flex:1,opacity:concealed?0:1}}
    onBack={() => navigation.goBack()} />;
}
