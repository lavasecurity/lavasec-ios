import {Copy,Section,Symbol,Group,Info,ListRow,Panel,FlowSheet,FormField,FormPanel,FormParagraph} from '../ui';
import {useEffect,useRef,useState} from 'react';
import {ActivityIndicator,Pressable,View,useWindowDimensions,type ColorValue} from 'react-native';
import {LavaActionButton} from '../../index';
import {colors} from '../../colors';
import {foundation} from '../../foundation';
import {Text,localized} from '../../../app/presentation';
import type {ImportAction,ImportPort,ImportReview,ImportState} from './contract';
import {StagedFlowTransition} from '../StagedFlowTransition';

const provenance='Check who shared this filter and review its contents carefully before importing. Shared filters aren’t reviewed by Lava.';
const replacementDescription='The selected filter keeps its name. Review the content changes below.';

/** Shared import pages arrange the established form/list atoms. The typed port
 * owns platform interactions, parsing, consent and transactions. */
export type ImportFlowProps={state:ImportState;port:ImportPort;labelColor?:ColorValue};
export function ImportFlow({state,port,labelColor=colors.primaryText}:ImportFlowProps){
  return <StagedFlowTransition stageID={state.stage} direction={state.direction}><ImportFlowBody state={state} port={port} labelColor={labelColor}/></StagedFlowTransition>;
}
function ImportFlowBody({state,port,labelColor}:{state:ImportState;port:ImportPort;labelColor:ColorValue}){
  const window=useWindowDimensions();
  // Fitting a short portrait utility sheet must not change its size class and
  // move the native-style pinned footer into the scroll body.
  const compactHeight=window.width>window.height;
  const [code,setCode]=useState(state.code);const [pending,setPending]=useState(false);
  const busy=state.stage==='applying'||pending;
  const current=useRef(state);current.current=state;
  const mounted=useRef(true);const commandFlight=useRef(false);
  useEffect(()=>{mounted.current=true;return()=>{mounted.current=false;};},[]);
  useEffect(()=>{setCode(state.code);},[state.stageID]);
  const run=async(action:ImportAction)=>{
    if(commandFlight.current||busy)return;
    commandFlight.current=true;setPending(true);
    try{await port.command(action);}finally{commandFlight.current=false;if(mounted.current)setPending(false);}
  };
  const button=(title:string,action:ImportAction,disabled=false,secondary=false)=><LavaActionButton title={title} role={secondary?'secondary':'primary'} disabled={disabled||busy} onPress={()=>void run(action)}/>;
  if(state.stage==='applying')return <View testID="import.stage.applying" style={{flex:1,alignItems:'center',justifyContent:'center',gap:16,backgroundColor:colors.groupedBackground}}>
    <ActivityIndicator size="large"/><FormParagraph>Applying filter…</FormParagraph>
  </View>;
  if(state.stage==='completed')return <FlowSheet centered compactHeight={compactHeight} onNaturalSize={port.measure} footer={button('Done',{type:'import.done'})}>
    <View testID="import.stage.completed" style={{alignItems:'center',gap:foundation.space.xl}}>
      <Symbol name="checkmark.circle.fill" size={66} pointSize={56} responsive={false}/><Copy role="heading" center weight="700" accessibilityRole="header">Filter imported</Copy>
      <FormParagraph textRole="body" verbatim style={{textAlign:'center',color:colors.secondaryText}}>{state.completed?.message??''}</FormParagraph>
      {!!state.completed?.unavailable&&<FormParagraph textRole="note" verbatim style={{textAlign:'center'}}>{state.completed.unavailable}</FormParagraph>}
    </View>
  </FlowSheet>;
  const review=state.review;
  const footer=state.stage==='enterCode'?button('Continue',{type:'import.continue',value:code},code.trim().length===0)
    :state.stage==='confirm'?<View style={{gap:foundation.space.sm}}>
      {button(review?.canImport?'Add as a new filter':'Nothing to import',{type:'import.add'},state.checkingCatalog||state.catalogCheckFailed||!review?.canImport)}
      {!state.checkingCatalog&&!state.catalogCheckFailed&&review?.canImport&&button('Replace a filter instead',{type:'import.targets'},false,true)}
    </View>:state.stage==='reviewReplacement'?button('Replace a filter',{type:'import.replace'}):undefined;
  return <FlowSheet compactHeight={compactHeight} onNaturalSize={port.measure} footer={footer}>
    <View testID={`import.stage.${state.stage}`} style={{gap:state.stage==='confirm'||state.stage==='reviewReplacement'?16:14}}>
      {state.stage==='chooseMethod'&&<>
        <Panel accent={colors.lavaOrange}><FormParagraph style={{color:colors.primaryText}}>{provenance}</FormParagraph></Panel>
        <Group><Method title="Scan a QR code" symbol="qrcode.viewfinder" onPress={()=>void run({type:'import.method',method:'scan'})} disabled={busy}/>
          <Method title="Import from Photo" symbol="photo.on.rectangle" onPress={()=>void run({type:'import.method',method:'photo'})} disabled={busy||state.decodingPhoto} dimmed={state.decodingPhoto} hint="Use a saved card someone sent you"/>
          <Method title="Enter a code" symbol="character.cursor.ibeam" onPress={()=>void run({type:'import.method',method:'code'})} disabled={busy}/></Group>
      </>}
      {state.stage==='enterCode'&&<>
        <Info title="Enter a setup code" description={'Paste the setup code someone shared with you. It usually starts with "LF1-".'} icon="character.cursor.ibeam"/>
        <FormField title="Setup code" placeholder="LF1-…" verbatimPlaceholder value={code} resetRevision={0} multiline minHeight={180} editable={!busy} onChangeText={value=>{setCode(value);void port.command({type:'import.code',value});}} style={{textAlignVertical:'top'}}/>
        {!!state.error&&<FormParagraph textRole="note" verbatim style={{color:colors.errorText}}>{state.error}</FormParagraph>}
      </>}
      {state.stage==='scanCode'&&(state.cameraDenied?<FormPanel>
        <View style={{flexDirection:'row',gap:8,alignItems:'center'}}><Symbol name="video.slash.fill" tone="primary"/><Copy role="section" color={colors.ink}>Camera access is off</Copy></View>
        <FormParagraph>Allow camera access in Settings to scan a QR code — or tap back and enter the code instead.</FormParagraph>
        {button('Open the Settings app',{type:'import.cameraSettings'})}
      </FormPanel>:<>
        <View style={{height:320,borderRadius:18,borderCurve:'continuous',overflow:'hidden'}}>{port.scanner}<View pointerEvents="none" style={{position:'absolute',top:0,right:0,bottom:0,left:0,borderWidth:2,borderRadius:18,borderCurve:'continuous',borderColor:colors.safeGreen,opacity:0.6}}/></View>
        <FormParagraph>Hold the shared QR code inside the frame.</FormParagraph>
        {!!state.error&&<FormParagraph textRole="note" verbatim style={{color:colors.errorText}}>{state.error}</FormParagraph>}
      </>)}
      {state.stage==='confirm'&&<>
        <FormParagraph style={{color:colors.lavaOrangeText}}>{provenance}</FormParagraph>
        {state.checkingCatalog?<View style={{flexDirection:'row',gap:8,alignItems:'center'}}><ActivityIndicator/><FormParagraph textRole="body">Checking available lists…</FormParagraph></View>
          :state.catalogCheckFailed?<><FormParagraph textRole="note">Couldn’t check available lists. Try again when you’re online.</FormParagraph>{button('Try again',{type:'import.retry'},false,true)}</>
          :review&&<ReviewContents review={review} onUpgrade={()=>void run({type:'import.upgrade'})}/>}
      </>}
      {state.stage==='chooseReplace'&&<>
        <Info title="Replace which filter?" description={replacementDescription} icon="arrow.triangle.2.circlepath"/>
        <Section title="Your filters"><Group>{state.targets?.map(target=><ListRow key={target.id} title={target.name} verbatimTitle subtitle={target.summary}
          leading={<Symbol name="line.3.horizontal.decrease.circle" tone={target.locked?'secondary':'green'} size={foundation.control.glyphSlot} pointSize={foundation.control.glyph}/>}
          trailingRole="disclosure" trailing={<Symbol name={target.locked?'lock.fill':'chevron.right'} tone="secondary" size={foundation.row.disclosureWidth} height={target.locked?41/3:38/3} pointSize={foundation.row.disclosureWidth}/>}
          disabled={busy} onPress={()=>void run({type:'import.target',target:target.id})}/>)}</Group></Section>
      </>}
      {state.stage==='reviewReplacement'&&state.replacement&&<>
        <Info title="Review import" description={replacementDescription} icon="arrow.triangle.2.circlepath"/>
        <Copy role="section" color={labelColor} verbatim>{state.replacement.name}</Copy><FormParagraph textRole="note" verbatim>{state.replacement.removed}</FormParagraph>
        {state.replacement.groups.filter(group=>group.removed.length||group.added.length).map(group=><Section key={group.title} title={group.title}><View style={{gap:8}}>
          {!!group.removed.length&&<><Copy role="row" weight="600" color={labelColor}>Removed</Copy><Text verbatim selectable style={{fontSize:17,color:labelColor}}>{group.removed.join('\n')}</Text></>}
          {!!group.added.length&&<><Copy role="row" weight="600" color={labelColor}>Added</Copy><Text verbatim selectable style={{fontSize:17,color:labelColor}}>{group.added.join('\n')}</Text></>}
        </View></Section>)}
      </>}
    </View>
  </FlowSheet>;
}

function Method({title,symbol,onPress,disabled,dimmed=false,hint}:{title:string;symbol:string;onPress:()=>void;disabled:boolean;dimmed?:boolean;hint?:string}){
  // The system photo picker dims its complete label while decoding. Keep the
  // canonical row paint instead of changing only its title/icon to secondary.
  return <Pressable accessibilityRole="button" accessibilityLabel={localized(title)} accessibilityHint={hint?localized(hint):undefined} accessibilityState={{disabled}} disabled={disabled} onPress={onPress} style={{opacity:dimmed?0.55:1}}>
    {/* Native's unframed 12pt regular chevron has a 12⅔pt natural height. */}
    <ListRow title={title} icon={symbol} trailingRole="disclosure" trailing={<Symbol name="chevron.right" tone="secondary" size={foundation.row.disclosureWidth} height={38/3} pointSize={foundation.row.disclosureWidth}/>}/>
  </Pressable>;
}
function ReviewContents({review,onUpgrade}:{review:ImportReview;onUpgrade:()=>void}){
  return <>
    <Section title="Lava blocks these"><Group>{review.blocked.length?review.blocked.map(row=><ListRow key={row.id} title={row.title} verbatimTitle={row.verbatim}
      subtitle={row.metadata} outcome="blocked" trailing={<View style={{width:44}}/>}/>):<ListRow title="Nothing to import"/>}</Group></Section>
    <Section title="Lava lets these through"><Group>{review.allowed===null?<ListRow title="Not included in this shared filter"/>:review.allowed.length?review.allowed.map(domain=><ListRow key={domain} title={domain} verbatimTitle subtitle="Single domain" outcome="allowed" trailing={<View style={{width:44}}/>}/>):<ListRow title="No allowed exceptions"/>}</Group></Section>
    {!!review.allowed?.length&&<FormParagraph>Allowed exceptions include subdomains and can let blocked sites through. Review every entry.</FormParagraph>}
    {review.showUpgrade&&<><Banner title="Use Lava Plus for full import" symbol="plus.circle.fill" onPress={onUpgrade} green/>
      {review.upgradeRows.map((title,index)=><ListRow key={index} title={title} verbatimTitle subtitle="Not imported on this device" trailing={<View style={{width:44}}/>} onPress={onUpgrade}/>)}</>}
    {!!review.warnings.length&&<Section title="Not imported on this device"><View style={{gap:10}}>{review.warnings.map((warning,index)=>warning.quiet?<FormParagraph key={index} textRole="note" verbatim>{warning.message}</FormParagraph>
      :<Banner key={index} title={warning.message} symbol="exclamationmark.triangle.fill"/>)}</View></Section>}
  </>;
}

// Counterpart of LavaOverviewBannerRow, reused by upgrade and dropped-entry
// notices so their wrapping, type and minimum row treatment remain identical.
function Banner({title,symbol,onPress,green=false}:{title:string;symbol:string;onPress?:()=>void;green?:boolean}){
  const content=<><Symbol name={symbol} size={28} pointSize={15} weight="semibold" tone={green?'green':'orange'}/><View style={{flex:1}}><Copy role="supporting" color={colors.primaryText}>{title}</Copy></View></>;
  const style={minHeight:50,flexDirection:'row' as const,alignItems:'center' as const,gap:10,paddingHorizontal:14,paddingVertical:10,borderRadius:16,borderCurve:'continuous' as const,backgroundColor:green?colors.softGreen:colors.lavaOrangeSoft};
  return onPress?<Pressable accessibilityRole="button" accessibilityLabel={localized(title)} onPress={onPress} style={style}>{content}</Pressable>:<View style={style}>{content}</View>;
}
