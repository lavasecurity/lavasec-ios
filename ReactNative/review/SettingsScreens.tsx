import {Alert} from '../app/presentation';
import {useAppAction,useExclusiveAppAction} from '../app/actions';
import {useEffect, useRef, useState, useSyncExternalStore} from 'react';
import {AccessibilityInfo, AppState, Linking, View} from 'react-native';
import {useIsFocused} from '@react-navigation/native';
import {useSafeAreaInsets} from 'react-native-safe-area-context';
import {LavaChoice} from '../src';
import {colors} from '../src/colors.ios';
import {Choice, Copy, Row, Screen, Section, Symbol} from './primitives';
import {Link, LinkGroup, ListRow, PasscodeEntry, Quiet, QuietFooter, Sheet, Toggle} from './scaffold';
import {useReview} from './ReviewContext';
import {localized,localizedFormat} from '../app/presentation';
import {LavaPlusStory} from './plus-scaffold';
import {previewNotice, useReviewNavigation} from './navigation';

import {connectionStages} from './connection-model';
import {ConnectionPanel,StoryColumns,StoryStack} from './story-scaffold';
import {SettingsControl,SettingsDisclosure,SettingsGlyph,SettingsGroup,SettingsGuardRow,SettingsGuardPreview,SettingsGuardSpotlight,SettingsInset,SettingsIntro,SettingsLoading,SettingsMessage,SettingsPrice,SettingsStack,SettingsStatus,SettingsSubscriptionStatus,SettingsSurface,SettingsTextPreview,SettingsTextSlider,settingsStyles} from './settings-scaffold';

export function SettingsScreen() {
  const nav = useReviewNavigation(); const {live,app,session} = useReview(); const run=useAppAction();
  const stages=connectionStages(live,session);
  return <Screen wide><StoryColumns primary={<ConnectionPanel stages={stages}
    onSelect={stage=>stage.destination?nav.navigate(stage.destination):nav.navigate('Explore',{part:'phone'})}
    onExplore={()=>nav.navigate('Explore')}/>}
    secondary={<StoryStack>
      <SettingsGroup title="Your Lava">
        <Row intent="page" icon="person.crop.circle" title="Account & Backup" onPress={() => nav.navigate('Account')} />
        <Row intent="page" icon="slider.horizontal.3" title="Customization" onPress={() => nav.navigate('Customization')} />
        <Row intent="page" icon="shield.fill" title={live?.plus?.enabled?'Thank you for using Lava Plus':'Get Lava Plus today'} onPress={() => nav.navigate('Upgrade')} />
      </SettingsGroup>
      <SettingsGroup title="Privacy & security">
        <Row intent="page" icon="eyeglasses" testID="row.Privacy & data" title="Privacy & Data" onPress={() => nav.navigate('Privacy')} />
        <Row intent="page" icon="lock.fill" title="Security" onPress={() => nav.navigate('Security')} />
      </SettingsGroup>
      <SettingsGroup title="Support">
        <Row intent="external" icon="questionmark.circle" title="Help" onPress={() => { void Linking.openURL('https://lavasecurity.app/support/'); }} />
        <Row intent="page" icon="ladybug" title="Feedback" onPress={() => app ? run({type:'native.flow',flow:'feedback'}) : nav.navigate('Feedback')} />
        <Row intent="page" icon="doc.text" title="Legal Notices" onPress={() => nav.navigate('Legal')} />
      </SettingsGroup>
      <SettingsGroup title="Advanced">
        <Row intent="page" icon="waveform.path.ecg.rectangle" testID="row.Network activity" title="Network Activity" onPress={() => nav.navigate('Network')} />
        <Row intent="page" icon="number" testID="row.Nerd stats" title="Nerd Stats" onPress={() => nav.navigate('Stats')} />
        {live?.qaTools&&<Row intent="page" icon="square.grid.2x2" title="Design system" onPress={()=>nav.navigate('Components')}/>}
        {live?.qaTools&&<Row intent="page" icon="hammer" title="Device QA" onPress={()=>nav.navigate('DeviceQA')}/>}
      </SettingsGroup>
      <Copy role="caption" color={colors.secondaryText}>{live ? `${localizedFormat('Lava %1$@ (build %2$@)',live.version,live.build)}${live.sourceRevision?` · ${live.sourceRevision.slice(0,12)}`:''}` : 'Lava · UI preview'}</Copy>
    </StoryStack>}/></Screen>;
}

export function AccountScreen() {
  const {app,live}=useReview(); const run=useAppAction();
  const signIn=useExclusiveAppAction('signIn',!!live?.account.busy);
  const backup=useExclusiveAppAction('backup',!!live?.backup.busy);
  const focused=useIsFocused();
  useEffect(()=>{
    if(!app||!focused||!live?.account.signedIn||live.backup.remoteStatus===undefined)return;
    const refresh=()=>{void Promise.resolve(app.command({type:'backup.refresh'})).catch(()=>{});};
    refresh();
    const subscription=AppState.addEventListener('change',state=>{if(state==='active')refresh();});
    return()=>subscription.remove();
  },[app,focused,live?.account.signedIn,live?.backup.enablement?.value]);
  const maintain=(button:string,type:'backup.delete'|'backup.disable')=>{
    if(backup.isBusy())return;
    const confirmation=live?.confirmations?.[button]??{title:button+'?',action:button,message:type==='backup.delete'
      ?"Permanently deletes your account's encrypted backup — this can't be undone. Backup stays on, and a fresh copy uploads next time."
      :"Turns off backup on this device and permanently deletes your account's copy. This can't be undone — you can set up a new backup later."};
    return new Promise<void>(resolve=>Alert.alert(confirmation.title,confirmation.message,[{text:'Cancel',style:'cancel',onPress:resolve},{text:confirmation.action,style:'destructive',onPress:()=>{void backup.run({type}).finally(resolve);}}],{onDismiss:resolve}));
  };
  const [maintenanceOpen,setMaintenanceOpen]=useState(false);
  const enablement=live?.backup.enablement;
  const signedIn=!!live?.account.signedIn;
  // Signed-out backup cannot upload, so present Off without changing the saved
  // native preference. Signed-in missing capabilities remain unknown.
  const enabled=signedIn?(enablement?.value??null):false;
  const needsAttention=live?.backup.needsAttention??false;
  const pendingDeletion=enablement?.state==='deletionPending'||!!live?.backup.deletionPending;
  const backupDetail=needsAttention?live?.backup.detail:undefined;
  const backupSummary=!signedIn?'Ready after sign-in':backupDetail||(enabled?live?.backup.remoteStatus??live?.backup.summary:enabled===false?'No backup':live?.backup.detail||'Needs attention');
  const canShowTools=enabled===true&&signedIn;
  const setup=()=>{if(signedIn&&enablement?.canEnable&&!backup.isBusy())backup.run({type:'native.flow',flow:'backupSetup'});};
  const disable=()=>{if(signedIn&&enablement?.canDisable&&!backup.isBusy())maintain('Turn off & delete backup','backup.disable');};
  return <Screen>
    <SettingsIntro summary="Use Lava without an account, or sign in to back up your settings securely."/>
    <SettingsGroup title="Account">
      <SettingsStatus icon="person.crop.circle" title={live?.account.status??'Not signed in'} description={live?.account.message||live?.account.detail||undefined}/>
      <ListRow action title={live?.account.appleTitle??'Sign in with Apple'} disabled={signIn.busy} leading={<SettingsGlyph name="apple.logo" busy={live?.account.appleBusy}/>}
        onPress={()=>signIn.run(live?.account.appleConnected?{type:'native.flow',flow:'account'}:{type:'account.apple'})}/>
      <ListRow action title={live?.account.googleTitle??'Sign in with Google'} disabled={signIn.busy} leading={<SettingsGlyph name="google.signin" busy={live?.account.googleBusy}/>}
        onPress={()=>signIn.run(live?.account.googleConnected?{type:'native.flow',flow:'account'}:{type:'account.google'})}/>
    </SettingsGroup>
    <Section title="Encrypted Backup">
      <SettingsSurface>
        {enabled===null
          ? <SettingsStatus icon="lock.icloud" title="Enable backup" description={backupSummary} busy={!!live?.backup.busy}/>
          : <Toggle title="Enable backup" summary={backupSummary} value={enabled} optimistic={false}
              disabled={!signedIn||backup.busy||!(enabled?enablement?.canDisable:enablement?.canEnable)}
              onChange={next=>{if(next)setup();else disable();}}/>}
        {canShowTools&&<ListRow action title={live?.backup.backingUp?'Backing Up':'Back Up Now'} icon="icloud.and.arrow.up.fill" leading={live?.backup.backingUp?<SettingsGlyph name="icloud.and.arrow.up.fill" busy/>:undefined}
          disabled={backup.busy||!enablement?.canBackUp} onPress={()=>backup.run({type:'backup.now'})}/>}
        {!!live?.account.signedIn&&!pendingDeletion&&enabled!==null&&<ListRow action title="Restore Backup" icon="icloud.and.arrow.down.fill"
          disabled={backup.busy||!enablement?.canRestore} onPress={()=>backup.run({type:'native.flow',flow:'backupRestore'})}/>}
        {pendingDeletion&&<ListRow action title="Turn off & delete backup" icon="trash" color={colors.errorText}
          disabled={backup.busy||!enablement?.canRetryDeletion} onPress={()=>maintain('Turn off & delete backup','backup.disable')}/>}
      </SettingsSurface>
      {canShowTools&&<SettingsDisclosure title="Backup maintenance" icon="ellipsis.circle" testID="backup.maintenance" expanded={maintenanceOpen} onChange={setMaintenanceOpen}>
        <SettingsSurface footer="Lava waits 5 minutes after your last settings change before it tries an automatic upload.">
          <Toggle title="Automatic Backup" accessibilityHint="Lava waits 5 minutes after your last settings change before it tries an automatic upload."
            value={!!live?.backup.automatic} disabled={backup.busy||!enablement?.canChangeAutomatic}
            onChange={value=>run({type:'settings.set',key:'backup.automatic',value})}/>
        </SettingsSurface>
        <SettingsSurface><ListRow action title="Delete online backup copy"
          icon="trash" disabled={backup.busy||!enablement?.canDisable} color={colors.errorText}
          onPress={()=>maintain('Delete online backup copy','backup.delete')}/></SettingsSurface>
      </SettingsDisclosure>}
    </Section>
  </Screen>;
}

export function CustomizationScreen() {
  const nav = useReviewNavigation(); const {appearance, session, setSession,app,live,look} = useReview(); const run=useAppAction();
  const {snapshot, error} = useSyncExternalStore(appearance.subscribe, appearance.getSnapshot);
  return <Screen>
    <SettingsIntro summary="Change Lava's look and feel. Protection stays the same."/>
    <SettingsGuardPreview look={look} title={live?.guards?.find(g=>g.id===look)?.title??'Original'} subtitle={live?.guards?.find(g=>g.id===look)?.subtitle||undefined} onPress={()=>nav.navigate('Guardian')}/>
    <Section title="Appearance">
      <Choice label="Appearance" options={['Light','Dark','System']} value={snapshot?.preference==='light'?'Light':snapshot?.preference==='dark'?'Dark':'System'} onChange={value=>app?run({type:'settings.set',key:'appearance',value:value.toLowerCase()}):appearance.setPreference(value.toLowerCase() as 'system'|'light'|'dark')}/>
      {error&&<SettingsInset><SettingsMessage warning>{error}</SettingsMessage></SettingsInset>}
    </Section>
    <SettingsGroup title="Text Size">
      <SettingsTextPreview/>
      <Toggle title="Match System" value={session.matchTextSize} onChange={value=>setSession({...session,matchTextSize:value})}/>
      {!session.matchTextSize&&<SettingsTextSlider value={session.textSize} disabled={false} onChange={value=>setSession({...session,textSize:value})}/>}
    </SettingsGroup>
    <SettingsGroup title="Notifications & haptics">
      <Toggle title="App Haptics" value={session.haptics} onChange={value=>setSession({...session,haptics:value})}/>{Object.entries(session.notifications).map(([title,value])=><Toggle key={title} title={title} value={value} onChange={next=>setSession({...session,notifications:{...session.notifications,[title]:next}})}/>)}</SettingsGroup>
    {(!live||live.liveActivityPause.available)&&<SettingsGroup title="Live Activities (beta)" footer="Shows Lava status on the Lock Screen and Dynamic Island when available.">
      <Toggle title="Use Live Activities" accessibilityHint="Shows Lava status on the Lock Screen and Dynamic Island when available." value={session.liveActivities} onChange={value=>setSession({...session,liveActivities:value})}/>
      {session.liveActivities&&<SettingsControl title={live?.liveActivityPause.label??localizedFormat('Pause length: %d min',5)}><LavaChoice presentation="stepper" testID="Live Activity pause length" label={live?.liveActivityPause.label??localizedFormat('Pause length: %d min',5)} options={(live?.liveActivityPause.minutes??Array.from({length:30},(_,i)=>i+1)).map(minutes=>({value:String(minutes),label:String(minutes)}))} value={String(live?.liveActivityPauseMinutes??5)} onValueChange={value=>run({type:'settings.set',key:'liveActivityPauseMinutes',value:Number(value)})}/></SettingsControl>}
    </SettingsGroup>}
    <SettingsGroup title="Language"><Row intent="external" title="Change in system settings" onPress={()=>{void Linking.openSettings();}}/></SettingsGroup>
  </Screen>;
}

export function GuardianScreen() {
  const nav = useReviewNavigation(); const {session,setSession,app,live,look,setLook} = useReview();
  const selectionPending=useRef(false);const iconPending=useRef(false);const [changingIcon,setChangingIcon]=useState(false);
  const select=(id:string)=>{
    if(!app){setLook(id);return;}if(selectionPending.current)return;selectionPending.current=true;
    void app.command({type:'settings.set',key:'look',value:id}).catch(error=>{if(error.message!=='Authentication cancelled.')Alert.alert('Lava',error.message);}).finally(()=>{selectionPending.current=false;});
  };
  const matchIcon=(value:boolean)=>{
    if(!app){setSession({...session,matchIcon:value});return;}if(iconPending.current)return;iconPending.current=true;setChangingIcon(true);
    return app.command({type:'settings.set',key:'matchIcon',value}).catch(error=>{if(error.message!=='Authentication cancelled.')Alert.alert('Lava',error.message);}).finally(()=>{iconPending.current=false;setChangingIcon(false);});
  };
  const variants=live?.guards??[{id:'original',title:'Original',description:'A Lava a day keeps bad domains away.',tip:'Keep Lava protecting you to unlock more Guards, or upgrade to unlock them all.'}];
  return <Sheet>
    <SettingsGuardSpotlight look={look} variants={variants}/>
    <SettingsGroup title="Choose your Guard" testID="guardian.options">{live?live.guards.map(guard=><SettingsGuardRow
      key={guard.id} testID={`guardian.option.${guard.id}`} look={guard.id} title={guard.title} subtitle={guard.subtitle||undefined}
      selected={look===guard.id} locked={!guard.selectable} onPress={()=>select(guard.id)}/>):[0,3,7,14,30,60,90,120].map(days=><SettingsGuardRow
      key={days} look="original" title={days?localizedFormat('Use Lava %d days',days):localized('Original')} subtitle={days?localizedFormat('Currently at: %d days',0):undefined}
      selected={days===0} locked={days>0} onPress={()=>{}}/>)}</SettingsGroup>
    <SettingsSurface><Toggle title="Match App Icon to Lava Guard" value={session.matchIcon} disabled={changingIcon} onChange={matchIcon}/></SettingsSurface>
    {!live?.plus?.enabled&&<>
      <QuietFooter note="Keep Lava protecting you to unlock more Guards, or upgrade to unlock them all." title="Upgrade" onPress={()=>nav.navigate('Upgrade')}/>
      <QuietFooter note="Lava Guard progress requires local logs." title="Review Privacy & Data" onPress={()=>nav.navigate('Privacy')}/>
    </>}
  </Sheet>;
}

export {DNSScreen,DNSPickerScreen} from './DNSScreen';

export function PrivacyScreen() {
  const {session,setSession,app,live} = useReview(); const run=useAppAction(); const [showDelete,setShowDelete] = useState(false);
  const [exportError,setExportError]=useState<string>();
  const exportPending=useRef(false); const [isExporting,setIsExporting]=useState(false);
  const exportBusy=isExporting||!!live?.logExportBusy;
  const exportLogs=()=>{
    if(exportPending.current||live?.logExportBusy)return;
    setExportError(undefined);
    if(!app){previewNotice();return;}
    exportPending.current=true;setIsExporting(true);
    void app.command({type:'logs.export',domains:false}).catch(error=>{if(error.message!=='Authentication cancelled.')setExportError(localizedFormat('Could not export local logs: %@',localized(error.message)));})
      .finally(()=>{exportPending.current=false;setIsExporting(false);});
  };
  const disableLogs:Record<string,{title:string;message:string;action:string}>={
    'Filtering Counts':{title:'Turn off local filtering counts?',message:'Saved filtering counts will be cleared and new allowed, blocked, and local protection uptime counts will not be saved.',action:'Turn Off and Clear Counts'},
    'Domain logs':{title:'Turn off local domain history?',message:'Saved domain names will be cleared and new domain names will not be saved.',action:'Turn Off and Clear History'},
    'Network activity':{title:'Turn off local network activity?',message:'Saved network activity entries will be cleared and new network activity entries will not be saved.',action:'Turn Off and Clear Activity'},
    'Lava Guard Progress':{title:'Turn off Lava Guard progress?',message:'Saved Lava Guard progress will be cleared and new Lava Guard progress will not be saved.',action:'Turn Off and Clear Progress'},
  };
  const setLog=(title:string,next:boolean)=>{
    const apply=()=>app ? run({type:'settings.set',key:`logs.${title}`,value:next}) : setSession({...session,logs:{...session.logs,[title]:next},sudoku:title==='Lava Guard Progress'&&!next?undefined:session.sudoku});
    const confirmation=live?.confirmations?.[`disable.${title}`]??disableLogs[title];
    if(!next&&confirmation) return new Promise<void>(resolve=>Alert.alert(confirmation.title,confirmation.message,[
      {text:'Cancel',style:'cancel',onPress:resolve},{text:confirmation.action,style:'destructive',onPress:()=>{void Promise.resolve(apply()).finally(resolve);}},
    ],{onDismiss:resolve}));
    return apply();
  };
  const clearProgress=()=>Alert.alert('Clear Lava Guard progress?',
    'This removes unearned Lava Guard progress from this device. Earned Lava Guards stay unlocked.',[
      {text:'Cancel',style:'cancel'},{text:'Clear Progress',style:'destructive',onPress:()=>{
        if(app) run({type:'logs.clear',kind:'Clear Lava Guard progress'});
        else {setSession({...session,sudoku:undefined});AccessibilityInfo.announceForAccessibility(localized('Lava Guard progress cleared.'));}
      }},
    ]);
  const clearLog=(kind:string)=>{
    const contract=live?.confirmations?.[kind];
    if(contract){Alert.alert(contract.title,contract.message,[{text:'Cancel',style:'cancel'},{text:contract.action,style:'destructive',onPress:()=>run({type:'logs.clear',kind})}]);return;}
    if(kind==='Clear Lava Guard progress'){clearProgress();return;}
    previewNotice();
  };
  return <Screen>
    <SettingsIntro summary="Domain history and network activity stay on this device for 7 days. Counts and Guard progress last longer."/>
    <SettingsGroup title="Local Logs">{Object.entries(session.logs).map(([title,value])=><Toggle key={title} title={title} value={value} optimistic={false} onChange={next=>setLog(title,next)}/>)}</SettingsGroup>
    <SettingsSurface footer="Anyone with this ZIP can read its diagnostics and settings.">
      <ListRow action icon="square.and.arrow.up" title="Export local logs" accessibilityHint="Anyone with this ZIP can read its diagnostics and settings." disabled={exportBusy} onPress={exportLogs}/>
    </SettingsSurface>
    {!isExporting&&!!(exportError||live?.logExportError)&&<SettingsMessage warning>{exportError||live?.logExportError}</SettingsMessage>}
    <SettingsDisclosure title="Delete Local Logs" icon="trash" testID="privacy.delete-options" expanded={showDelete} onChange={setShowDelete}>
      <SettingsSurface>{['Clear filtering counts','Clear domain history','Clear network activity','Clear Lava Guard progress'].map(title=><ListRow key={title} action title={title} color={colors.errorText} icon="trash" onPress={()=>clearLog(title)}/>)}
      <ListRow action title="Clear all logs" color={colors.errorText} icon="trash" onPress={()=>clearLog('Clear all logs')}/></SettingsSurface>
    </SettingsDisclosure>
  </Screen>;
}

export function SecurityScreen() {
  const pending=useRef(false);const [updating,setUpdating]=useState(false);
  const nav = useReviewNavigation(); const {session,setSession,app,live} = useReview(); const run=useAppAction();
  const hasMethod=live?.security.hasAuthenticationMethod??(session.passcode||session.biometrics);
  const setProtection=(title:string,next:boolean)=>{
    if(!hasMethod||pending.current||live?.security.updatingSurface)return;
    if(!app){setSession({...session,protectedActions:{...session.protectedActions,[title]:next}});return;}
    pending.current=true;setUpdating(true);
    return app.command({type:'settings.set',key:`protectedActions.${title}`,value:next}).catch(error=>{if(error.message!=='Authentication cancelled.')Alert.alert('Lava',error.message);}).finally(()=>{pending.current=false;setUpdating(false);});
  };
  return <Screen>
    <SettingsIntro summary="Choose which parts of Lava need a passcode or Face ID."/>
    <SettingsGroup title="Authentication method">
      <Toggle title="Passcode" disabled={live?.security.unavailable} value={session.passcode} onChange={()=>app?run({type:'native.flow',flow:'passcode'}):nav.navigate('Passcode')}/>
      {(!live||live.security.showBiometrics)&&<Toggle title={live?.security.biometricTitle??'Face ID'} value={session.biometrics} disabled={live?!live.security.canEnableBiometrics:!session.passcode} onChange={value=>setSession({...session,biometrics:value})}/>}
      {!!live?.security.status&&<SettingsInset><SettingsMessage>{live.security.status}</SettingsMessage></SettingsInset>}
    </SettingsGroup>
    <SettingsGroup title="Use authentication for" footer="Choose which actions ask for authentication. All choices start off.">
      {Object.entries(session.protectedActions).map(([title,value])=><Toggle key={title} title={title} value={hasMethod&&value} disabled={!hasMethod||updating||live?.security.updatingSurface} onChange={next=>setProtection(title,next)}/>)}
    </SettingsGroup>
  </Screen>;
}

export function PasscodeScreen() {
  // Never retain credentials in the UI fixture. The keypad lets the reviewer
  // inspect the native input surface; completing it reports the service boundary.
  const [code,setCode] = useState('');
  const insets = useSafeAreaInsets();
  return <PasscodeEntry topInset={insets.top} value={code} onChange={value=>{setCode(value);if(value.length===4){setCode('');previewNotice();}}}/>;
}

export function UpgradeScreen() {
  const {app,live,look}=useReview();const {run,busy}=useExclusiveAppAction('purchase',!!live?.plus.busy);
  const focused=useIsFocused();
  useEffect(()=>{if(!app||!focused)return;void app.command({type:'purchase.refresh'}).catch(error=>Alert.alert('Lava',error.message));return()=>{void app.command({type:'purchase.clearMessage'}).catch(()=>{});};},[app,focused]);
  return <Screen>
    <LavaPlusStory/>
    {live?.plus.enabled ? <><SettingsSubscriptionStatus look={live.look} expiration={live.plus.expiration}/><SettingsSurface><ListRow action title="Manage Subscription" icon="creditcard.circle" disabled={busy} onPress={()=>run({type:'purchase.manage'})}/><ListRow action title="Restore Purchase" icon="arrow.clockwise.circle" disabled={busy} onPress={()=>run({type:'purchase.restore'})}/></SettingsSurface></> : live?.plus.checking ? <SettingsLoading title="Checking Lava Security Plus"/> : <SettingsStack><SettingsStack><Copy role="heading">Choose a plan</Copy><Copy color={colors.secondaryText}>... and a pitch for your parent</Copy></SettingsStack>
      {(!app&&([['Yearly','"Paying by the year beats paying by the month."','$29.99'],['Monthly','"We already saved this by unplugging appliances."','$3.99']] as const).map(([title,pitch,price]) => <SettingsSurface key={title}><ListRow action title={title} subtitle={pitch} trailing={<Copy weight="600" color={colors.safeGreen}>{price}</Copy>} onPress={previewNotice} /></SettingsSurface>))}
      {live?.plus.offers.map(offer=><SettingsSurface key={offer.id}><ListRow action title={offer.title} subtitle={offer.subtitle} trailing={<SettingsPrice price={offer.price} commitment={offer.commitmentPrice}/>} disabled={busy} onPress={()=>run({type:"purchase.buy",id:offer.id})}/></SettingsSurface>)}
      <Copy color={colors.secondaryText}>or if you have already made a purchase</Copy><SettingsSurface><ListRow action title="Restore Purchase" icon="arrow.clockwise.circle" disabled={busy} onPress={()=>run({type:"purchase.restore"})} /></SettingsSurface>
    </SettingsStack>}
    <SettingsStack>
      <Quiet>{live?.plus.showsYearlyPaidMonthly ? 'Monthly and yearly plans auto-renew. Yearly paid monthly is billed monthly on a 12-month commitment; after that, cancelling affects the next renewal per App Store terms. Payment is charged to your Apple Account at purchase and renews unless turned off at least 24 hours before the period ends. Manage or cancel in Apple Account settings.' : 'Monthly and yearly plans auto-renew. Payment is charged to your Apple Account at purchase and renews unless turned off at least 24 hours before the period ends. Manage or cancel in Apple Account settings.'}</Quiet>
      <LinkGroup><Link title="Terms of Use" onPress={()=>{void Linking.openURL('https://www.apple.com/legal/internet-services/itunes/dev/stdeula/');}} /><Link title="Privacy Policy" onPress={()=>{void Linking.openURL('https://lavasecurity.app/privacy/');}} /></LinkGroup>
    </SettingsStack>
    {!!live?.plus.message&&<Quiet>{live.plus.message}</Quiet>}
  </Screen>;
}
