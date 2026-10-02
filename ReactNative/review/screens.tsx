import {useOnboardingHandoff} from './onboarding-handoff';
export {DNSPatchScreen} from './DNSPatchScreen';
export {VPNChainingScreen,AutoSwitchScreen,FeedbackSettingsScreen,DeviceQAScreen} from './NativePageScreen';
import {useMascotTapInteraction} from './mascot-interaction';
import {ContextMenu} from './ContextMenu';
import {useIsFocused,useNavigation} from '@react-navigation/native';
import {Alert, localized, localizedFormat} from '../app/presentation';
import {useEffect,useRef,useState} from 'react';
import { AppState, View} from 'react-native';
import {Link} from './scaffold';
import {LavaActionButton} from '../src';
import {LavaComponentGallery} from '../gallery/LavaComponentGallery';
import {Copy, Guardian, Screen} from './primitives';
import {useReview} from './ReviewContext';
import {activeFilterSummary,todaySummary} from './connection-model';
import {ExploreInvitation,GuardSummaries,ProtectionHero,StoryColumns,StoryStack,StorySurface} from './story-scaffold';
import {previewNotice, useReviewNavigation} from './navigation';
export type {ReviewRoutes} from './navigation';
export {previewNotice} from './navigation';
export * from './SettingsScreens';
export * from './FilterScreens';
export * from './DiagnosticScreens';
export {FeedbackScreen} from './FeedbackScreen';
export {ActivityScreen} from './ActivityScreen';
export {SudokuScreen} from './SudokuScreen';
export {ExploreScreen} from './ExploreScreen';

export function GuardScreen() {
  const nav=useReviewNavigation();const {session,look,app,live,onboardingPreview}=useReview();
  const handoff=live?.onboarding?.mock===!!onboardingPreview?live?.onboarding:undefined;
  const ready=!!handoff&&['arriving','ready'].includes(handoff.phase);
  const rawNav=useNavigation();const revealing=useRef(false);const active=useRef(true);const revealEpoch=useRef(0);
  const taps=useRef({count:0,last:0});const focused=useIsFocused();
  const anchors=useOnboardingHandoff(app,focused?handoff:undefined);
  const [foreground,setForeground]=useState(AppState.currentState==='active');
  const mascotInteraction=useMascotTapInteraction(true,live?.protection.mood==='awake');
  const gesture=(value:'start'|'end'|'tap'|'reveal')=>{if(onboardingPreview)return;void app?.command({type:'guard.gesture',gesture:value}).catch(()=>{});};
  useEffect(()=>{
    const reset=()=>{taps.current.count=0;gesture('end');};
    active.current=focused;if(!focused)reset();
    const listener=AppState.addEventListener('change',state=>{setForeground(state==='active');if(state!=='active')reset();if(state==='background')++revealEpoch.current;});
    return()=>{active.current=false;++revealEpoch.current;listener.remove();reset();};
  },[focused,app]);
  const reveal=()=>{
    taps.current.count=0;gesture('end');
    if(!app){nav.navigate('Guardian');return;}if(revealing.current)return;revealing.current=true;const started=revealEpoch.current;
    void app.command({type:'navigation.authorize',surface:'appSettings'}).then(()=>{if(active.current&&started===revealEpoch.current){gesture('reveal');rawNav.navigate('Guardian' as never);}}).catch(error=>{if(active.current&&error.message!=='Authentication cancelled.')Alert.alert('Lava',error.message);}).finally(()=>{revealing.current=false;});
  };
  const mascotTap=()=>{
    mascotInteraction.tap();
    const now=Date.now();
    taps.current={count:now-taps.current.last>=1200?1:taps.current.count+1,last:now};
    if(taps.current.count===5){taps.current.count=0;nav.navigate('Sudoku');}
  };
  const protection = onboardingPreview ? {...live!.protection,title:'Protection Off',subtitle:'Tap once to add local protection',action:'Turn On',mood:'sleeping',materialIntent:'rest' as const,actionTone:'affirmative' as const,canPause:false,configuring:false,disabled:false,needsVPNSetup:false,needsDNSProviderChange:false} : live?.protection;
  const command = () => {if(onboardingPreview||handoff)return;if(app) void app.command({type:'protection.toggle'}).catch(error=>Alert.alert('Lava',error.message)); else previewNotice();};
  const mood = mascotInteraction.grateful&&protection?.mood==='awake'?'grateful':protection?.mood ?? "sleeping";
  const pauseOptions=protection?.canPause?(protection.pauseOptions??[5,10,15].map(minutes=>({minutes,title:localizedFormat('Pause for %d minutes',minutes)}))).map(option=>({id:String(option.minutes),title:option.title,symbol:'pause.circle'})):[];
  const pause=(id:string)=>{if(pauseOptions.some(option=>option.id===id))void app?.command({type:'protection.pause',minutes:Number(id) as 5|10|15}).catch(error=>{if(error.message!=='Authentication cancelled.')Alert.alert('Lava',error.message);});};
  return <Screen wide><StoryColumns primary={<View ref={anchors.panel} collapsable={false}><ProtectionHero ready={ready} title={protection?.title ?? 'Protection Off'}
    materialIntent={protection?.materialIntent}
    active={focused&&foreground}
    description={protection?.subtitle ?? 'Tap once to add local protection'}
    accessibilityActions={[{name:'playSudoku',label:localized('Play Sudoku')},{name:'changeGuardian',label:localized('Change Lava Guard')}]}
    onAccessibilityAction={event=>{if(event.nativeEvent.actionName==='playSudoku')nav.navigate('Sudoku');else if(event.nativeEvent.actionName==='changeGuardian')reveal();}}
    mascot={<View ref={anchors.mascot} collapsable={false} style={{opacity:handoff&&handoff.phase!=='released'?0:1}}><Guardian testID="guard.mascot" look={look} mood={mood} gesturesEnabled={focused&&foreground}
      onGesture={value=>{if(value==='end')gesture('end');else if(focused&&foreground){if(value==='reveal')reveal();else if(value==='tap')mascotTap();else gesture('start');}}}/></View> }
    action={<View ref={anchors.action} collapsable={false}><ContextMenu testID="guard.pause-menu" actions={pauseOptions} onAction={pause}>
      <LavaActionButton stablePill tone={protection?.actionTone} title={ready?'Open Guard':protection?.action ?? 'Turn On'} subtitle={protection?.canPause?'Long-press for pause options':undefined}
        disabled={protection?.disabled} busy={protection?.configuring} onPress={command}
        accessibilityActions={pauseOptions.map(option=>({name:option.id,label:localized(option.title)}))} onAccessibilityAction={event=>pause(event.nativeEvent.actionName)}/>
    </ContextMenu></View>}>
    {protection?.needsDNSProviderChange&&<Link title="Change DNS provider" onPress={()=>nav.navigate('DNS')} footer/>}
    {protection?.needsVPNSetup&&<Link title="Review VPN setup" onPress={()=>nav.navigate('VPNChaining')} footer/>}
  </ProtectionHero></View>} secondary={<StoryStack>
    <GuardSummaries today={todaySummary(live,session)} filter={activeFilterSummary(live,session)} onActivity={()=>nav.navigate('Activity')} onFilters={()=>nav.navigate('Filters')}/>
    <ExploreInvitation attention={live?.discoveries?.['ios27Patch.settings']===true} onPress={()=>nav.navigate('Explore')}/>
  </StoryStack>}/></Screen>;
}
export function ComponentsScreen() { return <LavaComponentGallery />; }

export function RuntimeError({message, retry}: {message: string; retry: () => void}) {
  return <StorySurface><Copy role="body">{message}</Copy><LavaActionButton title="Try again" onPress={retry}/></StorySurface>;
}

export {CustomEntryScreen} from './NativePageScreen';
