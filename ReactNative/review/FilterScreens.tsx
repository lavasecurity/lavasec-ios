import {Alert, localized, localizedFormat, localizedNumber} from '../app/presentation';
import {useFilterRoute} from './filter-route';
import {FilterShareCard,type ShareCardContent} from './FilterShareCard';
import {SettingsSurface,SettingsIntro} from './settings-scaffold';
import {StoryStack,FilterOverview,FilterIdentity,FilterEmoji,CatalogSheet,BudgetBar,PrivateQRCode,SetupCodeField} from './story-scaffold';
import {activeFilterSummary} from './connection-model';
import {useAppAction} from '../app/actions';
import {useAppQuery} from '../app/queries';
import {mayRetainPresentationFrame} from '../app/read-cache';
import {usePresentationAuthority,usePresentationReadiness} from '../app/use-presentation-readiness';
import {useEffect, useMemo, useRef, useState} from 'react';
import { AppState, Share, View, type ScrollViewInstance} from 'react-native';
import {useIsFocused,useRoute, type RouteProp} from '@react-navigation/native';
import NativeReview from '../specs/NativeLavaReview';
import {LavaActionButton, LavaCard, LavaIconButton} from '../src';
import {colors} from '../src/colors.ios';
import {Copy, Metric, Row, Screen, Section, Symbol} from './primitives';
import {AccessorySlot, DomainInput, Link, AddAction, Group, Info, InputRow, ListRow, Panel, Quiet, QuietFooter, Search, Sheet, toolbarButton, useToolbar} from './scaffold';
import {lavaTokens} from '../src/generated/tokens';
import {useReview} from './ReviewContext';
import {addPreviewDomain, initialPreviewDraft, previewDiff} from './preview-model';
import {filterFixtures} from './session';
import {catalogFixture} from './catalog-fixture';
import {previewNotice, useReviewNavigation, type ReviewRoutes} from './navigation';

export function FiltersScreen() {
  const nav = useReviewNavigation(); const {session,setSession,app,live} = useReview();
  const activeFilter=activeFilterSummary(live,session);
  const saved=live?.filters.find(filter=>filter.id===live.session.activeFilterID);
  const preview=!app?filterFixtures.find(filter=>filter.name===session.activeFilter):undefined;
  const available=!!(saved??preview);
  useToolbar({unstable_headerRightItems:()=>[toolbarButton('Import','square.and.arrow.down',()=>{if(app)void app.command({type:'native.flow',flow:'import'}).catch(error=>Alert.alert('Lava',error.message));else nav.navigate('Import');})]},[app]);
  const open=()=>{
    if(!available)return;
    if(app&&saved){void app.command({type:'filter.open',id:saved.id}).then(()=>nav.navigate('Filter',{id:saved.id})).catch(error=>Alert.alert('Lava',error.message));return;}
    setSession({...session,filter:preview!.name,blocklists:[...preview!.lists],savedBlocklists:[...preview!.lists],editing:false});nav.navigate('Filter');
  };
  return <Screen><StoryStack>
    <FilterOverview emoji={activeFilter.emoji} name={available?activeFilter.name:localized('Filter unavailable')} rules={activeFilter.count} disabled={!available} onOpen={open}
      counts={[{label:'Blocklists',value:saved?.lists.length??preview?.lists.length},
        {label:'Blocked Domains',value:saved?.blockedDomainCount??(!app?0:undefined)},
        {label:'Allowed Exceptions',value:saved?.allowedExceptionCount??(!app?0:undefined)}]}/>
    <SettingsSurface><Row intent="page" icon="line.3.horizontal.decrease.circle" title="Switch or manage filters" onPress={()=>nav.navigate('Library')} /><Row intent="page" icon="arrow.triangle.2.circlepath" title="Auto-switch filters" onPress={()=>{if(app)nav.navigate('AutoSwitch');else previewNotice();}}/></SettingsSurface>
  </StoryStack></Screen>;
}

export function LibraryScreen() {
  const nav=useReviewNavigation();const {session,setSession,setDraft,app,live}=useReview(); const run=useAppAction();
  const [previewEditing,setEditing]=useState(false);const [previewStaged,setStaged]=useState<string[]>([]);
  const editing=live?.libraryEditing?.active??previewEditing; const staged=live?.libraryEditing?.deletions??previewStaged; const hasChanges=live?.libraryEditing?.hasChanges??staged.length>0;
  const pending=useRef(false);const [busy,setBusy]=useState(false);
  const filters=live?.filters??filterFixtures.map(filter=>({...filter,id:filter.name,frozen:false,empty:false,shareable:true}));
  const finishEditing=()=>{if(app)run({type:'library.cancel'});setEditing(false);setStaged([]);};
  const close=()=>hasChanges?Alert.alert('Discard changes?',"Your draft library changes won't be applied.",[{text:'Cancel',style:'cancel'},{text:'Discard',style:'destructive',onPress:finishEditing}]):finishEditing();
  const perform=async(action:()=>Promise<unknown>)=>{if(pending.current)return;pending.current=true;setBusy(true);try{await action();}catch(error){if((error as Error).message!=='Authentication cancelled.')Alert.alert('Lava',(error as Error).message);}finally{pending.current=false;setBusy(false);}};
  const open=(id:string)=>{if(app)void perform(async()=>{await app.command({type:'filter.open',id});nav.navigate('Filter',{id});});};
  const begin=()=>{if(!app){setEditing(true);return;}void perform(async()=>{await app.command({type:'library.edit'});setEditing(true);});};
  const create=()=>{
    if(!app||!live){previewNotice();return;}
    if(hasChanges){confirm();return;}
    if(filters.length>=live.limits.maxFilters){
      if(live.plus.enabled)Alert.alert('Maximum filters reached',localizedFormat('You can host up to %d filters. Delete one to add another.',live.limits.maxFilters),[{text:'OK',style:'cancel'}],{verbatimMessage:true});
      else nav.navigate('Upgrade');
      return;
    }
    void perform(async()=>{const id=await app.command<string|false>({type:'library.form',form:'create'});if(typeof id==='string'){finishEditing();nav.navigate('Filter',{id});}});
  };
  const confirm=()=>{if(!app){previewNotice();return;}void perform(async()=>{if(await app.command<boolean>({type:'library.form',form:'delete',ids:staged}))finishEditing();});};
  useToolbar({headerBackVisible:!editing,gestureEnabled:!editing,
    unstable_headerLeftItems:editing?()=>[toolbarButton('Close edit mode','xmark',close,busy)]:undefined,
    unstable_headerRightItems:()=>editing?[toolbarButton('Review changes','checkmark',confirm,busy||!hasChanges,'confirm')]:[toolbarButton('Edit','square.and.pencil',begin,busy)],
  },[editing,staged,hasChanges,busy,app,live]);
  const share=(filter:typeof filters[number])=>{
    if(!('shareable' in filter)||!filter.shareable)return;
    nav.navigate('ShareDetail',{id:filter.id});
  };
  const choose=(filter:typeof filters[number])=>{
    if(!app){setSession({...session,filter:filter.name,blocklists:[...filter.lists],savedBlocklists:[...filter.lists],editing:false});setDraft(initialPreviewDraft());nav.navigate('Filter');return;}
    if(editing){void perform(()=>app.command({type:'library.form',form:'rename',id:filter.id}));return;}
    if(filter.id===live?.session.activeFilterID){open(filter.id);return;}
    void NativeReview.chooseFilterAction(filter.name,!filter.frozen,'shareable' in filter&&!!filter.shareable).then(action=>{
      if(action==='switch')void perform(()=>app.command({type:'filter.switch',id:filter.id}));
      else if(action==='view')open(filter.id);
      else if(action==='share')share(filter);
    }).catch(error=>Alert.alert('Lava',error.message));
  };
  return <Screen><SettingsIntro summary="Choose a filter to use, view or edit." />
    <Group footer={editing&&<View style={{padding:16}}><AddAction title="Add a filter" onPress={create}/></View>}>{filters.map(filter=>{
      const active=live?live.session.activeFilterID===filter.id:session.activeFilter===filter.name;
      const deleting=staged.includes(filter.id);const disabled=busy||editing&&(filter.frozen||deleting);
      return <ListRow testID={`filter.library.${filter.id}`} separateTrailing verbatimTitle key={filter.id} title={filter.name} metadata={filter.empty?'Blocks nothing':localizedFormat('%@ rules',filter.count)}
        leading={<FilterEmoji emoji={'emoji' in filter?filter.emoji:undefined}/>} pending={deleting} disabled={disabled} onPress={()=>choose(filter)}
        trailing={<AccessorySlot>{editing&&!active&&!filter.frozen&&filters.length>1
          ? <LavaIconButton title={deleting?'Undo':'Delete'} item={filter.name} icon={deleting?'undo':'remove'} role={deleting?'neutral':'destructive'} disabled={busy} onPress={()=>{if(app)run({type:'library.toggleDeletion',id:filter.id});else setStaged(current=>current.includes(filter.id)?current.filter(id=>id!==filter.id):[...current,filter.id]);}}/>
          : active?<Symbol name="play.circle.fill" size={20}/>:filter.frozen?<Symbol name="lock.fill" size={14} tone="secondary"/>:null}
        </AccessorySlot>}/>;
    })}</Group>
    {editing&&<LavaActionButton role="secondary" title="Restore default filters" disabled={busy||hasChanges} onPress={()=>Alert.alert('Restore default filters?',"This replaces your filters with the three defaults — Core, Balanced, and Extra — with Balanced in effect.",[{text:'Cancel',style:'cancel'},{text:'Restore',style:'destructive',onPress:()=>{if(app)void perform(async()=>{await app.command({type:'filter.restoreDefaults'});finishEditing();});else previewNotice();}}])}/>}
    {!live?.plus?.enabled&&<QuietFooter note="Manage more than three filters with Lava Plus." title="Upgrade" onPress={()=>nav.navigate('Upgrade')}/>}
  </Screen>;
}

export function FilterScreen() {
  const nav=useReviewNavigation();const {session,setSession,draft,setDraft,savedDraft,app,live}=useReview(); const run=useAppAction();
  const {id,ready}=useFilterRoute(true);
  const saving=useRef(false);const [busy,setBusy]=useState(false);
  const refreshPending=useRef<Promise<unknown>|null>(null);const [refreshing,setRefreshing]=useState(false);
  const refresh=()=>{
    if(refreshPending.current)return refreshPending.current;
    if(!app||!id||!ready||id!==live?.session.activeFilterID)return Promise.resolve();
    setRefreshing(true);
    const request=app.command({type:'filter.refresh',id}).finally(()=>{refreshPending.current=null;setRefreshing(false);});
    refreshPending.current=request;return request;
  };
  const editPending=useRef(false);
  const edit=()=>{
    if(editPending.current||!ready||app&&!id||session.editing)return;
    if(!app){setSession({...session,editing:true});return;}
    editPending.current=true;
    void app.command({type:'filter.edit',id:id!}).catch(error=>{if(error.message!=='Authentication cancelled.')Alert.alert('Lava',error.message);}).finally(()=>{editPending.current=false;});
  };
  const save=()=>{
    if(!app){if(!changed){setSession({...session,editing:false});return;}nav.navigate('Review',{id});return;}
    if(!ready||!id||saving.current)return;
    saving.current=true;setBusy(true);
    void app.command<'review'|'saved'>({type:'filter.save',id}).then(result=>{if(result==='review')nav.navigate('Review',{id});}).catch(error=>{if(error.message!=='Authentication cancelled.')Alert.alert("Couldn't save",error.message);}).finally(()=>{saving.current=false;setBusy(false);});
  };
  const editing=ready&&session.editing&&!(app&&live?.filters.find(f=>f.id===id)?.frozen);
  const isNew=!!app&&!!live?.newFilter&&live.newFilter.id===id;
  const filter=app?(isNew?live?.newFilter:live?.filters.find(f=>f.id===id)):filterFixtures.find(f=>f.name===session.filter)??filterFixtures[1];
  const diff=previewDiff(savedDraft,draft);
  const changed=live?.filterEditing?.canSave??(Object.values(diff).some(items=>items.length>0) || session.blocklists.join('|')!==session.savedBlocklists.join('|'));
  const cancel=()=>{
    const discard=()=>{if(app&&live){void app.command({type:'filter.cancel',id:id!}).catch(error=>Alert.alert('Lava',error.message));return;}setDraft(savedDraft);setSession({...session,editing:false,blocklists:[...session.savedBlocklists]});};
    if(changed&&!isNew)Alert.alert('Discard changes?','Your draft changes will be removed. The current saved filter will stay active.',[{text:'Cancel',style:'cancel'},{text:'Discard',style:'destructive',onPress:discard}]);else discard();
  };
  const share=()=>{if(!filter||app&&(!('shareable' in filter)||!filter.shareable))return;if(!app)setSession({...session,shareFilter:filter.name});nav.navigate('ShareDetail',{id:id??filter.name});};
  useToolbar({title:'',headerBackVisible:!editing,gestureEnabled:!editing,
    unstable_headerLeftItems:editing?()=>[toolbarButton('Cancel editing','xmark',cancel)]:undefined,
    unstable_headerRightItems:()=>editing?[toolbarButton('Save','checkmark',save,busy||!!live?.filterEditing?.validation)]:[...(!live||id===live.session.activeFilterID?[toolbarButton('Refresh now','arrow.clockwise',()=>{if(live)run({type:'filter.refresh',id:id!});else previewNotice();},!app||!ready||live?.filterEditing?.refreshing)]:[]),toolbarButton('Share my filter','square.and.arrow.up',share,!ready||!filter||!!app&&(!('shareable' in filter)||!filter.shareable)),...(!live?.filters.find(f=>f.id===id)?.frozen?[toolbarButton('Edit','square.and.pencil',edit,!ready)]:[])],
  },[session,draft,savedDraft,ready,id,filter,live?.filterEditing,busy],true);
  const remove=(decision:'blocked'|'allowed',domain:string)=>{if(app&&live)run({type:'filter.domain',id:id!,decision,domain,remove:true});else setDraft({...draft,[decision]:draft[decision].filter(d=>d!==domain)});};
  const changeButton=(name:string,undo:boolean,onPress:()=>void)=><LavaIconButton title={undo?'Undo':'Remove'} item={name} testID={`filter.edit.${name}`} icon={undo?'undo':'remove'} role={undo?'neutral':'destructive'} onPress={onPress}/>;
  const lists=live?.filterEditing?.lists??session.blocklists.map(id=>({id,pending:false,undo:false}));
  const blocked=live?.filterEditing?.blocked??draft.blocked.map(id=>({id,pending:false,undo:false}));
  const allowed=live?.filterEditing?.allowed??draft.allowed.map(id=>({id,pending:false,undo:false}));
  const domainRow=(decision:'blocked'|'allowed',row:{id:string;pending:boolean;undo:boolean})=><ListRow testID={`filter.rule.${decision}.${row.id}`} verbatimTitle key={row.id} title={row.id} outcome={decision} pending={row.pending} trailing={<AccessorySlot>{editing&&changeButton(row.id,row.undo,()=>{if(app&&row.undo)run({type:'filter.undoDomain',id:id!,decision,domain:row.id});else remove(decision,row.id);})}</AccessorySlot>}/>;
  if(!ready)return <Screen><Info title="Loading filter…" description="Restoring the filter you opened." /></Screen>;
  if(!filter)return <Screen><Info title="Filter unavailable" description="This filter is no longer saved on this device." /></Screen>;
  return <Screen onRefresh={app&&id===live?.session.activeFilterID?()=>app.command({type:'filter.refresh',id:id!}):undefined}><FilterIdentity emoji={'emoji' in filter?filter.emoji:undefined} onRename={editing&&app?()=>run({type:'filter.renameForm',id:id!}):undefined} name={filter.name} rules={localizedFormat('%@ rules',filter.count)} status={live?.filterStatus.title??'Filter up to date'} icon={live?.filterStatus.icon??'checkmark.circle.fill'} warning={live?.filterStatus.warning} inactive={app?id!==live?.session.activeFilterID:filter.name!==session.activeFilter}/>
    <Section title="Lava blocks these"><Group footer={editing&&<View style={{padding:16,gap:8}}><AddAction title="Add a blocklist" onPress={()=>nav.navigate('AddBlocklist',{id})}/><AddAction title="Block a domain" onPress={()=>nav.navigate('AddDomain',{decision:'blocked',id})}/></View>}>
      {lists.map(row=><ListRow testID={`filter.rule.list.${row.id}`} verbatimTitle key={row.id} title={live?.blocklistNames[row.id]??row.id} outcome="blocked" pending={row.pending} metadata={live?.blocklistMetadata[row.id]??localizedFormat('%@ rules',localizedNumber(catalogFixture[row.id]?.count??0))} trailing={<AccessorySlot>{editing&&changeButton(row.id,row.undo,()=>{if(app&&live)run({type:row.undo?'filter.undoList':'filter.removeList',id:id!,sourceID:row.id});else setSession({...session,blocklists:session.blocklists.filter(x=>x!==row.id)});})}</AccessorySlot>} />)}
      {blocked.map(row=>domainRow('blocked',row))}
      {!lists.length&&!blocked.length&&<ListRow title="No blocklists enabled"  />}


    </Group></Section>
    <Section title="Lava lets these through"><Group footer={editing&&<View style={{padding:16}}><AddAction title="Add an exception" onPress={()=>nav.navigate('AddDomain',{decision:'allowed',id})}/></View>}>
      {allowed.length ? allowed.map(row=>domainRow('allowed',row)):<ListRow title="No allowed exceptions"  />}


    </Group></Section>
  </Screen>;
}

export function AddDomainScreen() {
  const {id,ready}=useFilterRoute();
  const nav=useReviewNavigation();const route=useRoute<RouteProp<ReviewRoutes,'AddDomain'>>();const decision=route.params.decision;
  const {draft,setDraft,app,live}=useReview();const [text,setText]=useState('');const [error,setError]=useState<{title:string;message:string}|null>(null);const saving=useRef(false);const [busy,setBusy]=useState(false);
  useToolbar({title:decision==='blocked'?'Add Blocked Domain':'Add Allowed Exception'},[decision]);
  const limit=live?(decision==='blocked'?live.limits.maxBlockedDomains:live.limits.maxAllowedDomains):25;
  const count=draft[decision].length;const atLimit=count>=limit;const freeAtLimit=atLimit&&!live?.plus.enabled;
  const usage=localizedFormat(decision==='blocked'?(freeAtLimit?'%d/%d blocked domains used - Upgrade or remove entries':atLimit?'%d/%d blocked domains used - Remove entries to continue':'%d/%d blocked domains used'):(freeAtLimit?'%d/%d exceptions used - Upgrade or remove entries':atLimit?'%d/%d exceptions used - Remove entries to continue':'%d/%d exceptions used'),count,limit);
  const add=async(raw:string)=>{
    if(saving.current||!ready)return;
    if(freeAtLimit){nav.navigate('Upgrade');return;}
    if(atLimit||!raw.trim())return;
    saving.current=true;setBusy(true);setError(null);
    try{
      if(app&&live){const result=await app.command<{isAccepted:false;title:string;message:string}|null>({type:'filter.domain',id:id!,domain:raw,decision});if(result?.isAccepted===false){setError(result);return;}}
      else setDraft(addPreviewDomain(draft,raw,input=>NativeReview.normalizeDomain(input),decision));
      nav.goBack();
    }catch(e){if((e as Error).message!=='Authentication cancelled.')setError({title:'Domain cannot be added',message:(e as Error).message});}finally{saving.current=false;setBusy(false);}
  };
  if(!ready)return null;
  return <Sheet>{decision==='allowed'&&<Info warning icon="exclamationmark.triangle.fill" title="Before you allow a site" description="A site you allow here always gets through, even if a blocklist would block it. Only add sites you fully trust." />}<View style={{gap:12}}><LavaCard><InputRow title="Domain"><DomainInput label={decision==='blocked'?'Domain to block':'Domain to allow'} placeholder={decision==='blocked'?"example.com":"trusted.example.com"} onChange={setText} onSubmit={raw=>void add(raw)} /></InputRow></LavaCard>
    <Copy role="caption" center color={atLimit?colors.lavaOrangeText:colors.secondaryText}>{usage}</Copy>{error&&<Info warning title={error.title} description={error.message}/>}<LavaActionButton title={freeAtLimit?'Upgrade':decision==='blocked'?'Add Domain':'Add Exception'} disabled={busy||!freeAtLimit&&(atLimit||!text.trim())} onPress={()=>void add(text)} />
  </View></Sheet>;
}
type CatalogSection = {title:string; isCustom?:boolean; sources:{id:string;name:string;licenseName:string;sourceURL:string;metadata?:string}[]};
type CatalogResponse = {sections:CatalogSection[];count:number;budget:number;pending:number;exceeded:boolean;summary:string;fraction:number;indeterminate:boolean;atOrOverBudget:boolean};
export function AddBlocklistScreen() {
  const {id,ready}=useFilterRoute();
  const {session,setSession,app,live}=useReview(); const nav=useReviewNavigation(); const run=useAppAction();
  const [selected,setSelected]=useState(session.blocklists);
  const nativeSelection=useRef(session.blocklists);
  useEffect(()=>{
    const previous=nativeSelection.current;nativeSelection.current=session.blocklists;
    // Native custom-list additions select the resulting draft, as in the native
    // picker. Deleting a source only removes that ID from the staged selection.
    if(session.blocklists.some(source=>!previous.includes(source)))setSelected(session.blocklists);
    else {
      const removed=previous.filter(source=>!session.blocklists.includes(source));
      if(removed.length)setSelected(current=>current.filter(source=>!removed.includes(source)));
    }
  },[JSON.stringify(session.blocklists)]); const [search,setSearch]=useState(''); const [saving,setSaving]=useState(false);const savingRef=useRef(false);
  const fixture=useMemo<CatalogSection[]>(()=>{try{return JSON.parse(NativeReview.getBlocklistCatalog());}catch{return [];}},[]);
  // Checkbox totals refresh asynchronously; keep the same filter's rows mounted
  // so selection cannot collapse the sheet or discard its scroll position.
  const query=useAppQuery<CatalogResponse>(ready?{type:'catalog.query',ids:selected}:null,JSON.stringify(['catalog',id]));
  const catalog=app?query.value?.sections??[]:fixture;
  useEffect(()=>{
    if(!app||!query.value||query.refreshing||query.error)return;
    const available=new Set(query.value.sections.flatMap(section=>section.sources.map(source=>source.id)));
    // Only discard staged choices no longer offered by native availability.
    // Native retains existing configured lists so they remain removable. A failed
    // refresh may retain older rows, which cannot establish current availability.
    setSelected(current=>current.every(id=>available.has(id))?current:current.filter(id=>available.has(id)));
  },[app,query.value,query.refreshing,query.error]);
  const searchQuery=search.trim().toLocaleLowerCase();
  const sections=catalog.map(section=>({...section,sources:section.sources.filter(source=>[source.name,source.licenseName,section.title,localized(section.title),...(section.isCustom?[source.sourceURL]:[])].some(value=>value.toLocaleLowerCase().includes(searchQuery)))})).filter(section=>section.sources.length);
  const estimate=app?query.value?.count??0:selected.reduce((total,name)=>total+(catalogFixture[name]?.count??0),0);
  const budget=app?query.value?.budget??live?.limits.maxFilterRules??500000:500000;
  const exceeded=app?query.value?.exceeded??false:estimate>budget;
  const freeOverLimit=exceeded&&!live?.plus.enabled;
  const fraction=app?query.value?.fraction??0:Math.min(1,estimate/budget);
  const indeterminate=app?query.value?.indeterminate??true:false;
  const summary=app?query.value?.summary??localized('Loading blocklists…'):localizedFormat('About %1$@ of %2$@ rules',`${localizedNumber(Math.round(estimate/1000))}K`,'500K');
  const changed=[...selected].sort().join('|')!==[...session.blocklists].sort().join('|');
  const save=async()=>{
    if(!ready||savingRef.current||!!app&&query.refreshing)return;
    if(exceeded){if(freeOverLimit)nav.navigate('Upgrade');return;}
    savingRef.current=true;setSaving(true);
    try {if(app&&live)await app.command({type:'filter.lists',id:id!,ids:selected});else setSession({...session,blocklists:selected});nav.goBack();}
    catch(error){Alert.alert('Lava',(error as Error).message);}finally{savingRef.current=false;setSaving(false);}
  };
  useToolbar({title:'Choose Blocklists',unstable_headerRightItems:()=>[toolbarButton('Bring your own list','plus',()=>{if(!ready)return;if(!app||!live){previewNotice();return;}if(!live.limits.allowsCustomBlocklists){nav.navigate('Upgrade');return;}void app.command<string>({type:'filter.customList',id:id!,ids:selected}).then(id=>nav.navigate('CustomEntry',{id,kind:'blocklist'})).catch(error=>Alert.alert('Lava',error.message));})]},[app,live,selected,ready,id]);
  if(!ready)return null;
  return <CatalogSheet sections={sections.map(section=>({title:section.title,items:section.sources}))}
    search={search} onSearch={setSearch} searchLabel="Search lists or categories"
    footer={<View style={{gap:9}}><BudgetBar fraction={fraction} indeterminate={indeterminate} warning={exceeded||query.value?.atOrOverBudget}/><Copy verbatim role="caption" center color={exceeded?colors.lavaOrangeText:colors.secondaryText}>{summary}</Copy><LavaActionButton title={freeOverLimit?'Upgrade':saving?'Saving…':'Save Selection'} disabled={saving||!!app&&(!query.value||query.refreshing)||!freeOverLimit&&(!changed||exceeded)} onPress={()=>void save()} /></View>}
    renderRow={(source,sectionTitle)=><ListRow separateTrailing verbatimTitle key={source.id} title={source.name} subtitle={source.licenseName} metadata={app?source.metadata:catalogFixture[source.name]?localizedFormat('%@ rules',localizedNumber(catalogFixture[source.name]!.count)):"Not downloaded"} metadataPrefix={app?undefined:catalogFixture[source.name]?.bucket} selected={selected.includes(app?source.id:source.name)} trailing={!!app&&!!live&&catalog.find(section=>section.title===sectionTitle)?.isCustom?<AccessorySlot><LavaIconButton title="Delete custom blocklist" icon="delete" role="destructive" item={source.name} onPress={()=>Alert.alert("Delete custom list?",source.name,[{text:"Cancel",style:"cancel"},{text:"Delete",style:"destructive",onPress:()=>{void app.command({type:"filter.deleteCustomList",id:id!,sourceID:source.id}).then(()=>setSelected(current=>current.filter(id=>id!==source.id))).catch(error=>Alert.alert("Lava",error.message));}}],{verbatimMessage:true})}/></AccessorySlot>:undefined} onPress={()=>setSelected(selected.includes(app?source.id:source.name)?selected.filter(id=>id!==(app?source.id:source.name)):[...selected,app?source.id:source.name])} />}
    empty={<Group><ListRow title={query.error??(app&&!query.value?'Loading blocklists…':search?'No blocklists found':'No blocklists available')} /></Group>} />;
}
export function ReviewScreen() {
  const {id,ready}=useFilterRoute();
  const {draft,savedDraft,session,app,live}=useReview();const nav=useReviewNavigation(); const [validation,setValidation]=useState<{identity:string;review?:string;error?:string}>();const [busy,setBusy]=useState(false);
  const route=useRoute<RouteProp<ReviewRoutes,'Review'>>();const standaloneReview=route.params?.standaloneReview;
  useEffect(()=>()=>{if(app&&standaloneReview)void app.command({type:'domains.cancel',token:standaloneReview}).catch(()=>{});},[app,standaloneReview]);
  const authoritative=usePresentationAuthority(app);const focused=useIsFocused();
  const authorization=useRef({authoritative,epoch:0});
  if(authorization.current.authoritative!==authoritative)authorization.current={authoritative,epoch:authorization.current.epoch+1};
  // Validation capabilities must be renewed after authority is revoked. Broad
  // source revisions also advance when review itself runs and cannot key this effect.
  const identity=JSON.stringify([authorization.current.epoch,live?.security?.readRevision,live?.security?.ownerRevision,live?.session.filterID,live?.session.activeFilterID,draft,savedDraft,session.blocklists,session.savedBlocklists,live?.filterEditing?.reviewCanConfirm,live?.filterEditing?.validation]);
  const review=authoritative&&validation?.identity===identity?validation.review:undefined;
  const error=validation?.identity===identity?validation.error:undefined;
  const setError=(message:string)=>setValidation(current=>({identity,review:current?.identity===identity?current.review:undefined,error:message}));
  usePresentationReadiness(app,focused&&ready&&!!live?.session.editing&&!live?.filterPreparationPresented,!!review||!!error,identity);
  useEffect(()=>{if(!authoritative||!focused||!ready||!app||!live||!live.session.editing||live.filterPreparationPresented)return;let current=true;setValidation(undefined);void app.command<string>({type:'filter.review',id:id!}).then(value=>{if(current)setValidation({identity,review:value});}).catch(error=>{if(current)setValidation({identity,error:error.message});});return()=>{current=false;};},[app,identity,live?.filterPreparationPresented,ready,id,authoritative,focused]);
  const applying=useRef(false);const hadPreparation=useRef(false);
  useEffect(()=>{
    if(live?.filterPreparationPresented){hadPreparation.current=true;return;}
    if(hadPreparation.current&&!standaloneReview&&live?.session.editing){hadPreparation.current=false;nav.goBack();}
  },[live?.filterPreparationPresented,standaloneReview]);
  // The authoritative editing transition in useFilterRoute owns dismissal. A
  // second pop from the command response can also dismiss the saved filter detail.
  const apply=()=>{if(applying.current||!ready||!app||!live||!review)return;applying.current=true;setBusy(true);void app.command({type:'filter.apply',id:id!,review,...(standaloneReview?{standaloneReview}:{})}).catch(error=>setError(error.message)).finally(()=>{applying.current=false;setBusy(false);});};
  const diff=previewDiff(savedDraft,draft);
  const rows=[...diff.blockedAdded.map(title=>({title,kind:'Blocked domain added'})),...diff.blockedRemoved.map(title=>({title,kind:'Blocked domain removed'})),...diff.allowedAdded.map(title=>({title,kind:'Allowed domain added'})),...diff.allowedRemoved.map(title=>({title,kind:'Allowed domain removed'}))];
  const lists=[...session.blocklists.filter(x=>!session.savedBlocklists.includes(x)).map(title=>({title,kind:'Added'})),...session.savedBlocklists.filter(x=>!session.blocklists.includes(x)).map(title=>({title,kind:'Removed'}))];
  const count=rows.length+lists.length;
  if(!ready)return null;
  return <Sheet footer={<LavaActionButton title="Confirm changes" disabled={!app||!review||busy||live?.filterEditing?.reviewCanConfirm===false} onPress={apply} />}>
    {(live?.filterEditing?.validation||error)&&<Info warning title="Review cannot continue" description={live?.filterEditing?.validation||error}/>}
    <Copy color={colors.secondaryText}>{localizedFormat('%@ will be saved locally.',localizedFormat(count===1?'%d change':'%d changes',count))}</Copy>
    {!!diff.allowedAdded.length&&<Info warning icon="exclamationmark.triangle.fill" title="Be extra careful" description="Allowed exceptions let a site through even when a blocklist would catch it." />}
    {[{title:'Blocklists',added:lists.filter(row=>row.kind==='Added').map(row=>live?.blocklistNames[row.title]??row.title),removed:lists.filter(row=>row.kind==='Removed').map(row=>live?.blocklistNames[row.title]??row.title)},
      {title:'Blocked Domains',added:diff.blockedAdded,removed:diff.blockedRemoved},{title:'Allowed Exceptions',added:diff.allowedAdded,removed:diff.allowedRemoved}].filter(group=>group.added.length||group.removed.length).map(group=><Section key={group.title} title={group.title}><Group>{[...group.added.map(title=>({title,added:true})),...group.removed.map(title=>({title,added:false}))].map(row=><View key={`${row.added}-${row.title}`} accessible accessibilityLabel={localized(row.added?'Added':'Removed')} accessibilityValue={{text:row.title}}><ListRow verbatimTitle title={row.title} leading={<Symbol name={row.added?'plus':'minus'} size={lavaTokens.toolbar.framedIconPointSize} tone={row.added?'green':'error'}/>} /></View>)}</Group></Section>)}
    {!count&&<Group><ListRow title="No changes yet" /></Group>}
  </Sheet>;
}

export function ShareScreen() {
  const nav=useReviewNavigation();const {session,setSession,live}=useReview();
  const filters=live?.filters??filterFixtures.map(filter=>({...filter,id:filter.name,shareable:true,shareSummary:localizedFormat('%@ rules',filter.count)}));
  return <Screen><Section title="Your filters"><Group>{filters.map(filter=><ListRow action icon="line.3.horizontal.decrease.circle" verbatimTitle key={filter.id} title={filter.name} metadata={filter.shareSummary} disabled={!filter.shareable} onPress={()=>{setSession({...session,shareFilter:filter.name});nav.navigate('ShareDetail',{id:filter.id});}} />)}</Group></Section></Screen>;
}
export function ShareDetailScreen() {
  const {session,app,live}=useReview();const [revealed,setRevealed]=useState(false);const [copied,setCopied]=useState(false);
  const focused=useIsFocused();const [exportActive,setExportActive]=useState(AppState.currentState==='active');const [cardReady,setCardReady]=useState(false);
  const displayPolicy=useRef(live);displayPolicy.current=live;
  const route=useRoute<RouteProp<ReviewRoutes,'ShareDetail'>>();
  const filter=live?.filters.find(item=>route.params?.id?item.id===route.params.id:item.name===session.shareFilter);
  const query=useAppQuery<{code:string;url:string;image:string|null;card?:ShareCardContent|null}>(filter&&filter.shareable!==false?{type:'share.query',id:filter.id}:null, filter&&filter.shareable!==false?filter.id:undefined, true);
  const fixture=useMemo<{code:string;url:string;image:string;card?:ShareCardContent|null}|null>(()=>{if(app)return null;try{return JSON.parse(NativeReview.getSharePreview(session.shareFilter));}catch{return null;}},[app,session.shareFilter]);
  const content=app?query.value:fixture;
  useEffect(()=>{setRevealed(false);setCopied(false);},[filter?.id,content?.code]);
  // A revealed sharing page follows the same native off choice as every other
  // painted page. A new code or a concealment boundary still retires its reveal.
  useEffect(()=>{const subscription=AppState.addEventListener('change',state=>{setExportActive(state==='active');if(state!=='active'&&!mayRetainPresentationFrame(displayPolicy.current)){setRevealed(false);setCopied(false);}});return()=>subscription.remove();},[]);
  useToolbar({unstable_headerRightItems:()=>[toolbarButton('Share filter card','square.and.arrow.up',()=>{if(app&&filter&&content?.card&&cardReady)void app.command({type:'share.card',id:filter.id,token:content.card.token}).catch(error=>Alert.alert('Lava',error.message));else if(!app&&content)void Share.share({message:content.url});},app?(!content?.card||!cardReady||!exportActive||!focused):!content?.image)]},[content,app,filter?.id,cardReady,exportActive,focused]);
  return <Sheet>
    {app&&content?.card&&exportActive&&focused&&<FilterShareCard key={content.card.token} content={content.card} onReady={setCardReady}/>}
    <SettingsIntro summary="Your filter is shared as-is. Review your blocklists, blocked sites, and allowed exceptions before sharing. Anyone with the code can see them." />
    <PrivateQRCode image={content?.image} revealed={revealed} onReveal={()=>setRevealed(true)} available={!!content} loadingMessage={query.error??'Loading filter…'}/>
    <Section title="Setup code"><LavaCard role="panel"><Copy verbatim role="caption" mono color={colors.ink}>{content?.code??''}</Copy></LavaCard><LavaActionButton title={copied?'Copied':'Copy setup code'} disabled={!content} onPress={()=>{if(app&&filter){void app.command({type:'share.copy',id:filter.id}).then(()=>setCopied(true)).catch(error=>Alert.alert('Lava',error.message));}else{NativeReview.copySharePreview(session.shareFilter);setCopied(true);}}} /><Quiet>Share this code only with people you trust.</Quiet></Section>
  </Sheet>;
}
export function ImportScreen() {
  const nav=useReviewNavigation();const [stage,setStage]=useState<'method'|'code'>('method');const [code,setCode]=useState('');
  useToolbar({title:stage==='code'?'Enter a code':'Import a filter',unstable_headerLeftItems:stage==='code'?()=>[toolbarButton('Back','chevron.left',()=>setStage('method'))]:()=>[],unstable_headerRightItems:stage==='method'?()=>[toolbarButton('Close','xmark',()=>nav.goBack())]:()=>[]},[stage]);
  return stage==='method'?<Sheet><Panel warning><Copy role="supporting">Check who shared this filter and review its contents carefully before importing. Shared filters aren’t reviewed by Lava.</Copy></Panel><SettingsSurface><Row intent="page" icon="qrcode.viewfinder" title="Scan a QR code" onPress={previewNotice} /><Row intent="page" icon="photo.on.rectangle" title="Import from Photo" onPress={previewNotice} /><Row intent="page" icon="character.cursor.ibeam" title="Enter a code" onPress={()=>setStage('code')} /></SettingsSurface></Sheet>
    :<Sheet footer={<LavaActionButton title="Continue" disabled={!code.trim()} onPress={previewNotice} />}><Info icon="character.cursor.ibeam" title="Enter a setup code" description={'Paste the setup code someone shared with you. It usually starts with "LF1-".'} /><InputRow title="Setup code"><SetupCodeField onChange={setCode}/></InputRow></Sheet>;
}
