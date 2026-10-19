import {useCallback,useEffect,useRef,useState} from 'react';
import {AppState} from 'react-native';
import {useIsFocused} from '@react-navigation/native';
import {isPresentationCancellation,localized} from '../app/presentation';
import {mayInteractWithPresentation} from '../app/read-cache';
import type {ActivityDates} from '../specs/NativeLavaReview';
import {useReview} from './ReviewContext';
import type {ActivityChartKind,ActivityShareCardContent} from './ActivityShareCard';

export function useActivityShare({dates,chart,period,loaded}:{dates:ActivityDates|null;chart:ActivityChartKind;period:ActivityShareCardContent['period'];loaded:boolean}) {
  const {app}=useReview();const focused=useIsFocused();
  const mounted=useRef(true),focus=useRef(focused);focus.current=focused;
  const request=useRef(0),pending=useRef(false),sharing=useRef<string|undefined>(undefined);
  const [content,setContent]=useState<ActivityShareCardContent>();
  const [cardReady,setCardReady]=useState(false);
  const [busy,setBusy]=useState(false),[error,setError]=useState<string>();
  const epoch=app?.getReadEpoch?.();
  const retire=useCallback(()=>{++request.current;pending.current=false;sharing.current=undefined;setContent(undefined);setCardReady(false);setBusy(false);},[]);
  useEffect(()=>{mounted.current=true;const listener=AppState.addEventListener('change',state=>{if(state!=='active')retire();});
    return()=>{mounted.current=false;++request.current;listener.remove();};},[retire]);
  useEffect(()=>{retire();},[focused,epoch,dates?.start,dates?.end,chart,period,retire]);
  const canAct=()=>mounted.current&&focus.current&&mayInteractWithPresentation(app);
  const fail=(reason:Error)=>{if(mounted.current&&!isPresentationCancellation(reason.message))setError(localized(reason.message));};
  const exportChart=()=>{
    if(!app||!dates||!loaded||pending.current||!canAct())return;
    const id=++request.current;const readEpoch=app.getReadEpoch?.();
    pending.current=true;setBusy(true);setError(undefined);
    void app.command<ActivityShareCardContent>({type:'activity.card.query',start:dates.start,end:dates.end,hourly:period==='today',chart,period})
      .then(value=>{if(id!==request.current)return;if(canAct()&&readEpoch===app.getReadEpoch?.())setContent(value);else retire();})
      .catch(reason=>{if(id===request.current){fail(reason);retire();}});
  };
  // Passive effects run after the Surface's ready prop commits. Calling native
  // capture directly from the child's RAF callback races its registry update.
  useEffect(()=>{
    if(!cardReady||!content||!app||sharing.current===content.token||!canAct())return;
    const id=request.current;sharing.current=content.token;
    void app.command({type:'activity.share',token:content.token})
      .catch(reason=>{if(id===request.current)fail(reason);})
      .finally(()=>{if(id===request.current&&mounted.current)retire();});
  },[app,content,cardReady,retire]);
  return {content,busy,error,exportChart,ready:setCardReady};
}
