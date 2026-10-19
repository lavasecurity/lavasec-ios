import {Copy,Section,Group,Info,Search,SystemButton,BufferedInput} from '../ui';
import {FlowConsentToggle} from '../FlowConsentToggle';
import {useState,type ReactNode} from 'react';
import {Pressable,ScrollView,StyleSheet,View,type LayoutChangeEvent,type ColorValue} from 'react-native';
import {LavaActionButton,LavaCard,LavaRowLabel} from '../../index';
import {foundation} from '../../foundation';
import {colors} from '../../colors';
import type {QAAction,QAState,QADetail,QARow} from './contract';

export type QAPort={
  send:(action:QAAction)=>void;
  configuration:ReactNode;
  glyph:(name:string,destructive?:boolean,kind?:'row'|'detail')=>ReactNode;
  fieldBackground:ColorValue;
  labelColor?:ColorValue;
  searchField?:(props:{label:string;value:string;onChange:(value:string)=>void})=>ReactNode;
  onLayout?:(event:LayoutChangeEvent)=>void;
  localize:(text:string)=>string;
  textScale:number;
};
function QAPage({children,port,spacing=18}:{children:ReactNode;port:QAPort;spacing?:number}){
  return <ScrollView testID="qa.scroll" onLayout={port.onLayout} style={styles.screen} contentInsetAdjustmentBehavior="automatic"
    keyboardDismissMode="interactive" keyboardShouldPersistTaps="handled" showsVerticalScrollIndicator
    contentContainerStyle={[styles.content,{gap:spacing}]}>{children}</ScrollView>;
}
/** The retained native condensed anatomy includes an empty metadata line. Use
 * the shared label owner, preserving that baseline height and its 24pt glyph. */
function QARowView({row,port,onPress,leading}:{row:QARow;port:QAPort;onPress?:()=>void;leading?:ReactNode}){
  const body=<View style={styles.row}>
    <View style={styles.glyph}>{leading??port.glyph(row.icon??'checklist',row.destructive)}</View>
    <View style={styles.label}><LavaRowLabel title={row.title} summary={row.subtitle} titleNumberOfLines={2} verbatimTitle verbatimSummary>
      <View style={{minHeight:20}}/>
    </LavaRowLabel></View><View style={{minWidth:6}}/>
  </View>;
  return onPress?<Pressable testID={`qa.${row.id}`} disabled={row.disabled} onPress={onPress} accessibilityRole="button"
    accessibilityLabel={[row.title,row.subtitle].filter(Boolean).join(', ')} accessibilityState={{disabled:!!row.disabled}}>{body}</Pressable>:body;
}
function QAField({value,onChangeText,placeholder,port,keyboardType='url',multiline=false,revision=0}:{value:string;onChangeText:(value:string)=>void;placeholder:string;port:QAPort;keyboardType?:'url'|'numbers-and-punctuation';multiline?:boolean;revision?:number}){
  return <BufferedInput accessibilityLabel={port.localize(placeholder)} placeholder={port.localize(placeholder)} value={value}
    resetRevision={revision} onChangeText={onChangeText} autoCorrect={false} autoCapitalize="none" keyboardType={multiline?'default':keyboardType}
    multiline={multiline} grows={multiline} allowFontScaling={false}
    style={{fontSize:17*port.textScale,fontFamily:multiline?undefined:'Menlo',color:colors.primaryText,
      padding:multiline?6:12,minHeight:multiline?66*port.textScale:46*port.textScale,
      maxHeight:multiline?132*port.textScale:undefined,backgroundColor:multiline?colors.cardBackground:port.fieldBackground,
      borderRadius:multiline?5:12,borderColor:multiline?colors.separator:undefined,borderWidth:multiline?StyleSheet.hairlineWidth:0}}/>;
}
export function QAScreen({state,port}:{state:QAState;port:QAPort}){
  const [search,setSearch]=useState(state.search);
  const searchProps={label:'Search Device QA',value:search,onChange:(value:string)=>{setSearch(value);port.send({action:'search',value});}};
  return <QAPage port={port} spacing={22}>
    <Info title="Test Lava on this device" description="Prepare test settings, check app features, and run guided network checks." icon="checklist"/>
    {port.searchField?port.searchField(searchProps):<Search {...searchProps}/>}
    {state.sections.map(section=><Section key={section.title} title={section.title}><Group dividerInset={50}>{section.rows.map(row=><QARowView key={row.id} row={row} port={port} onPress={()=>port.send({action:'row',row:row.id})}/>)}</Group></Section>)}
    {!state.sections.length&&!state.formsVisible&&<View style={styles.empty}><Copy role="row">No matching checks</Copy></View>}
    <View testID="qa.forms" style={state.formsVisible?undefined:{height:0,overflow:'hidden',opacity:0}} pointerEvents={state.formsVisible?'auto':'none'} accessibilityElementsHidden={!state.formsVisible}>
      <View style={{gap:22}}>
        <Section title="WireGuard configuration" footer="Stage a configuration for the next test connection. Secrets remain in this build's own store."><LavaCard><View style={{gap:14}}>
          <View style={styles.detailRow}>{port.glyph('doc.on.clipboard',false,'detail')}<View style={{flex:1}}><LavaRowLabel titleRole="cardTitle" title="Stage upstream from .conf" summary="Paste [Interface] + [Peer]; commits one rotation"/></View></View>
          {port.configuration}<SystemButton testID="qa.stage" eventID={state.id} title="Stage upstream" prominent disabled={state.staging||!state.hasConfiguration} onPress={()=>port.send({action:'stage'})}/>
        </View></LavaCard></Section>
        <Section title="Custom Probe Suffix" footer="Use this for LAN or sslip.io physical-device checks."><LavaCard><View style={{gap:12}}>
          <QAField placeholder="192-168-1-20.sslip.io" value={state.probeSuffix} onChangeText={value=>port.send({action:'suffix',value})} port={port}/>
          <LavaActionButton title="Apply Custom QA Probes" role="panel" onPress={()=>port.send({action:'probes.apply'})}/>
        </View></LavaCard></Section>
        <Section title="DNS Leak Canary" footer="Physical-path leak (#8 positive control). Fires ONE cleartext DNS query to this resolver at the next chained connect — watch for it in your off-device capture (Pi-hole log / tcpdump). Arm shows the --canary-nonce to pass the analyzer."><LavaCard><View style={{gap:12}}>
          <QAField placeholder="resolver IP (e.g. 192.168.11.2)" value={state.canaryIP} onChangeText={value=>port.send({action:'canaryIP',value})} keyboardType="numbers-and-punctuation" port={port}/>
          <View style={styles.canaryButtons}><View style={{flex:1}}><LavaActionButton title="Arm Leak Canary" role="panel" onPress={()=>port.send({action:'canary.arm'})}/></View><SystemButton testID="qa.disarm" eventID={state.id} title="Disarm" destructive onPress={()=>port.send({action:'canary.disarm'})}/></View>
        </View></LavaCard></Section>
      </View>
    </View>
  </QAPage>;
}
export function QADetailScreen({state,port}:{state:QADetail;port:QAPort}){
  if(state.kind==='result')return <QAPage port={port}><Info title="QA result" description={state.message} icon="info.circle"/><Copy role="supporting">Applying settings does not verify protection or complete a network check.</Copy></QAPage>;
  if(state.kind==='suite')return <QAPage port={port}><Info title={state.name??''} description="Open a check, apply its settings, and record the observed outcome. Results here are reported by the tester and last for this session." icon="checklist"/>
    <Section title={state.count??''}><Group>{state.rows?.map(row=><QARowView key={row.id} row={row} port={port} onPress={()=>port.send({action:'scenario',row:row.id})}/>)}</Group></Section>
  </QAPage>;
  return <QAPage port={port}>
    <Info title="Guided network check" description="Lava prepares probes and settings. You must create the network condition and verify the active tunnel, downloads, and probes." icon="checklist"/>
    <LavaActionButton title="Apply test settings" role="panel" onPress={()=>port.send({action:'prepare'})}/>
    <Section title="Procedure"><Group>{state.steps?.map((step,index)=><QARowView key={index} row={{id:String(index),title:step,subtitle:''}} port={port}
      leading={<Copy role="row" verbatim>{String(index+1)}</Copy>}/>)}</Group></Section>
    <Info title="Expected result" description={state.expected} icon="info.circle"/>
    <LavaActionButton title="Open Hosted QA Site" role="panel" icon="browse" onPress={()=>port.send({action:'hosted'})}/>
    <FlowConsentToggle testID="qa.verified" title="I verified the setup and positive control" value={!!state.verified} labelColor={port.labelColor??colors.primaryText} disabled={!state.prepared||!state.configurationMatches} onChange={value=>port.send({action:'verified',value})}/>
    <Copy role="supporting">Confirm the active tunnel uses these settings, selected rules have finished loading, and the allowed probe works. A timeout alone does not prove blocking.</Copy>
    <QAField placeholder="Observed result and evidence" multiline value={state.evidence??''} revision={state.revision??0} onChangeText={value=>port.send({action:'evidence',value})} port={port}/>
    <View style={styles.resultButtons}>{(['Passed','Failed','Blocked'] as const).map(value=><SystemButton key={value} testID={`qa.record.${value}`} eventID={state.id} title={value} disabled={value==='Blocked'?!state.canBlock:!state.canRecord} onPress={()=>port.send({action:'record',value})}/>)}</View>
    {!!state.result&&<Copy role="supporting" verbatim>{state.result}</Copy>}
    {state.prepared&&!state.configurationMatches&&<Copy role="supporting">Settings changed. Apply the test settings again before recording a result.</Copy>}
  </QAPage>;
}
const styles=StyleSheet.create({
  screen:{flex:1,backgroundColor:colors.groupedBackground},content:{paddingHorizontal:foundation.space.screenHorizontal,paddingTop:foundation.space.screenTop,paddingBottom:foundation.space.screenBottom},
  row:{minHeight:foundation.row.standard,paddingHorizontal:foundation.row.horizontalInset,flexDirection:'row',alignItems:'center',gap:10},
  glyph:{width:24,paddingVertical:foundation.row.verticalInset,alignItems:'center'},label:{flex:1,paddingVertical:foundation.row.verticalInset},
  empty:{minHeight:foundation.row.standard,paddingHorizontal:foundation.row.horizontalInset,paddingVertical:foundation.row.verticalInset,justifyContent:'center'},detailRow:{flexDirection:'row',alignItems:'flex-start',gap:12},canaryButtons:{flexDirection:'row',alignItems:'center',gap:12},resultButtons:{flexDirection:'row',flexWrap:'wrap',gap:8},
});
