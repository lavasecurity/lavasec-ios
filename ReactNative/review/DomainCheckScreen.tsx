import {useEffect,useRef,useState} from 'react';
import {useIsFocused} from '@react-navigation/native';
import {AppState,Keyboard,View} from 'react-native';
import {Alert,isPresentationCancellation,localizedFormat} from '../app/presentation';
import {usePresentationAuthority} from '../app/use-presentation-readiness';
import {useReview} from './ReviewContext';
import {useReviewNavigation,previewNotice} from './navigation';
import {Copy,Screen,Section,Symbol} from './primitives';
import {Group,ListRow,Quiet} from './scaffold';
import {FormField,FormPanel} from './form-scaffold';
import {StorySurface} from './story-scaffold';
import {LavaActionButton} from '../src';
import {colors} from '../src/colors';
import {foundation} from '../src/foundation';
import {usePlusEntry} from './plus-entry';
import type {AppCommand} from '../app/contract';

type CheckedDomain={status:'checked';domain:string;decision:'allow'|'block';reason:string;filterID:string;filterName:string;filterEmoji:string;
  proof:string;ignoredURLParts:boolean;repairedScheme:boolean;alreadyAllowed:boolean;alreadyBlocked:boolean;allowedExceptions:string[];protection?:'off'|'paused'};
type DomainCheckOutcome='allowed'|'allowedException'|'blocked';
type DomainCheckAction=Extract<AppCommand,{type:'domainCheck.stage'}>['decision'];
export type DomainCheckResult=CheckedDomain|{status:'invalid';message:string}|{status:'unavailable';domain:string;ignoredURLParts?:boolean;repairedScheme?:boolean};
// The visit identifier is a lifecycle marker; native-generated proofs authorize mutations.
function visitID(){return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g,char=>{
  const value=Math.floor(Math.random()*16);return (char==='x'?value:(value&3)|8).toString(16);
});}

export function DomainCheckScreen(){
  const {app,live}=useReview();const nav=useReviewNavigation();const focused=useIsFocused();
  const authoritative=usePresentationAuthority(app);const visit=useRef(visitID());
  const upgrade=usePlusEntry();
  const [input,setInput]=useState('');
  const [result,setResult]=useState<DomainCheckResult>();const resultScope=useRef<string|undefined>(undefined);const [message,setMessage]=useState('');
  const [busy,setBusy]=useState(false);const [changing,setChanging]=useState(false);
  const [fresh,setFresh]=useState(false);const [resume,setResume]=useState(0);
  const active=useRef(true);const mounted=useRef(true);const requestRevision=useRef(0);
  const submitted=useRef('');const mutationPending=useRef(false);const currentInput=useRef('');
  // Only filter content and its owner retire the painted verdict. Diagnostics,
  // authentication grants and background covers do not change the checked rules.
  const nextScope=JSON.stringify([live?.security?.ownerRevision,live?.domainCheckRevision,live?.session.activeFilterID,
    live?.savedDraft?.blocked,live?.savedDraft?.allowed,live?.session.savedBlocklists,live?.filterPreparationPresented,live?.protection.paused]);
  const currentScope=useRef(nextScope);if(live)currentScope.current=nextScope;const scope=currentScope.current;
  const readRevision=useRef(live?.security?.readRevision);readRevision.current=live?.security?.readRevision;
  const inFlight=useRef<{request:number;scope:string;readRevision?:number;refresh:boolean}|undefined>(undefined);
  const mayRead=()=>active.current&&AppState.currentState==='active'&&(!app?.getSnapshot||!!app.getSnapshot().snapshot);
  const check=async(text:string,refresh=false)=>{
    if(!text.trim()){Keyboard.dismiss();return;}
    if(!app){previewNotice();return;}if(!mayRead()||mutationPending.current)return;
    // An explicit tap can replace a quiet refresh; repeated explicit submissions stay blocked.
    if(!refresh&&inFlight.current&&!inFlight.current.refresh)return;
    // A new authentication grant supersedes a query pinned to an older grant,
    // even when the filter content and painted verdict remain unchanged.
    if(refresh&&inFlight.current?.scope===currentScope.current&&inFlight.current.readRevision===readRevision.current)return;
    if(!refresh)Keyboard.dismiss();
    // A repeat check renews authority without removing the accepted result's native views.
    // Editing the input or changing the filter still retires that result immediately.
    if(!refresh&&submitted.current!==text)setResult(undefined);
    submitted.current=text;const request=++requestRevision.current;const startedScope=currentScope.current;
    inFlight.current={request,scope:startedScope,readRevision:readRevision.current,refresh};setFresh(false);
    setMessage('');setBusy(!refresh);
    try{const value=await app.command<DomainCheckResult>({type:'domainCheck.query',visit:visit.current,input:text,refresh});
      if(mayRead()&&request===requestRevision.current&&startedScope===currentScope.current){resultScope.current=startedScope;setResult(value);setFresh(true);}
    }catch(error){if(mayRead()&&request===requestRevision.current&&!isPresentationCancellation((error as Error).message))setMessage((error as Error).message);}
    finally{if(inFlight.current?.request===request)inFlight.current=undefined;if(active.current&&request===requestRevision.current)setBusy(false);}
  };
  useEffect(()=>{mounted.current=true;return()=>{mounted.current=false;};},[]);
  useEffect(()=>{
    active.current=focused;
    if(!focused){++requestRevision.current;inFlight.current=undefined;setFresh(false);setBusy(false);return;}
    if(!authoritative){++requestRevision.current;inFlight.current=undefined;setFresh(false);setBusy(false);return;}
    if(submitted.current&&!mutationPending.current)void check(submitted.current,true);
  },[focused,authoritative,scope,live?.security?.readRevision,resume]);
  useEffect(()=>{
    const listener=AppState.addEventListener('change',state=>{
      if(state==='background'){++requestRevision.current;inFlight.current=undefined;setFresh(false);setBusy(false);
        void app?.command({type:'domainCheck.cancel',visit:visit.current}).catch(()=>{});}
      else if(state==='active')setResume(value=>value+1);
    });
    return()=>{active.current=false;++requestRevision.current;listener.remove();
      void app?.command({type:'domainCheck.cancel',visit:visit.current}).catch(()=>{});};
  },[app]);
  const edit=(text:string)=>{if(text===currentInput.current)return;currentInput.current=text;++requestRevision.current;inFlight.current=undefined;submitted.current='';setInput(text);setResult(undefined);setFresh(false);setMessage('');setBusy(false);};
  const visibleResult=resultScope.current===scope?result:undefined;
  const checked=visibleResult?.status==='checked'&&visibleResult.filterID===live?.session.activeFilterID?visibleResult:undefined;
  const outcome:DomainCheckOutcome=checked?.decision==='block'?'blocked':checked?.reason==='localAllowlist'?'allowedException':'allowed';
  const hasException=!!checked&&(checked.alreadyAllowed||checked.allowedExceptions.length>0);
  const stage=async(decision:DomainCheckAction)=>{
    if(!app||!checked||!fresh||!mayRead()||mutationPending.current||inFlight.current)return;
    mutationPending.current=true;setChanging(true);Keyboard.dismiss();
    try{const staged=await app.command<{id:string;standaloneReview:string}|{rejection:{title:string;message:string;limitReached?:boolean}}>(
      {type:'domainCheck.stage',visit:visit.current,proof:checked.proof,decision});
      if('rejection' in staged){if(!mayRead())return;
        if(staged.rejection.limitReached&&(decision==='allowed'||decision==='blocked'))upgrade(decision==='allowed'?'allowedDomains':'blockedDomains',async()=>{
          const refreshed=await app.command<DomainCheckResult>({type:'domainCheck.query',visit:visit.current,input:checked.domain});
          if(refreshed.status!=='checked'||refreshed.filterID!==checked.filterID){Alert.alert('Lava','The filter changed. Check the domain again.');return;}
          const retry=await app.command<{id:string;standaloneReview:string}|{rejection:{title:string;message:string}}>({type:'domainCheck.stage',visit:visit.current,proof:refreshed.proof,decision});
          if('rejection' in retry){Alert.alert(retry.rejection.title,retry.rejection.message);return;}
          return {name:'Review',params:retry};
        });else Alert.alert(staged.rejection.title,staged.rejection.message);return;}
      if(mayRead())nav.navigate('Review',staged);
      else await app.command({type:'domains.cancel',token:staged.standaloneReview});
    }catch(error){if(mayRead()&&!isPresentationCancellation((error as Error).message))setMessage((error as Error).message);}
    finally{mutationPending.current=false;if(mounted.current)setChanging(false);}
  };
  return <Screen keyboard>
    <FormPanel><FormField title="Domain or URL" testID="domain-check.input" value={input}
      placeholder="example.com" verbatimPlaceholder autoCapitalize="none" autoCorrect={false} textContentType="URL" keyboardType="url" spellCheck={false} smartInsertDelete={false} clearButtonMode="always"
      editable={!changing} onChangeText={edit} onSubmitEditing={event=>void check(event.nativeEvent.text)}/>
    </FormPanel>
    <LavaActionButton title="Check" disabled={changing||busy||!input.trim()} busy={busy} onPress={()=>void check(input)}/>
    {checked&&<StorySurface tone="green" testID="domain-check.result">
      <View style={{flexDirection:'row',alignItems:'center',gap:foundation.space.sm}}>
        <Symbol name={checked.decision==='block'?foundation.outcome.blocked:foundation.outcome.allowed}
          size={foundation.type.heading.fontSize} tone={checked.decision==='block'?'accentOrange':'green'}/>
        <View style={{flex:1}}><Copy role="heading">{outcome==='blocked'?'Blocked':outcome==='allowedException'?'Allowed exception':'Allowed'}</Copy></View>
      </View>
      <View style={{gap:foundation.space.sm}}>
        <Copy testID="domain-check.domain" verbatim role="body" color={colors.secondaryText}>{localizedFormat('Domain checked: %@',checked.domain)}</Copy>
        <Copy testID="domain-check.filter" verbatim role="body" color={colors.secondaryText}>{localizedFormat('Current filter: %@',`${checked.filterEmoji} ${checked.filterName}`)}</Copy>
      </View>
    </StorySurface>}
    {checked?.decision==='allow'&&<Quiet>An allowed result does not guarantee the site is safe.</Quiet>}
    {checked?.reason==='localAllowlist'&&<Quiet>An allowed-domain rule lets this domain through.</Quiet>}
    {checked?.protection&&<Quiet>{checked.protection==='paused'?'Lava is paused':'Lava is off'}</Quiet>}
    {visibleResult?.status==='invalid'&&<Copy color={colors.errorText}>{visibleResult.message}</Copy>}
    {visibleResult?.status==='unavailable'&&<Quiet>Cannot check this filter yet. Open Filters to review its preparation.</Quiet>}
    {!!message&&<Copy color={colors.errorText}>{message}</Copy>}
    {checked&&<Section title="Actions"><Group><ListRow title={hasException?'Remove from allowed exception':'Allow this'} icon={foundation.outcome.allowedOutline} interactionDisabled={!fresh||!authoritative} disabled={changing||busy||!hasException&&checked.reason==='threatGuardrail'} onPress={()=>void stage(hasException?'removeAllowedException':'allowed')}/>
      <ListRow title={checked.alreadyBlocked?'Remove from blocked domains':'Block this'} icon={foundation.outcome.blockedOutline} interactionDisabled={!fresh||!authoritative} disabled={changing||busy} onPress={()=>void stage(checked.alreadyBlocked?'removeBlockedDomain':'blocked')}/></Group></Section>}
    {checked?.reason==='threatGuardrail'&&<Quiet>Some dangerous domains cannot be allowed.</Quiet>}
  </Screen>;
}
