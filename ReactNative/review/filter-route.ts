import {useEffect, useState,useSyncExternalStore} from 'react';
import {usePresentationReadiness} from '../app/use-presentation-readiness';
import {mayInteractWithPresentation} from '../app/read-cache';
import {useIsFocused, useNavigation, useRoute} from '@react-navigation/native';
import {useReview} from './ReviewContext';

// Native filter selection is shared with automation and other tabs. A retained
// detail owns its opened identity; editing sheets must never adopt a new target.
export function useFilterRoute(restoreDetail=false) {
  const {app,live}=useReview();
  const route=useRoute();const navigation=useNavigation();const focused=useIsFocused();
  const [initialID]=useState(live?.session?.filterID);
  const id=(route.params as {id?:string}|undefined)?.id??initialID;
  const exists=live?.newFilter?.id===id||live?.filters?.some(filter=>filter.id===id)!==false;
  const frozen=live?.filters?.find(filter=>filter.id===id)?.frozen??false;
  const editing=live?.session?.editing;
  const selected=live?.session?.filterID;
  const ready=!app||!!id&&exists&&selected===id&&(restoreDetail||!!editing);
  const scope=JSON.stringify([id,exists,restoreDetail]);const [failedScope,setFailedScope]=useState<string>();
  const prepared=ready&&!(restoreDetail&&frozen&&editing);
  const authoritative=usePresentationReadiness(app,focused&&!!app,prepared||!id||!exists||!restoreDetail&&!editing||failedScope===scope||!!live?.filterPreparationPresented,scope);
  const interactive=useSyncExternalStore(app?.subscribe??(()=>()=>{}),()=>mayInteractWithPresentation(app));
  useEffect(()=>{
    if(!app||!focused||!authoritative)return;
    const close=()=>{if(mayInteractWithPresentation(app))navigation.goBack();};
    if(failedScope===scope){close();return;}
    if(!id||!exists){close();return;}
    if(live?.filterPreparationPresented)return;
    if(!restoreDetail&&!editing){close();return;}
    if(selected===id&&!(restoreDetail&&frozen&&editing))return;
    if(!restoreDetail){close();return;}
    let current=true;
    void app.command({type:'filter.open',id}).catch(()=>{if(current)setFailedScope(scope);});
    return()=>{current=false;};
  },[app,focused,id,exists,selected,restoreDetail,frozen,editing,live?.filterPreparationPresented,navigation,authoritative,interactive,failedScope,scope]);
  useEffect(()=>{
    if(!app||!restoreDetail||!id)return;
    return()=>{void app.command({type:'filter.close',id}).catch(()=>{});};
  },[app,restoreDetail,id]);
  return {id,ready};
}
