import {QAFlowAdapter} from './QAFlowAdapter.ios';
import {usePresentationNativeLayout} from '../app/use-presentation-readiness';
import {useRef,type PropsWithChildren} from 'react';
import {useDiscoveryVisit} from './discovery';
import {useIsFocused,useNavigation,useRoute,type RouteProp} from '@react-navigation/native';
import {useReview,useRouteBodyConcealed} from './ReviewContext';
import {useReviewNavigation,type ReviewRoutes} from './navigation';
import {FeedbackScreen} from './FeedbackScreen';
import {AutoSwitchPage} from './HelpScreens';
import {DNSHelpScreen} from '../src/flows/dns-help/DNSHelpScreen';
import {Screen,Symbol} from './primitives';
import {foundation} from '../src/foundation';
import {useNativeFlowAlert} from './NativeFlowAlert.ios';

export function AutoSwitchScreen() {
  return <AutoSwitchPage/>;
}

export function DNSPatchScreen() {
  const {app,live}=useReview();
  const route=useRoute<RouteProp<ReviewRoutes,'DNSPatch'>>();
  const focused=useIsFocused(),concealed=useRouteBodyConcealed();
  const showAlert=useNativeFlowAlert(app,{kind:'dnsPatch',id:route.key},focused&&!concealed);
  const navigation=useReviewNavigation(route.params);
  useDiscoveryVisit('ios27Patch.page');
  if(!app)return null;
  const enabled=live?.dnsPatch?.state==='enabled';
  const open=(target:'settings'|'connectivityAssist')=>{void app.command({type:'system.open',target}).catch(error=>showAlert('Lava',error.message));};
  return <DNSHelpScreen profileEnabled={enabled} page={DNSHelpPage} port={{openDNS:()=>navigation.navigate('DNS'),openVPN:()=>navigation.navigate('VPNChaining'),openSettings:()=>open('settings'),openSupport:()=>open('connectivityAssist'),
    profileGlyph:<Symbol size={foundation.control.glyphSlot} pointSize={foundation.control.glyph} name={enabled?'checkmark.circle.fill':'network'} tone={enabled?'green':'primary'}/>}}/>;
}

// A pushed page exposes its scroll view directly to the enclosing native stack.
// Keep the original sheet body's measured vertical clearances inside that owner.
function DNSHelpPage({children}:PropsWithChildren){
  return <Screen contentContainerStyle={{paddingTop:28,paddingBottom:44}}>{children}</Screen>;
}

export {CustomEntryScreen} from './CustomEntryScreen';

// Preview-only route. Full-app feedback is the shared native-authorized flow.
export function FeedbackSettingsScreen() { return <FeedbackScreen/>; }

export function DeviceQAScreen() {
  const {app, live} = useReview();
  const available=useRef(false);
  const coveredByForeground=useRef(false);
  // PhoneQAView owns an unpublished configuration buffer. A temporary missing
  // projection conceals that same native host; availability loss, a foreground
  // takeover, or the enclosing owner boundary retires it.
  if(live)available.current=live.qaTools;
  // Keep the page unmounted through a QA sheet's handoff to Feedback. The old
  // sheet's visit retires when its UIKit dismissal completes, and a temporary
  // privacy snapshot gap must not admit a replacement page in that interval.
  if(live)coveredByForeground.current=!!live.foregroundFlow;
  if (!app || !available.current || coveredByForeground.current) return null;
  return <DeviceQANativePage/>;
}

// Only an admitted host owns a viewport ticket. Availability/owner retirement
// disposes its measurement; temporary revocation keeps that same native layout.
function DeviceQANativePage() {
  const id=useRef(`device-qa-${Date.now()}-${Math.random().toString(36).slice(2)}`).current;
  return <QAFlowAdapter id={id}/>;
}
