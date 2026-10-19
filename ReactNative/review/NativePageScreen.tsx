import {QAFlowAdapter} from './QAFlowAdapter.ios';
import {usePresentationNativeLayout} from '../app/use-presentation-readiness';
import {useContext,useRef,type PropsWithChildren} from 'react';
import {PixelRatio,View} from 'react-native';
import {useDiscoveryVisit} from './discovery';
import {useIsFocused,useNavigation,useRoute,type RouteProp} from '@react-navigation/native';
import {useReview,useRouteBodyConcealed} from './ReviewContext';
import {useReviewNavigation,type ReviewRoutes} from './navigation';
import {FeedbackScreen} from './FeedbackScreen';
import {AutoSwitchPage} from './HelpScreens';
import {DNSHelpScreen,type DNSInstructionRowProps} from '../src/flows/dns-help/DNSHelpScreen';
import {PresentationContext} from '../app/presentation';
import {useTextScale} from '../app/text-metrics';
import {Screen,Symbol} from './primitives';
import {foundation} from '../src/foundation';
import {colors} from '../src/colors';
import {FormParagraph} from './form-scaffold';
import {NativeFlowMetrics} from './NativeFlowMetrics.ios';
import {useNativeFlowAlert} from './NativeFlowAlert.ios';

export function AutoSwitchScreen() {
  return <AutoSwitchPage/>;
}

export function DNSPatchScreen() {
  return <NativeFlowMetrics><DNSPatchBody/></NativeFlowMetrics>;
}
function DNSPatchBody() {
  const {app,live}=useReview();
  const route=useRoute<RouteProp<ReviewRoutes,'DNSPatch'>>();
  const focused=useIsFocused(),concealed=useRouteBodyConcealed();
  const showAlert=useNativeFlowAlert(app,{kind:'dnsPatch',id:route.key},focused&&!concealed);
  const navigation=useReviewNavigation(route.params);
  useDiscoveryVisit('ios27Patch.page');
  if(!app)return null;
  const enabled=live?.dnsPatch?.state==='enabled';
  const open=(target:'settings'|'connectivityAssist')=>{void app.command({type:'system.open',target}).catch(error=>showAlert('Lava',error.message));};
  return <DNSHelpScreen profileEnabled={enabled} page={DNSHelpPage} paragraph={DNSHelpParagraph} instructionRow={DNSHelpInstructionRow} port={{openDNS:()=>navigation.navigate('DNS'),openVPN:()=>navigation.navigate('VPNChaining'),openSettings:()=>open('settings'),openSupport:()=>open('connectivityAssist'),
    profileGlyph:<Symbol size={foundation.control.glyphSlot} pointSize={foundation.control.glyph} name={enabled?'checkmark.circle.fill':'network'} tone={enabled?'green':'primary'}/>}}/>;
}

// A pushed page exposes its scroll view directly to the enclosing native stack.
// Keep the original sheet body's measured vertical clearances inside that owner.
function DNSHelpPage({children}:PropsWithChildren){
  return <Screen contentContainerStyle={{paddingTop:28,paddingBottom:44}}>{children}</Screen>;
}

// SwiftUI subheadline keeps20pt baseline advance and standard orphan handling.
// Retain its natural first/last line box through the existing paragraph atom.
function DNSHelpParagraph({children}:PropsWithChildren){
  return <FormParagraph lineBreakStrategyIOS="standard" style={{color:colors.primaryText}}>{children}</FormParagraph>;
}
function DNSHelpInstructionRow({badge,children}:DNSInstructionRowProps){
  const {nativeTextMetrics}=useContext(PresentationContext);const scale=useTextScale('subheadline');
  const metric=nativeTextMetrics?.subheadline;
  const lineHeight=metric&&Number.isFinite(metric.fontSize)&&metric.fontSize>0&&Number.isFinite(metric.lineHeight)&&metric.lineHeight>0&&Number.isFinite(metric.leading)&&metric.lineHeight+metric.leading>0?metric.lineHeight:17.900390625*scale;
  const naturalHeight=Math.ceil(lineHeight*PixelRatio.get())/PixelRatio.get();
  // Original firstTextBaseline HStack: a22pt badge centers its natural18pt
  // label, so regular-size prose starts2pt lower and retains that row envelope.
  // When text exceeds the badge atAX sizes, the badge moves down instead.
  return <View testID="dns.instruction.row" style={{flexDirection:'row',alignItems:'flex-start',gap:foundation.space.md}}>
    <View testID="dns.instruction.badge" style={{paddingTop:Math.max(0,(naturalHeight-22)/2)}}>{badge}</View>
    <View testID="dns.instruction.body" style={{flex:1,paddingTop:Math.max(0,(22-naturalHeight)/2)}}>{children}</View>
  </View>;
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
