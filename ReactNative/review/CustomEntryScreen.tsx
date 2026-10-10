import {useEffect,useLayoutEffect,useRef,useState,useSyncExternalStore} from 'react';
import {useRoute,useIsFocused,usePreventRemove,type RouteProp} from '@react-navigation/native';
import {AppState,Keyboard,View} from 'react-native';
import {LavaActionButton} from '../src';
import {colors} from '../src/colors';
import {foundation} from '../src/foundation';
import {domainReviewPrivacyScope,mayInteractWithPresentation} from '../app/read-cache';
import {usePresentationReadiness} from '../app/use-presentation-readiness';
import {LiveRenderBoundary,useReview} from './ReviewContext';
import {useReviewNavigation,type ReviewRoutes} from './navigation';
import {Copy} from './primitives';
import {Group,Info,InputRow,ListRow,Sheet,nativeInlineHeader,toolbarButton,useToolbar} from './scaffold';
import {usePlusEntry} from './plus-entry';
import {FormField,FormPanel,FormDivider} from './form-scaffold';
import {PresentationCover} from './PresentationCover';

const noSubscribe=()=>()=>{};
export function CustomEntryRoute(){
  const {app}=useReview();
  const interactive=useSyncExternalStore(app?.subscribe??noSubscribe,()=>mayInteractWithPresentation(app));
  usePreventRemove(!!app&&!interactive,()=>{});
  // The draft token belongs to this route. Privacy transitions conceal fields
  // without firing removal cleanup or losing unfinished input.
  return <LiveRenderBoundary component={CustomEntryScreen} retainBody directScrollRoot/>;
}

// DNS and source entry share the same field/panel/action composition as the
// native baseline. Validation and draft ownership stay with the native token.
export function CustomEntryScreen(){
  const route=useRoute<RouteProp<ReviewRoutes,'CustomEntry'>>();
  const {app,live}=useReview();const nav=useReviewNavigation();const upgrade=usePlusEntry();
  const focused=useIsFocused();const authorizing=useRef(false);
  const isDNS=route.params.kind==='dns';const token=route.params.id;
  const entry=live?.customEntry?.id===token?live.customEntry:undefined;
  const initial=useRef(entry);
  const retained=useRef(entry);if(entry)retained.current=entry;
  const presentation=entry??retained.current;
  const [initialized,setInitialized]=useState(!!entry);const [fieldReset,setFieldReset]=useState(0);
  const [name,setName]=useState(initial.current?.name??'');
  const [primary,setPrimary]=useState(initial.current?.primary??'');
  const [secondary,setSecondary]=useState(initial.current?.secondary??'');
  const [url,setURL]=useState('');const [message,setMessage]=useState('');const [busy,setBusy]=useState(false);
  const scope=JSON.stringify([token,live?domainReviewPrivacyScope(live):null]);
  const [entryFailure,setEntryFailure]=useState<{scope:string;message:string}>();
  const currentScope=useRef(scope);currentScope.current=scope;
  const failed=entryFailure?.scope===scope;
  const presentationAuthority=usePresentationReadiness(app,!!app&&focused,!!entry&&initialized||failed,scope);
  const active=useRef(true);const pending=useRef(false);
  useLayoutEffect(()=>{if(entry&&!initial.current){initial.current=entry;setName(entry.name);setPrimary(entry.primary);setSecondary(entry.secondary);setFieldReset(value=>value+1);setInitialized(true);}},[entry]);
  useToolbar({...nativeInlineHeader,title:isDNS?'Custom DNS':'Bring your own list',headerBackVisible:false,
    unstable_headerLeftItems:()=>[toolbarButton('Close','xmark',()=>nav.goBack(),busy)]},[isDNS,busy]);
  useEffect(()=>{active.current=true;return()=>{active.current=false;void app?.command({type:'customEntry.dismiss',id:token}).catch(()=>{});};},[app,token]);
  const enter=async()=>{if(!app||!focused||entry||!presentationAuthority||authorizing.current||AppState.currentState!=='active')return;
    authorizing.current=true;try{await app.command({type:'customEntry.enter',id:token});}
    catch(error){if(active.current&&currentScope.current===scope)setEntryFailure({scope,message:(error as Error).message});}
    finally{authorizing.current=false;}};
  useEffect(()=>{
    if(!entry&&focused)Keyboard.dismiss();void enter();
    const lifecycle=AppState.addEventListener('change',value=>{if(value==='active')void enter();});return()=>lifecycle.remove();
  },[app,token,focused,!!entry,live?.security?.readRevision,presentationAuthority]);
  const save=async()=>{
    if(!app||pending.current||!entry||!canEdit())return;
    pending.current=true;setBusy(true);setMessage('');
    try{await app.command({type:'customEntry.save',id:token,name,...(isDNS?{primary,secondary}:{url:url.trim()})});
      if(active.current&&mayInteractWithPresentation(app))nav.goBack();
    }catch(error){if(active.current&&(error as Error).message!=='Authentication cancelled.')setMessage((error as Error).message);}
    finally{pending.current=false;if(active.current)setBusy(false);}
  };
  const epoch=app?.getReadEpoch?.();
  const canEdit=()=>active.current&&!!entry&&!busy&&currentScope.current===scope&&app?.getReadEpoch?.()===epoch&&mayInteractWithPresentation(app)
    &&(!app?.getSnapshot||app.getSnapshot().snapshot?.customEntry?.id===token);
  const field=(title:string,placeholder:string,value:string,onChangeText:(text:string)=>void,address=false,verbatimPlaceholder=false)=><FormField title={title}
      placeholder={placeholder} verbatimPlaceholder={verbatimPlaceholder} value={value} resetRevision={fieldReset} onChangeText={text=>{if(canEdit())onChangeText(text);}}
      editable={!busy&&!!entry&&mayInteractWithPresentation(app)} autoCapitalize="none" autoCorrect={false} keyboardType={address?'url':'default'}
      />;
  const concealed=!entry;
  return <><Sheet><View testID="custom-entry-page" style={{gap:12,paddingTop:10,opacity:concealed?0:1}} pointerEvents={concealed?'none':'auto'} accessibilityElementsHidden={concealed} importantForAccessibility={concealed?'no-hide-descendants':'auto'}>
    {presentation?.allowed===false?<Group><ListRow title="Upgrade" subtitle="Bring your own list" icon="sparkles" onPress={()=>upgrade(isDNS?'customDNS':'customBlocklist')}/></Group>:<>
      <FormPanel>
        {field('Name (optional)',isDNS?'Custom DNS':'My blocklist',name,setName)}
        <FormDivider/>
        {isDNS?<>{field('Primary DNS','IPv4/6, https://, tls://, doq://, quic://, or sdns://',primary,setPrimary,true)}
          <FormDivider/>
          {field('Secondary DNS (optional)','Same transport as Primary',secondary,setSecondary,true)}</>
          :field('Blocklist URL','https://example.com/pi-hole-style-list.txt',url,setURL,true,true)}
      </FormPanel>
      {presentation?.overBudget&&<Copy role="supporting" color={colors.lavaOrangeText} center>Remove a list before adding another — you're at your filter-rule limit.</Copy>}
      {!!message&&<Info title={isDNS?'Custom DNS cannot be saved':'Custom source cannot be added'} description={message} icon="exclamationmark.triangle"/>}
      <LavaActionButton title={isDNS?'Save':'Add Blocklist'} icon={isDNS?'confirm':'add'}
        labelRole="rowTitle"
        disabled={busy||!entry?.allowed||!!entry?.overBudget||!(isDNS?primary:url).trim()} onPress={()=>void save()}/>
    </>}
  </View></Sheet>{concealed&&<View style={{position:'absolute',top:0,bottom:0,left:0,right:0}}><PresentationCover testID="custom-entry-privacy-cover">{failed&&entryFailure.message!=='Authentication cancelled.'&&<Copy role="supporting" center>{entryFailure.message}</Copy>}<LavaActionButton title="Unlock Lava" role="secondary" onPress={()=>{setEntryFailure(undefined);void enter();}}/></PresentationCover></View>}</>;
}
