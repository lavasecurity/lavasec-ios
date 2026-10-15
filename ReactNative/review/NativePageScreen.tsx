import {usePresentationNativeLayout} from '../app/use-presentation-readiness';
import {useRef} from 'react';
import {useDiscoveryVisit} from './discovery';
import {useIsFocused,useNavigation,useRoute,type RouteProp} from '@react-navigation/native';
import NativePage from '../specs/LavaNativePageNativeComponent';
import {useReview,useRouteBodyConcealed} from './ReviewContext';
import {useReviewNavigation,type ReviewRoutes} from './navigation';
import {FeedbackScreen} from './FeedbackScreen';
import {AutoSwitchPage} from './HelpScreens';

export function AutoSwitchScreen() {
  return <AutoSwitchPage/>;
}

export function DNSPatchScreen() {
  const {app}=useReview();
  if(!app)return null;
  return <NativeSettingsPage page="dnsPatch" testID="dns-patch-page"/>;
}

// Native content shares the enclosing stack's bar, transition and destination
// authentication. Its configuration editor is presented by the app's native flow
// host, not declared inside this embedded page.
function NativeSettingsPage({page,testID}:{page:'automation'|'dnsPatch';testID:string}) {
  const route=useRoute<RouteProp<ReviewRoutes,'VPNChaining'>>();
  const focused=useIsFocused();
  const onLayout=usePresentationNativeLayout();
  const navigation=useReviewNavigation(route.params);
  useDiscoveryVisit(page==='dnsPatch'?'ios27Patch.page':undefined);
  const open=(destination:string)=>{
    if(destination!=='DNS'&&destination!=='Upgrade'&&!(page==='dnsPatch'&&destination==='VPNChaining'))return;
    const state=navigation.getState();const previous=state.routes[state.index-1];
    if(destination===route.params?.returnTo&&route.params.returnKey&&previous?.name===destination&&previous.key===route.params.returnKey)navigation.goBack();
    else navigation.navigate(destination);
  };
  return <NativePage page={page} focused={focused} testID={testID} onLayout={onLayout} style={{flex:1}}
    onBack={()=>navigation.goBack()} onNavigate={event=>open(event.nativeEvent.destination)}/>;
}

export {CustomEntryScreen} from './CustomEntryScreen';

// Preview-only route. Full-app feedback is the shared native-authorized flow.
export function FeedbackSettingsScreen() { return <FeedbackScreen/>; }

export function DeviceQAScreen() {
  const {app, live} = useReview();
  const available=useRef(false);
  // PhoneQAView owns an unpublished configuration buffer. A temporary missing
  // projection conceals that same native host; only explicit availability loss
  // or the enclosing owner boundary retires it.
  if(live)available.current=live.qaTools;
  if (!app || !available.current) return null;
  return <DeviceQANativePage/>;
}

// Only an admitted host owns a viewport ticket. Availability/owner retirement
// disposes its measurement; temporary revocation keeps that same native layout.
function DeviceQANativePage() {
  const navigation=useNavigation();
  const focused=useIsFocused();
  const concealed=useRouteBodyConcealed();
  const onLayout=usePresentationNativeLayout();
  return <NativePage page="phoneQA" focused={focused} testID="device-qa-page" onLayout={onLayout}
    pointerEvents={concealed?'none':'auto'} accessibilityElementsHidden={concealed}
    importantForAccessibility={concealed?'no-hide-descendants':'auto'} style={{flex:1,opacity:concealed?0:1}}
    onBack={() => navigation.goBack()} />;
}
