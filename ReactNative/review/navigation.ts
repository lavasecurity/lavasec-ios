import {useEffect,useRef} from 'react';
import {AppState} from 'react-native';
import {useIsFocused,useNavigation,usePreventRemove, type NavigationProp} from '@react-navigation/native';
import {Alert} from '../app/presentation';
import {useReview} from './ReviewContext';
import {mayInteractWithPresentation} from '../app/read-cache';

export type ReviewRoutes = {
  Foreground:{id:string};
  Guard: undefined; Settings: undefined; Filters: undefined; Activity: undefined;
  Explore: {part?:import('./connection-model').ConnectionPart;returnTo?:'DNS'|'Filters';returnKey?:string}|undefined;
  Library: undefined; Filter: {id?:string}|undefined; Review: {id?:string;standaloneReview?:string}|undefined; Share: undefined; ShareDetail: {id?:string}|undefined;
  Import: undefined; TopDomains: {start?: number; end?: number} | undefined; History: undefined; Customization: undefined;
  Guardian: undefined; Account: undefined; Upgrade: {reason?:import('./plus-intents').PlusReason;intent?:string;embedded?:boolean}|undefined; DNS: undefined; CustomEntry:{id:string;kind:'dns'|'blocklist'}; DNSPicker:{target:'tier'|'profile';index?:number}; DNSPatch: undefined; Privacy: undefined;
  Security: undefined; Passcode: undefined; Feedback: undefined; DeviceQA: undefined; Legal: undefined; Stats: undefined;
  AutoSwitch: undefined; VPNChaining: {returnTo?:'DNS';returnKey?:string}|undefined; Network: undefined; Components: undefined; AddDomain: {decision: 'blocked' | 'allowed';id?:string};
  AddBlocklist: {id?:string}|undefined; Sudoku: undefined;
};
export function useReviewNavigation(context?: ReviewRoutes['Explore']) {
  const navigation = useNavigation<NavigationProp<ReviewRoutes>>();
  const {app,session} = useReview();
  const focused=useIsFocused();const active=useRef(focused);const pending=useRef(false);const epoch=useRef(0);
  useEffect(()=>{
    active.current=focused;
    const listener=AppState.addEventListener('change',state=>{if(state==='background')++epoch.current;});
    return()=>{++epoch.current;active.current=false;listener.remove();};
  },[focused]);
  // Both forward links and contextual returns use this one authentication/lifetime gate.
  const authorizeThen = (name: keyof ReviewRoutes, action:()=>void) => {
    if(!mayInteractWithPresentation(app))return;
    const surface = name==='Security' ? 'credentials' : ['Activity','TopDomains','History','Stats','Network'].includes(name) ? 'activityViewing'
      : ['Components','Explore','Settings','Account','Upgrade','Customization','Guardian','DNS','DNSPatch','VPNChaining','AutoSwitch','Privacy','DeviceQA'].includes(name) ? 'appSettings' : undefined;
    if (app && surface) {
      if(pending.current||!active.current)return;pending.current=true;const started=epoch.current;
      void app.command({type: 'navigation.authorize', surface}).then(() => {
        if(!active.current||started!==epoch.current||!mayInteractWithPresentation(app))return;
        // Start the authorized local read alongside the native push. The page
        // joins this in-flight read; completed values are never cached in JS.
        const dates=name==='Activity'?app.getSnapshot?.().snapshot?.activityDates:undefined;
        if(dates)void app.command({type:'activity.query',start:dates.start,end:dates.end,hourly:true}).catch(()=>{});
        action();
      }).catch(error => {if(active.current&&mayInteractWithPresentation(app)&&error.message!=='Authentication cancelled.')Alert.alert('Lava', error.message);}).finally(()=>{pending.current=false;});
    } else action();
  };
  const navigate: typeof navigation.navigate = (...args: Parameters<typeof navigation.navigate>) => {
    const name = typeof args[0] === 'string' ? args[0] : args[0].name;
    authorizeThen(name,()=>navigation.navigate(...args));
  };
  // Register source-owned return work only when authorization actually permits
  // this push. A cancelled or retired navigation must not retain its callback.
  const navigateToUpgrade = (params:()=>ReviewRoutes['Upgrade']) => {
    authorizeThen('Upgrade',()=>navigation.navigate('Upgrade',params()));
  };
  // React Navigation owns removal interception, covering the contextual link,
  // native back button, Android back and iOS swipe without replacing native chrome.
  // An unprotected return retains its ordinary synchronous native transition.
  usePreventRemove(!!app&&context?.returnTo==='DNS'&&!!context.returnKey&&!!session?.protectedActions['Update App Settings'],({data})=>{
    const state=navigation.getState();const origin=state.routes[state.index];const previous=state.routes[state.index-1];
    if(!previous||!origin||!['GO_BACK','POP','POP_TO','POP_TO_TOP'].includes(data.action.type)||previous.name!==context?.returnTo||previous.key!==context?.returnKey){
      navigation.dispatch(data.action);return;
    }
    authorizeThen(previous.name,()=>{
      const current=navigation.getState();
      if(current.routes[current.index]?.key===origin?.key&&current.routes[current.index-1]?.key===previous.key)navigation.dispatch(data.action);
    });
  });
  return {...navigation, navigate, navigateToUpgrade};
}
export const previewNotice = () => Alert.alert('UI review build', 'This build previews Lava’s interface. It does not start a VPN, change production filters, authenticate, make purchases, or send reports. Changes in this review session are discarded when you close it.');
