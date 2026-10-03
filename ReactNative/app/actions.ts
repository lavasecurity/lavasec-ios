import {Alert} from './presentation';
import {AccessibilityInfo} from 'react-native';
import {useCallback,useSyncExternalStore} from 'react';
import type {AppStore} from './store';
import {useReview} from '../review/ReviewContext';
import type {AppCommand} from './contract';
import {mayInteractWithPresentation} from './read-cache';
import {previewNotice} from '../review/navigation';
export function useAppAction() {
  const {app} = useReview();
  return (command: AppCommand) => {
    if (!app) {previewNotice(); return;}
    if(!mayInteractWithPresentation(app))return Promise.resolve();
    return app.command(command).then(result => {
      if (command.type === 'logs.clear' && typeof result === 'string') AccessibilityInfo.announceForAccessibility(result);
    }).catch(error => {if(mayInteractWithPresentation(app))Alert.alert('Lava',error.message);});
  };
}


type ExclusiveActionGroup='purchase'|'signIn'|'backup';
type PendingActions={groups:Set<ExclusiveActionGroup>;listeners:Set<()=>void>};
// App-scoped so navigating away and recreating a screen cannot replay a queued
// intent. Weak ownership keeps a discarded app store from retaining UI state.
const pendingActions=new WeakMap<AppStore,PendingActions>();
function actionsFor(app:AppStore):PendingActions {
  let state=pendingActions.get(app);
  if(!state){state={groups:new Set(),listeners:new Set()};pendingActions.set(app,state);}
  return state;
}

// These native action groups disable sibling controls while working. Claim
// before AppStore queues the command, including time waiting for another command
// or authentication; the later native busy snapshot cannot close that window.
export function useExclusiveAppAction(group:ExclusiveActionGroup,nativeBusy=false) {
  const {app}=useReview();const state=app?actionsFor(app):undefined;
  const subscribe=useCallback((listener:()=>void)=>{state?.listeners.add(listener);return()=>{state?.listeners.delete(listener);};},[state]);
  const getPending=useCallback(()=>state?.groups.has(group)??false,[state,group]);
  const pending=useSyncExternalStore(subscribe,getPending);
  const notify=()=>{for(const listener of [...state!.listeners])listener();};
  const run=(command:AppCommand)=>{
    if(nativeBusy||state?.groups.has(group))return Promise.resolve();
    if(!app||!state){previewNotice();return Promise.resolve();}
    if(!mayInteractWithPresentation(app))return Promise.resolve();
    state.groups.add(group);notify();
    return (async()=>{
      try{await app.command(command);}
      catch(error){if(mayInteractWithPresentation(app)&&(error as Error).message!=='Authentication cancelled.')Alert.alert('Lava',(error as Error).message);}
      finally{state.groups.delete(group);notify();}
    })();
  };
  return {run,busy:pending||nativeBusy,isBusy:()=>nativeBusy||getPending()};
}
