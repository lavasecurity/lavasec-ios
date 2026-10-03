import {SettingsIntro} from './settings-scaffold';
import {foundation} from '../src/foundation';
import {ContextMenu} from './ContextMenu';
import {Alert, Text, localized, localizedFormat} from '../app/presentation';
import {QueryContent, useSettledSearch} from './QueryContent';
import {useAppQuery} from '../app/queries';
import {useAppAction} from '../app/actions';
import {useEffect, useMemo, useRef, useState} from 'react';
import {ActivityIndicator, View} from 'react-native';
import NativeReview from '../specs/NativeLavaReview';
import {LavaActionButton, LavaCard} from '../src';
import {colors} from '../src/colors.ios';
import {Choice, Copy, DisclosureRow, Screen, Section, Symbol} from './primitives';
import {Control, Group, Info, ListRow, Quiet, QuietFooter, Search, StatusPill, toolbarButton, useToolbar, nativeSearchOptions} from './scaffold';
import {DetailNotice, DetailValues, detailStyles as s} from './detail-scaffold';
import {useReview} from './ReviewContext';
import {previewDomains} from './preview-model';
import {previewNotice, useReviewNavigation} from './navigation';
import {reviewDNSProviders} from './session';
import {useIsFocused, useRoute} from '@react-navigation/native';

export function DomainListScreen({history=false}: {history?: boolean}) {
  const {app,session,setSession,activityExample,live}=useReview(); const run=useAppAction(); const nav=useReviewNavigation();const [search,setSearch]=useState('');const [decision,setDecision]=useState('All');
  const focused=useIsFocused();const canOpenReview=useRef(focused);
  useEffect(()=>{canOpenReview.current=focused;return()=>{canOpenReview.current=false;};},[focused]);
  const enabled=session.logs['Domain logs'];
  const enabling=useRef(false);const [enablePending,setEnablePending]=useState(false);
  const enableHistory=()=>{
    if(enabled||enabling.current)return;
    if(!app){setSession({...session,logs:{...session.logs,'Domain logs':true}});return;}
    enabling.current=true;setEnablePending(true);
    void app.command({type:'domains.enableHistory'}).catch(error=>Alert.alert('Lava',error.message))
      .finally(()=>{enabling.current=false;setEnablePending(false);});
  };
  const [limit,setLimit]=useState(30); const loadingMore=useRef(false);
  useEffect(()=>{setLimit(30);loadingMore.current=false;},[search,decision,enabled,live?.domainHistoryCount]);
  const settledSearch=useSettledSearch(search);
  const range=useRoute().params as {start?:number;end?:number}|undefined;
  const query=useAppQuery<{id:string;domain:string;metadata:string;icon?:string;tone?:string}[]>(enabled?{type:'domains.query',history,decision,search:settledSearch,...range,limit:limit+1}:null, JSON.stringify([history,decision,range?.start,range?.end,enabled]));
  useEffect(()=>{if(query.value)loadingMore.current=false;},[query.value]);
  const matching=query.value;
  const rows=app?(history?matching?.slice(0,limit):matching)??[]:enabled&&activityExample?previewDomains.filter(d=>d.includes(search.toLowerCase())).map((domain,i)=>({id:domain,domain,metadata:history?`${localized(decision)} · ${localizedFormat('%d minutes ago',i+1)}`:localizedFormat('%@ requests',String(120-i*32))})) : [];
  const clear=()=>{
    const contract=live?.confirmations?.['Clear domain history']??{title:'Clear domain history?',message:'This removes saved domain rows from this device. Filtering counts and network activity are unchanged.',action:'Clear History'};
    Alert.alert(contract.title,contract.message,[{text:'Cancel',style:'cancel'},{text:contract.action,style:'destructive',onPress:()=>run({type:'logs.clear',kind:'Clear domain history',surface:'activityViewing'})}]);
  };
  const domainActions=[{id:'copy',title:'Copy',symbol:'doc.on.doc'},{id:'blocked',title:'Block',symbol:foundation.outcome.blocked},{id:'allowed',title:'Allow',symbol:foundation.outcome.allowed}];
  const domainAction=(domain:string,action:string)=>{
    if(action==='copy'){run({type:'domains.copy',domain});return;}
    if(action!=='blocked'&&action!=='allowed')return;
    if(!app){previewNotice();return;}
    void app.command<{id:string;standaloneReview:string}|{rejection:{title:string;message:string}}>({type:'domains.stage',domain,decision:action}).then(result=>{
      if('rejection' in result){if(canOpenReview.current)Alert.alert(result.rejection.title,result.rejection.message);return;}
      if(canOpenReview.current)nav.navigate('Review',result);else return app.command({type:'domains.cancel',token:result.standaloneReview});
    }).catch(error=>{if(canOpenReview.current&&error.message!=='Authentication cancelled.')Alert.alert('Lava',error.message);});
  };
  const canClear=enabled&&(app?live?.hasDomainHistory===true:activityExample);
  useToolbar({headerSearchBarOptions:nativeSearchOptions('Search domains',setSearch),unstable_headerRightItems:()=>[toolbarButton('Clear Domain Logs','trash',clear,!canClear)]},[canClear]);
  // The search field belongs to the navigation item, so it no longer rides the
  // page's content insets; with it gone the page has no text input to avoid.
  return <Screen onRefresh={app?()=>query.refresh():undefined} onEndReached={()=>{if(app&&history&&!query.refreshing&&query.value&&query.value.length>limit&&!loadingMore.current){loadingMore.current=true;setLimit(limit+30);}}}>
    <Section title="Show"><Choice label="Show" options={['All','Allowed','Blocked']} value={decision} onChange={setDecision}/></Section>
    <View style={{gap:foundation.space.md}}>
      <QueryContent pending={!!enabled&&!!app&&!query.value} testID="domain-query-content">
      {rows.length>0&&(query.error?<Quiet>{query.error}</Quiet>:<Quiet>Long-press a domain</Quiet>)}
      <Group>{!enabled&&history?<View style={s.insetStack}>
        <View style={s.row}><Symbol name="lock.shield"/><Copy role="section" color={colors.safeGreen}>Local history is off</Copy></View>
        <Copy color={colors.secondaryText}>Turn on local history only if you want this searchable list.</Copy>
        <LavaActionButton title="Turn On Local History" role="panel" disabled={enablePending} busy={enablePending} onPress={enableHistory}/>
      </View>:!enabled?<ListRow title="Turn on Domain History to see your most frequent domains."/>:rows.length?rows.map(row=><ContextMenu key={row.id} testID={`domain-menu.${row.id}`} label={`${row.domain}, ${row.metadata}`} actions={domainActions} onAction={action=>domainAction(row.domain,action)}><ListRow verbatimTitle title={row.domain} metadata={row.metadata} trailing={<Symbol name={'icon' in row&&row.icon?row.icon:decision==='Blocked'?foundation.outcome.blocked:foundation.outcome.allowed} tone={'tone' in row?row.tone:decision==='Blocked'?'orange':'green'} size={28}/>} /></ContextMenu>):<ListRow title={query.error??(app&&(!query.value||query.refreshing)?'Loading domain logs…':search.trim()?'No domains match this search':decision==='All'?'No domains saved yet':decision==='Allowed'?'No allowed domains saved yet':'No blocked domains saved yet')} />}
    </Group></QueryContent></View>
  </Screen>;
}
type NetworkRecord={id:string;title:string;subtitle:string;metadata:string;theme?:{title:string;symbol:string;tone:'green'|'orange'|'secondary'}};
function NetworkRow({row}:{row:NetworkRecord}) {
  return <View accessible accessibilityRole="text" testID={`network-row.${row.id}`}
    accessibilityLabel={[row.theme?.title,row.metadata,row.title,row.subtitle].filter(Boolean).map(value=>localized(value!)).join(', ')}
    style={s.record}>
    <View style={s.recordMeta}>
      {row.theme&&<StatusPill {...row.theme}/>}
      <Text verbatim allowFontScaling dynamicTypeRamp="footnote" style={s.recordTime}>{row.metadata}</Text>
    </View>
    <Copy verbatim role="row" color={colors.ink}>{row.title}</Copy>
    <Copy verbatim role="supporting" color={colors.secondaryText}>{row.subtitle}</Copy>
  </View>;
}
export function NetworkScreen() {
  const nav=useReviewNavigation();const {app,session}=useReview(); const run=useAppAction();
  const query=useAppQuery<NetworkRecord[]>({type:"network.query"});
  const [limit,setLimit]=useState(30);
  const count=query.value?.length??0;
  useEffect(()=>setLimit(30),[count]);
  useToolbar({unstable_headerRightItems:()=>[toolbarButton('Clear network activity','trash',()=>Alert.alert('Clear local network activity?','This removes saved network activity entries from this phone. Filtering counts and domain history are unchanged.',[{text:'Cancel',style:'cancel'},{text:'Clear Activity',style:'destructive',onPress:()=>run({type:'logs.clear',kind:'Clear network activity',surface:'activityViewing'})}]),!query.value?.length)]},[query.value?.length??0]);
  return <Screen onRefresh={app?()=>query.refresh():undefined} onEndReached={()=>{if(count>limit)setLimit(Math.min(limit+30,count));}}><SettingsIntro summary="Connection and protection events stay on this device for 7 days. Share them only when you choose to attach a bug report."/>
    <View testID={query.value?"network.loaded":"network.pending"}><Group>{query.value?.length?query.value.slice(0,limit).map(row=><NetworkRow key={row.id} row={row}/>):<ListRow title={query.error??(app&&!query.value?'Loading network activity…':session.logs['Network activity']?'No network activity yet':'Network activity is off')} />}</Group></View>
  </Screen>;
}

type Notice={id:string;displayName:string;noticeText:string;plannedUse:string;sourceURL?:string;licenseTextURL?:string;noticeURL?:string;distributionModeDescription?:string};
type LegalContent={disclaimer:string;sections:{title:string;notices:Notice[]}[]};
export function LegalScreen() {
  const run=useAppAction();
  const [expanded,setExpanded]=useState<string>();
  const [search,setSearch]=useState('');
  const data=useMemo<LegalContent|null>(()=>{try{return JSON.parse(NativeReview.getLegalNotices());}catch{return null;}},[]);
  if(!data)return <Screen><Info title="Legal notices unavailable" description="The local notice catalog could not be read." /></Screen>;
  const sections=data.sections.map(section=>({...section,notices:section.notices.filter(notice=>`${localized(notice.displayName)} ${localized(section.title)} ${localized(notice.noticeText)}`.toLocaleLowerCase().includes(search.toLocaleLowerCase()))})).filter(section=>section.notices.length);
  return <Screen keyboard><SettingsIntro summary="Credits and licenses for the software used in Lava." />
    <Search value={search} onChange={setSearch} label="Search notices" />
    {!sections.length&&<Quiet>No matching notices</Quiet>}
    {sections.map(section=><Section key={section.title} title={section.title}><Group>{section.notices.map(notice=><View key={notice.id}>
      <DisclosureRow title={notice.displayName} expanded={expanded===notice.id} onChange={()=>setExpanded(current=>current===notice.id?undefined:notice.id)} />
      {expanded===notice.id&&<View style={s.expanded}><Copy role="body">{notice.noticeText}</Copy><Copy role="caption" verbatim color={colors.secondaryText}>{[localized(notice.plannedUse),notice.sourceURL&&localizedFormat('Source: %@',notice.sourceURL),notice.distributionModeDescription&&localizedFormat('Use: %@',localized(notice.distributionModeDescription)),notice.licenseTextURL&&localizedFormat('License: %@',notice.licenseTextURL),notice.noticeURL&&localizedFormat('Notice: %@',notice.noticeURL)].filter(Boolean).join('\n')}</Copy></View>}
    </View>)}</Group></Section>)}
    <Section title="Full License Texts"><Group><ListRow action icon="doc.text" title="Full License Texts" onPress={()=>run({type:"native.flow",flow:"licenses"})} /></Group></Section>
    <Copy role="caption" color={colors.secondaryText}>{data.disclaimer}</Copy>
    <Section title="Other Marks"><LavaCard><Copy color={colors.secondaryText}>All other trademarks and service marks are property of their respective owners.</Copy></LavaCard></Section>
  </Screen>;
}
const previewHealthRows=()=>[['Network','Unknown'],['Network path','Available'],['Network changes','0'],['Last network change','None yet'],['Runtime resets','0'],['Last runtime reset','None yet'],['Last resolver','None yet'],['DoH protocol','None yet'],['Data path','DNS-only'],['Last DNS response','None yet'],['DNS response time','None yet'],['Upstream success','0'],['Last success','None yet'],['Upstream failures','0'],['Last failure time','None yet'],['Timeouts','0'],['TCP fallback','0/0'],['DNS smoke probes','0/0'],['Device DNS fallback',localizedFormat('%1$@ activations · %2$@ query fallbacks','0','0/0')],['Cache hit rate','0%'],['Sampled','None yet']];
function Values({rows, metadata=false,pending=false}: {pending?:boolean;rows:readonly (readonly string[])[]; metadata?:boolean}) {
  return <LavaCard><DetailValues rows={rows} metadata={metadata} pending={pending}/></LavaCard>;
}
export function StatsScreen() {
  const healthRows=previewHealthRows();
  const {app,session}=useReview();const sampling=useRef(false);const [busy,setBusy]=useState(false);
  const query=useAppQuery<{sampleNotice?:string;app:string[][];healthSections:{id:string;title:string;rows:{id:string;title:string;value:string}[]}[];tiers:string[][]}>({type:"stats.query"});
  const refresh=async()=>{if(!app||sampling.current)return;sampling.current=true;setBusy(true);try{await query.refresh();}catch(error){Alert.alert('Lava',(error as Error).message);}finally{sampling.current=false;setBusy(false);}};
  const hostname=reviewDNSProviders.find(([name])=>name===session.provider)?.[1].replace('https://','').replace('/dns-query','');
  const selectedResolver=[
    session.provider+' ('+session.transport+')',
    {DoH:'DNS over HTTPS',DoT:'DNS over TLS',DoQ:'DNS over QUIC',IP:'Standard DNS'}[session.transport]??session.transport,
    session.transport==='DoH'?hostname:undefined,
  ].filter(Boolean).map(value=>localized(value!)).join('\n');
  return <Screen><SettingsIntro summary="Check how your connection is working. These local counters contain no website names."/>
    <Section title="App"><Values pending={!!app&&!query.value&&!query.error} rows={app?query.value?.app??[['Version','—'],['Platform','—']]:[['Version','1.5.0'],['Platform','iOS 26.5']]} /></Section>
    <Section title="DNS tiers" footer="Configured settings. With VPN chaining, tiers 1 and 2 require DNS fallback and a split tunnel."><Values metadata pending={!!app&&!query.value&&!query.error} rows={app?query.value?.tiers??[['T0 · VPN chaining','—'],['1 · Primary DNS','—'],['2 · Fallback DNS','—'],['S · System DNS','—']]:[
      ['T0 · VPN chaining',[localized('Off'),localized('Saved configuration unavailable')].join('\n')],
      ['1 · Primary DNS',session.deviceDNS?'Device DNS':selectedResolver],
      ['2 · Fallback DNS',[!session.fallback?localized('Off'):undefined,session.deviceDNS?selectedResolver:localized('Device DNS')].filter(Boolean).join('\n')],
      ['S · System DNS',[localized('Off'),localized('Profile not in use')].join('\n')],
    ]} /></Section>
    {(query.value?.healthSections??[
      {id:'network',title:'Network & runtime',rows:[...healthRows.slice(0,6),healthRows[8]!].map(([title,value])=>({id:title!,title:title!,value:app?'—':value!}))},
      {id:'performance',title:'Performance & sampling',rows:[...healthRows.slice(6,8),...healthRows.slice(9)].map(([title,value])=>({id:title!,title:title!,value:app?'—':value!}))},
    ]).map(section=><Section key={section.id} title={section.title} footer={section.id==='performance'?'Current observations. No domain names.':undefined}>
      <Values metadata pending={!!app&&!query.value&&!query.error} rows={section.rows.map(row=>[row.title,row.value,'',row.id])}/>
      {section.id==='performance'&&<><ListRow action title="Refresh sample" disabled={busy} leading={busy?<ActivityIndicator/>:<Symbol name="arrow.clockwise"/>} onPress={()=>void refresh()}/>{(query.error||query.value?.sampleNotice)&&<Quiet>{query.error||query.value?.sampleNotice}</Quiet>}</>}
    </Section>)}
  </Screen>;
}
