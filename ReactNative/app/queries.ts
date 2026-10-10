import {useEffect, useRef, useState, useSyncExternalStore} from 'react';
import {AppState} from 'react-native';
import {useIsFocused} from '@react-navigation/native';
import {useReview} from '../review/ReviewContext';
import type {AppCommand} from './contract';
import {appReadCache, clearAppReadCache, mayCacheRead, readPrivacyScope, readDisplayScope, mayRetainPresentationFrame} from './read-cache';
import {usePresentationAuthority,usePresentationReadiness} from './use-presentation-readiness';

export function useAppQuery<T>(command: AppCommand | null, retentionKey?: string, retainThroughInactivity=false) {
  const {app,live} = useReview(); const focused = useIsFocused();
  const invalidation = useSyncExternalStore(app?.subscribe ?? (() => () => {}), app?.getInvalidation ?? (() => 0));
  const authoritative=usePresentationAuthority(app);
  const refreshHandle=useRef<()=>Promise<void>>(()=>Promise.resolve());
  const key = JSON.stringify(command);
  const identity = JSON.stringify([live ? readPrivacyScope(live) : 'unknown', app?.getReadEpoch?.() ?? 0]);
  // A read/grant epoch invalidates readers, not pixels already painted under an
  // explicit off choice. Ownership, source/clear revision, settings and the exact
  // query (including period/search/filter) still define that frame's identity.
  const displayScope=JSON.stringify([live?readDisplayScope(live):'unknown',key,retentionKey]);
  const displayAllowed=mayRetainPresentationFrame(live)&&!!command;
  const cacheable = mayCacheRead(command, live);
  // Native owns reusable query data. Caller retention hints cannot opt into the
  // display exception. Only native-confirmed off keeps an already-painted value;
  // it provides no read or cache authority to any page, including sharing.
  const retainUnprotectedResult = false;
  retainThroughInactivity = false;
  const cache = app && cacheable ? appReadCache(app) : undefined;
  const cacheKey = [command?.type ?? 'disabled', retentionKey ?? null, key, identity, invalidation];
  const cached = cache?.peek<T>(cacheKey);
  const [state,setState] = useState<{key: string; retentionKey?: string; identity: string; displayScope:string; displayAllowed:boolean; value?: T; error?: string}>({key,retentionKey,identity,displayScope,displayAllowed:false,value:cached});
  // A mounted, authorized foreground list may keep its rows while selection,
  // search or pagination changes within the caller's explicit retention scope.
  // This does not widen the exact-query frame retained through inactivity.
  const canRetainForeground=(previous:typeof state)=>focused&&authoritative&&AppState.currentState==='active'
    &&!!command&&retentionKey!==undefined&&previous.retentionKey===retentionKey&&previous.identity===identity
    &&(!previous.displayAllowed||displayAllowed);
  const current = state.identity === identity && state.key === key && state.retentionKey === retentionKey;
  const settled=current&&(state.value!==undefined||state.error!==undefined);
  usePresentationReadiness(app,focused&&!!command,settled,JSON.stringify([key,identity,retentionKey]));
  useEffect(() => {
    const empty={key,retentionKey,identity,displayScope,displayAllowed:false};
    if (!app || !command) {setState(empty);return;}
    if (!focused && !cacheable) {
      setState(previous=>displayAllowed&&previous.displayAllowed&&previous.displayScope===displayScope
        ?{...previous,error:undefined}:empty);
      return;
    }
    setState(previous=>previous.displayAllowed&&(!displayAllowed
      ||previous.displayScope!==displayScope&&!canRetainForeground(previous))?empty:previous);
    const cached = cache?.peek<T>(cacheKey);
    if (cached !== undefined) setState({...empty,value:cached});
    const canRead=()=>AppState.currentState==='active'&&(app.getSnapshot ? app.getSnapshot().snapshot!==null : true);
    let current = true, foreground = canRead(), generation = 0, inFlight = false, cancelled = false;
    let timer: ReturnType<typeof setTimeout> | undefined;
    let waitingForRead: (()=>void)[] = [];
    const refresh = async () => {
      if (!focused || !current || !foreground || !canRead() || cancelled) return;
      if (inFlight) {await new Promise<void>(resolve=>waitingForRead.push(resolve));return;}
      inFlight=true;
      const started=generation;
      try {const read=()=>app.command<T>(JSON.parse(key)); const value=await (cache ? cache.read(cacheKey,read) : read()); if(current&&foreground&&canRead()&&started===generation)setState({key,retentionKey,identity,displayScope,displayAllowed,value});}
      catch(error) {
        if(!current)return;
        const message=(error as Error).message;
        if(foreground && (started===generation || message==='Authentication cancelled.'))setState(previous => {
          const sameScope = previous.identity === identity && (previous.key === key && previous.retentionKey === retentionKey
            || retentionKey !== undefined && previous.retentionKey === retentionKey);
          const sameDisplay=displayAllowed&&previous.displayAllowed&&previous.displayScope===displayScope;
          const value = (sameDisplay||sameScope&&command.type!=='share.query')&&message!=='Authentication cancelled.' ? previous.value : undefined;
          // Rows from a failed foreground scope change are still the previous
          // query's result; they cannot become the new query's inactive frame.
          return {key,retentionKey,identity,displayScope,displayAllowed:value!==undefined&&sameDisplay,value,error:message};
        });
        if(message === 'Authentication cancelled.' || command.type === 'share.query') clearAppReadCache(app);
        // Cancelling the native credential UI ends this polling attempt. A new
        // focus, query scope or native mutation can explicitly start another.
        cancelled=message==='Authentication cancelled.';
      } finally {inFlight=false;const waiting=waitingForRead;waitingForRead=[];waiting.forEach(finish=>finish());}
      if(!current||!foreground||cancelled)return;
      if(started!==generation) {
        // A native credential prompt may itself make the app inactive. Wait for
        // that request to settle before re-querying; never overlap prompts or
        // immediately re-prompt after cancellation.
        void refresh();
      } else {
        timer=setTimeout(refresh,5000);
      }
    };
    const manualRefresh=async()=>{cancelled=false;if(timer)clearTimeout(timer);await refresh();};
    refreshHandle.current=manualRefresh;
    const subscription=AppState.addEventListener('change',next=>{
      const wasForeground=foreground;
      foreground=next==='active'&&canRead();
      if(!foreground) {
        ++generation;
        if(timer)clearTimeout(timer);
        if (!retainThroughInactivity || retainUnprotectedResult) clearAppReadCache(app);
        if (!retainThroughInactivity) setState(previous=>displayAllowed&&previous.displayAllowed&&previous.displayScope===displayScope
          ?{...previous,error:undefined}:empty);
        else setState(current=>({...current}));
      } else if(!wasForeground) {
        setState(current=>({...current}));
        if(cancelled)setState({...empty,error:'Authentication cancelled.'});
        else void refresh();
      }
    });
    void refresh();
    return () => {current=false;if(refreshHandle.current===manualRefresh)refreshHandle.current=()=>Promise.resolve();subscription.remove();if(timer)clearTimeout(timer);};
  },[app,focused,key,invalidation,retentionKey,retainThroughInactivity,cacheable,identity,authoritative,displayScope,displayAllowed]);
  // Retain only when the caller explicitly identifies the same data scope.
  // Different accounts, decisions, ranges or disabled logs must not reuse it.
  const retained = canRetainForeground(state);
  const displayRetained=displayAllowed&&state.displayAllowed&&state.displayScope===displayScope;
  const visible=(focused||cacheable||displayRetained)&&command&&(AppState.currentState==='active'&&authoritative||displayRetained);
  // The delayed-read simulator fixture records lifecycle flags only. Never log
  // query arguments, identity strings, returned data or error messages.
  useEffect(()=>{
    if(live?.traceQueries)console.info('LAVA_QUERY_TRACE '+JSON.stringify({
      type:command?.type,focused,cacheable,lifecycle:AppState.currentState,
      readEpoch:app?.getReadEpoch?.(),invalidation,cached:cached!==undefined,
      sameIdentity:state.identity===identity,current,accepted:state.value!==undefined,
      failed:state.error!==undefined,visible:!!visible,
    }));
  });
  return {key, refresh:()=>refreshHandle.current(), value: visible ? cached ?? ((current || retained || displayRetained) ? state.value : undefined) : undefined,
    error: visible&&current&&authoritative ? state.error : undefined, refreshing: !!command&&!settled&&!displayRetained};
}
