import {useEffect,useRef,useState} from 'react';
import {Linking} from 'react-native';
import {useRoute,type RouteProp} from '@react-navigation/native';
import {Alert} from '../app/presentation';
import type {DNSChoice} from '../app/contract';
import {LavaActionButton,LavaIconButton,LavaToggleControl} from '../src';
import {colors} from '../src/colors.ios';
import {Screen,Section,Symbol} from './primitives';
import {AccessorySlot,AddAction,Group,ListRow,Quiet,toolbarButton,useToolbar} from './scaffold';
import {OrderedListAction,useSettingsEditToolbar,SettingsIntro,SettingsInset,SettingsSurface,SettingsGlyph} from './settings-scaffold';
import {CatalogSheet} from './story-scaffold';
import {useReview} from './ReviewContext';
import {useReviewNavigation,type ReviewRoutes} from './navigation';
import {selection,sameDNS,useDNSEditor} from './dns-editor';

const report=(error:unknown)=>{if((error as Error).message!=='Authentication cancelled.')Alert.alert('Lava',(error as Error).message);};
const openSettings=()=>{void Linking.openSettings().catch(report);};
const dnsRowMetadata=(choice?:DNSChoice)=>[choice?.transport,choice?.metadata].filter(Boolean).join(' · ');
export function DNSScreen(){
  const nav=useReviewNavigation();const {app,live}=useReview();const {draft,setDraft}=useDNSEditor();
  const [{editing,busy},setMode]=useState({editing:false,busy:false});const pending=useRef(false);
  const setBusy=(busy:boolean)=>setMode(mode=>({...mode,busy}));
  const setEditing=(editing:boolean)=>setMode(mode=>({...mode,editing}));
  const editable=live?.dns.editable!==false;const canEdit=editable;const tiers=editing?draft.tiers:live?.dns.tiers??[];
  useEffect(()=>{if(!editable){setEditing(false);setDraft({tiers:[],context:''});}},[editable]);
  const systemDNS=editing?draft.systemDNS:live?.dnsPatch?.provider;
  const systemChanged=editing&&(draft.systemDNS?.id??null)!==(draft.systemDNSOriginalID??null);
  useEffect(()=>()=>setDraft({tiers:[],context:''}),[]);
  const edit=()=>{setDraft({tiers:live?.dns.tiers??[],context:live?.dns.tiersContext??'',systemDNS:live?.dnsPatch?.provider??null,systemDNSOriginalID:live?.dnsPatch?.provider?.id??null});setEditing(true);};
  const cancel=()=>{const discard=()=>{setEditing(false);setDraft({tiers:[],context:''});};
    if(systemChanged||JSON.stringify(draft.tiers)!==JSON.stringify(live?.dns.tiers))Alert.alert('Discard changes?','Your saved DNS settings will stay active.',[{text:'Cancel',style:'cancel'},{text:'Discard',style:'destructive',onPress:discard}]);else discard();};
  const commit=async()=>{if(!app||pending.current)return;pending.current=true;setBusy(true);
    try{
      if(systemChanged){
        if((live?.dnsPatch?.provider?.id??null)!==(draft.systemDNSOriginalID??null))throw new Error('System DNS changed. Reopen the editor before saving.');
        await app.command(draft.systemDNS?{type:'settings.set',key:'dnsPatchProvider',value:draft.systemDNS.id}:{type:'settings.set',key:'dnsPatchRemove',value:true});
        // A later tier-save failure must not pretend the completed system operation is
        // still pending. Keep the remaining tier draft retryable against actual state.
        setDraft({...draft,systemDNSOriginalID:draft.systemDNS?.id??null});
      }
      if(editable&&JSON.stringify(draft.tiers.map(selection))!==JSON.stringify((live?.dns.tiers??[]).map(selection)))await app.command({type:'dns.tiers',context:draft.context,tiers:draft.tiers.map(selection)});
      setMode({editing:false,busy:false});
    }catch(e){report(e);setBusy(false);}finally{pending.current=false;}};
  const save=()=>{if(pending.current)return;
    if(systemChanged&&!draft.systemDNS)Alert.alert('Remove DNS profile?','Save your DNS changes and remove Lava’s System DNS profile?',[
      {text:'Cancel',style:'cancel'},{text:'Remove DNS profile',style:'destructive',onPress:()=>void commit()},
    ]);else void commit();};
  useSettingsEditToolbar({editing,busy,canEdit:editable&&canEdit&&!!app,saveDisabled:!tiers.length,
    onEdit:edit,onCancel:cancel,onSave:()=>void save()});
  const toggleTier=async(index:number,value:boolean)=>{
    if(!app||pending.current||editing)return;
    pending.current=true;
    try{await app.command({type:'dns.toggle',context:live?.dns.tiersContext??'',index,value});}
    catch(error){report(error);}finally{pending.current=false;}
  };
  const removeTier=(index:number)=>{
    const remaining=tiers.filter((_,i)=>i!==index);
    setDraft({...draft,tiers:remaining.some(row=>row.isEnabled!==false)?remaining:remaining.map(row=>({...row,isEnabled:true}))});
  };
  const command=async(key:string)=>{if(!app||pending.current)return false;pending.current=true;setBusy(true);
    try{await app.command({type:'settings.set',key,value:true});return true;}catch(e){report(e);return false;}finally{pending.current=false;setBusy(false);}};
  const state=live?.dnsPatch?.state;const installed=state==='enabled'||state==='disabled';const enabled=state==='enabled';
  // The bridge supplies a provider only when configuration readback exists.
  // Selection, catalog matching, and error status do not erase that evidence.
  const canUninstall=!!systemDNS;
  const checking=state==='checking'||!state;
  const profileBusy=busy||live?.dnsPatch?.busy||checking;
  const profileTitle=checking?'Checking profile…':state==='error'?'Unable to check profile':enabled?'Profile installed and selected':'Select Lava DNS profile';
  const profileNote=checking||enabled?undefined:state==='error'?'Tap to check again.':
    'In the Settings app, go to General → VPN & Device Management → DNS. Select “Lava Security”.';
  const profileIcon=enabled?'checkmark.circle.fill':'gearshape';
  const selectProfile=async()=>{
    if(state==='error')await command('dnsPatchCheck');
    else if(installed)openSettings();
    else if(state==='different'||state==='absent'){if(await command('dnsPatchSetup'))openSettings();}
  };
  const uninstallProfile=()=>{
    if(!app||pending.current||profileBusy)return;
    Alert.alert('Remove DNS profile?','Remove Lava’s System DNS profile?',[
      {text:'Cancel',style:'cancel'},{text:'Remove DNS profile',style:'destructive',onPress:()=>void command('dnsPatchRemove')},
    ]);
  };
  return <Screen><SettingsIntro summary={editable?'Choose who looks up website addresses for your device.':'With fallback off, VPN chaining uses DNS from its WireGuard configuration.'}
    action={!editable?{title:'Review VPN chaining',onPress:()=>nav.navigate('VPNChaining')}:undefined}/>
    {editable&&<><Section title="Resolution tiers in Lava" footer="Lava tries the primary DNS first, then the fallback DNS if needed."><Group footer={editing&&editable?<OrderedListAction count={tiers.length} addTitle="Add fallback DNS" disabled={busy}
      onAdd={()=>nav.navigate('DNSPicker',{target:'tier',index:tiers.length})} onSwap={()=>setDraft({...draft,tiers:[...tiers].reverse()})}/>:undefined}>
      {tiers.map((tier,index)=><ListRow key={index} title={tier.name} metadata={dnsRowMetadata(tier)}
        leading={<Symbol name={`${index+1}.circle`} tone="primary"/>} disabled={busy}
        onPress={editing&&editable?()=>nav.navigate('DNSPicker',{target:'tier',index}):undefined}
        trailing={<AccessorySlot switchable>{editing?(editable&&tiers.length>1?<LavaIconButton title="Remove" item={tier.name} icon="remove" role="destructive" onPress={()=>removeTier(index)}/>:null)
          :<LavaToggleControl title={tier.name} testID={`dns.tier-toggle.${index}`} value={tier.isEnabled!==false} disabled={busy||(tier.isEnabled!==false&&tiers.filter(row=>row.isEnabled!==false).length===1)} onValueChange={value=>toggleTier(index,value)}/>}</AccessorySlot>}/>)}
    </Group></Section>
    {live?.dnsPatch?.available&&<Section title="System DNS">
      <Group footer={editing&&!systemDNS?<SettingsInset><AddAction title="Add System DNS" onPress={()=>nav.navigate('DNSPicker',{target:'profile'})}/></SettingsInset>:undefined}>
        {systemDNS?<ListRow title={systemDNS.name} metadata={dnsRowMetadata(systemDNS)}
          leading={<Symbol name="s.circle" tone="primary"/>} disabled={profileBusy}
          onPress={editing?()=>nav.navigate('DNSPicker',{target:'profile'}):undefined}
          trailing={<AccessorySlot>{editing?<LavaIconButton title="Remove" item="System DNS" icon="remove" role="destructive" disabled={profileBusy} onPress={()=>setDraft({...draft,systemDNS:null})}/>:null}</AccessorySlot>}/>
          :<ListRow title={!editing&&checking?'Checking System DNS…':!editing&&state==='error'?'Unable to check System DNS':'System DNS not configured'} leading={<Symbol name="s.circle" tone="primary"/>}/>}
      </Group>
      {!editing&&systemDNS&&<SettingsSurface tone={enabled?'green':'neutral'} footer={profileNote}>
        <ListRow title={profileTitle} leading={profileBusy?<SettingsGlyph name={profileIcon} busy/>:<Symbol name={profileIcon} tone={enabled?'white':'primary'}/>} action disabled={profileBusy}
          onPress={selectProfile}/>
      </SettingsSurface>}
      {!editing&&canUninstall&&<SettingsSurface>
        <ListRow action title="Uninstall profile" icon="trash" color={colors.errorText} testID="dns.profile.uninstall"
          disabled={profileBusy||!app} onPress={uninstallProfile}/>
      </SettingsSurface>}
      <Quiet>This profile handles system DNS requests and helps Lava filter with Connectivity Assist.</Quiet>
    </Section>}
    </>}
  </Screen>;
}

export function DNSPickerScreen(){
  const nav=useReviewNavigation();const route=useRoute<RouteProp<ReviewRoutes,'DNSPicker'>>();const {target,index=0}=route.params;
  const {app,live}=useReview();const {draft,setDraft}=useDNSEditor();const [search,setSearch]=useState('');const [busy,setBusy]=useState(false);const pending=useRef(false);
  const [selected,setSelected]=useState<DNSChoice|undefined>(target==='profile'?(draft.systemDNS??undefined):draft.tiers[index]);
  const [customToken,setCustomToken]=useState<string>();
  const [custom,setCustom]=useState<DNSChoice|undefined>(selected?.id==='custom-dns'?selected:undefined);
  useEffect(()=>{if(customToken&&live?.dns.customDraftToken===customToken&&live.dns.customDraft){setCustom(live.dns.customDraft);setSelected(live.dns.customDraft);setCustomToken(undefined);}},[customToken,live?.dns.customDraftToken,live?.dns.customDraft]);
  const choices=target==='profile'?live?.dnsPatch?.choices??[]:[...(live?.dns.choices??[]),...(custom?[custom]:[])];
  const query=search.trim().toLocaleLowerCase();
  const sections=(target==='profile'?['DoT','DoH']:['Device','DoH','DoT','IP','DoQ']).map(title=>({title,items:choices.filter(choice=>choice.transport===title&&`${choice.name} ${choice.metadata} ${title}`.toLocaleLowerCase().includes(query))})).filter(section=>section.items.length);
  const duplicate=target==='tier'&&!!selected&&draft.tiers.some((choice,i)=>i!==index&&sameDNS(choice,selected));
  const save=async()=>{if(!selected||duplicate||pending.current)return;pending.current=true;setBusy(true);
    try{if(target==='profile'){setDraft({...draft,systemDNS:selected});}
      else {const tiers=[...draft.tiers];tiers[index]={...selected,isEnabled:draft.tiers[index]?.isEnabled!==false};setDraft({...draft,tiers});}nav.goBack();
    }catch(e){report(e);}finally{pending.current=false;setBusy(false);}};
  useToolbar({title:'Choose DNS',unstable_headerRightItems:()=>target==='tier'?[toolbarButton('Add custom DNS','plus',()=>{if(!live?.limits.allowsCustomDNS){nav.navigate('Upgrade');return;}if(!app||pending.current)return;pending.current=true;setBusy(true);void app.command<string>({type:'dns.customDraft',choice:custom}).then(id=>{setCustomToken(id);nav.navigate('CustomEntry',{id,kind:'dns'});}).catch(report).finally(()=>{pending.current=false;setBusy(false);});},busy)]:[],
  },[target,busy,draft,custom,live?.limits,selected]);
  return <CatalogSheet sections={sections} search={search} onSearch={setSearch} searchLabel="Search DNS providers or transports"
    renderRow={choice=><ListRow key={choice.id} title={choice.name} metadata={choice.metadata} selected={!!selected&&sameDNS(choice,selected)} disabled={busy||target==='tier'&&draft.tiers.some((row,i)=>i!==index&&sameDNS(row,choice))} onPress={()=>setSelected(choice)}/>}
    footer={<LavaActionButton title="Save Selection" disabled={!selected||duplicate||busy} onPress={()=>void save()}/>}
    empty={<Group><ListRow title="No DNS providers found"/></Group>}/>;
}
