import {useEffect,useRef,useState,useSyncExternalStore} from 'react';
import {AppState} from 'react-native';
import {useIsFocused,useNavigation,useRoute} from '@react-navigation/native';
import {mayInteractWithPresentation} from '../app/read-cache';
import {usePresentationReadiness} from '../app/use-presentation-readiness';
import {useReview} from './ReviewContext';

const noSubscribe=()=>()=>{};

/** The native Settings grant admits this retained route; a promise never does. */
export function useVPNPageAdmission(){
  const {app,live}=useReview();const focused=useIsFocused();
  const route=useRoute();const navigation=useNavigation();
  const [phase,setPhase]=useState(AppState.currentState);
  const [retry,setRetry]=useState(0);const [finished,setFinished]=useState(0);
  const [denied,setDenied]=useState<string>();const [failed,setFailed]=useState<string>();
  const lifecycle=useRef(0);const retirement=useRef(0);const mounted=useRef(true);
  const focusOwner=useRef({focused,generation:0});
  if(focusOwner.current.focused!==focused)focusOwner.current={focused,generation:focusOwner.current.generation+1};
  const pending=useRef<{scope:string;retirement:number}|undefined>(undefined);
  const appOwner=useRef({app,generation:0});
  if(appOwner.current.app!==app)appOwner.current={app,generation:appOwner.current.generation+1};
  const interactive=useSyncExternalStore(app?.subscribe??noSubscribe,()=>mayInteractWithPresentation(app));
  const authorized=live?.vpn?.authorized===true;
  const active=phase==='active';
  // This native modal has an independent navigator, so its underlying RN route
  // remains focused. Only the published public visit identity crosses a read
  // pause; it keeps the parent inert without authorizing either presentation.
  const childOwner=useRef({app,id:undefined as string|undefined,generation:0});
  if(childOwner.current.app!==app)childOwner.current={app,id:undefined,generation:childOwner.current.generation+1};
  if(live){
    const id=live.foregroundFlow?.kind==='vpnConfiguration'?live.foregroundFlow.id:undefined;
    if(childOwner.current.id!==id)childOwner.current={app,id,generation:childOwner.current.generation+1};
  }
  const parentFocused=focused&&!childOwner.current.id;
  const hasPublishedNativeChild=()=>app?.getSnapshot?.().snapshot?.foregroundFlow?.kind==='vpnConfiguration';
  // Concealment removes the projection, not the identity of the pending native
  // authentication. Retain only its public owner/revision fence until fresh
  // native fields replace it; this grants no display or input authority.
  const securityOwner=useRef([live?.security?.ownerRevision,live?.security?.readRevision]);
  if(live)securityOwner.current=[live.security?.ownerRevision,live.security?.readRevision];
  // A biometric prompt transiently makes the app inactive. Its one native
  // request survives that display pause; backgrounding or an actual route,
  // owner or security-turn replacement retires the request instead.
  const requestScope=JSON.stringify([appOwner.current.generation,route.key,securityOwner.current,
    focusOwner.current.generation,retirement.current,childOwner.current.id,childOwner.current.generation]);
  const scope=JSON.stringify([requestScope,focused,phase,lifecycle.current]);
  const current=useRef({scope,requestScope,focused:parentFocused,app});
  current.current={scope,requestScope,focused:parentFocused,app};
  const ready=authorized||denied===requestScope||failed===requestScope;
  const presentationAuthority=usePresentationReadiness(app,!!app&&parentFocused&&active,ready,scope);
  const authoritative=presentationAuthority&&!!live;

  useEffect(()=>{
    mounted.current=true;
    const listener=AppState.addEventListener('change',value=>{
      // Invalidate callbacks before React processes the lifecycle render.
      if(value!=='active')++lifecycle.current;
      if(value!=='active'&&value!=='inactive')++retirement.current;
      setPhase(value);
    });
    return()=>{mounted.current=false;++retirement.current;admitted.current=false;listener.remove();};
  },[]);

  useEffect(()=>{
    if(!app||!parentFocused||!active||!authoritative||authorized||denied===requestScope||failed===requestScope||pending.current)return;
    const attempt={scope:requestScope,retirement:retirement.current};pending.current=attempt;
    const isCurrent=()=>{
      const state=navigation.getState();
      return mounted.current&&pending.current===attempt&&retirement.current===attempt.retirement
        &&current.current.app===app&&current.current.requestScope===attempt.scope&&current.current.focused
        &&!hasPublishedNativeChild()
        &&!!state&&state.routes[state.index]?.key===route.key;
    };
    void app.command({type:'vpn.enter'}).catch((error:Error)=>{
      if(isCurrent()){
        if(error.message==='Authentication cancelled.')setDenied(attempt.scope);
        else setFailed(attempt.scope);
      }
    }).finally(()=>{
      if(pending.current===attempt)pending.current=undefined;
      // A retired request can complete after the next focused visit has mounted.
      // Only then may that visit request fresh native evidence.
      if(mounted.current&&current.current.requestScope!==attempt.scope)setFinished(value=>value+1);
    });
  },[app,parentFocused,active,authoritative,authorized,requestScope,retry,finished,denied,failed,navigation,route.key]);

  useEffect(()=>{
    // Settle the covered presentation first. The enclosing native route blocks
    // removal while hydration is pending; cancelling must leave this exact page
    // after that fence opens, with its protected controls still closed.
    if(denied!==requestScope||!parentFocused||!active||!interactive||authorized||hasPublishedNativeChild())return;
    const state=navigation.getState();
    if(state&&state.routes[state.index]?.key===route.key)navigation.goBack();
  },[denied,requestScope,parentFocused,active,interactive,authorized,navigation,route.key]);

  const parentPresentationAvailable=!!app&&focused&&active&&authoritative&&authorized&&interactive;
  const canInteract=parentFocused&&parentPresentationAvailable;
  // Native child ownership revokes parent input, not current authorized paint.
  // During a read pause only an explicit opt-out may retain accepted paint;
  // protected/unknown policy or absent grants conceal it. The independently
  // presented child alone owns accessible privacy controls.
  const coverAccessibilityHidden=!!childOwner.current.id;
  const coverRequired=!parentPresentationAvailable&&!(coverAccessibilityHidden&&authorized
    &&app?.getSnapshot?.().privacyCoverRequired===false);
  const admitted=useRef(canInteract);admitted.current=canInteract;
  return {canInteract,coverRequired,coverAccessibilityHidden,canRetry:failed===requestScope,
    isAdmitted:()=>admitted.current&&current.current.app===app&&current.current.scope===scope&&AppState.currentState==='active'&&!hasPublishedNativeChild(),
    retry:()=>{setDenied(undefined);setFailed(undefined);setRetry(value=>value+1);}};
}
