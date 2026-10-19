import {useEffect,useRef} from 'react';
import {AppState,type AlertButton} from 'react-native';
import type {AppStore} from '../app/store';
import type {NativeFlowAlertOwner,NativeFlowAlertRequest} from '../app/contract';
import {isPresentationCancellation,localized} from '../app/presentation';
import {mayInteractWithPresentation} from '../app/read-cache';

type Options={tint?:'app'|'confirmation';verbatimTitle?:boolean;verbatimMessage?:boolean;onRetire?:()=>void};
const requestID=()=> 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g,char=>{
  const value=Math.floor(Math.random()*16);return (char==='x'?value:(value&3)|8).toString(16);
});

/** Scoped system-alert island for migrated iOS flows. Existing RN Alert defaults
 * stay independent. A result selects a local callback, never a native mutation. */
export function useNativeFlowAlert(app:AppStore|undefined,owner:NativeFlowAlertOwner,active=true){
  const key=JSON.stringify(owner);
  const renderedEpoch=app?.getReadEpoch?.();
  const current=useRef({app,key,active});current.current={app,key,active};
  const pending=useRef(new Map<string,{owner:NativeFlowAlertOwner;epoch:number;onRetire?:()=>void}>());
  useEffect(()=>{
    if(current.current.app===app&&current.current.key===key)current.current.active=active;
    const cancel=()=>{
      const requests=[...pending.current];pending.current.clear();
      for(const [id,request] of requests){
        void app?.command({type:'presentation.flowAlert.cancel',owner:request.owner,requestID:id}).catch(()=>{});
        request.onRetire?.();
      }
    };
    if(!active)cancel();
    const subscription=AppState.addEventListener('change',phase=>{if(phase!=='active')cancel();});
    const unsubscribe=app?.subscribe?.(()=>{
      if(!mayInteractWithPresentation(app)||[...pending.current.values()].some(request=>request.epoch!==app.getReadEpoch()))cancel();
    });
    return()=>{
      if(current.current.app===app&&current.current.key===key)current.current.active=false;
      subscription.remove();unsubscribe?.();cancel();
    };
  },[app,key,active]);
  return (title:string,message='',buttons:AlertButton[]=[{text:'OK',style:'cancel'}],options:Options={})=>{
    if(!app||!active||current.current.app!==app||current.current.key!==key||!current.current.active||!mayInteractWithPresentation(app)
      ||renderedEpoch!==app.getReadEpoch?.()||isPresentationCancellation(message))return false;
    const snapshot=app.getSnapshot?.().snapshot,revision=snapshot?.security?.readRevision,token=snapshot?.presentationToken;
    if(!Number.isSafeInteger(revision)||!token||!app.getReadEpoch)return false;
    const id=requestID(),epoch=app.getReadEpoch();
    const request:NativeFlowAlertRequest={type:'presentation.flowAlert',owner,requestID:id,readRevision:revision!,presentationToken:token,
      title:options.verbatimTitle?title:localized(title),message:options.verbatimMessage?message:localized(message),tint:options.tint??'app',
      buttons:buttons.map((button,index)=>({id:String(index),title:localized(button.text??''),role:button.style??'default'})),
      ...(buttons.some(button=>button.isPreferred)?{preferred:String(buttons.findIndex(button=>button.isPreferred))}:{})};
    pending.current.set(id,{owner,epoch,onRetire:options.onRetire});
    void app.command<string|null>(request).then(selected=>{
      if(!pending.current.delete(id))return;
      if(current.current.app!==app||current.current.key!==key||!current.current.active
        ||app.getReadEpoch()!==epoch||!mayInteractWithPresentation(app)||selected===null){options.onRetire?.();return;}
      const index=request.buttons.findIndex(button=>button.id===selected);
      if(index>=0)buttons[index]?.onPress?.();else options.onRetire?.();
    }).catch(()=>{if(pending.current.delete(id))options.onRetire?.();});
    return true;
  };
}
