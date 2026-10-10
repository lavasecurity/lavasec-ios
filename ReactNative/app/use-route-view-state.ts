import {useCallback,useLayoutEffect,useRef,useState,type Dispatch,type SetStateAction} from 'react';
import {AppState} from 'react-native';
import {useOptionalReview} from '../review/ReviewContext';

/** Permitted transient presentation state belongs to the retained route visit.
 * Its owner boundary retires the hook on account/policy replacement. This is
 * never a cache for query values, credentials, or native confidential inputs.
 * The optional third callback only restores the initial value for internal
 * lifecycle cleanup of this mounted visit; never attach it to user actions. */
export function useRouteViewState<T>(initial:T|(()=>T)):[T,Dispatch<SetStateAction<T>>,()=>void] {
  const review=useOptionalReview();const app=review?.app;
  const epoch=app?.getReadEpoch?.();
  const [value,setValue]=useState(initial);
  const initialValue=useRef(value);
  const owner=useRef({mounted:true,app});
  const currentApp=useRef(app);currentApp.current=app;
  useLayoutEffect(()=>{owner.current.mounted=true;return()=>{owner.current.mounted=false;};},[]);
  const resetForLifecycle=useCallback(()=>{
    if(owner.current.mounted&&owner.current.app===currentApp.current)setValue(initialValue.current);
  },[]);
  const setCurrent:Dispatch<SetStateAction<T>>=next=>{
    if(app&&typeof app.getSnapshot==='function'&&(AppState.currentState!=='active'
      ||!review?.live||!app.getSnapshot().snapshot||app.getReadEpoch?.()!==epoch))return;
    setValue(next);
  };
  return [value,setCurrent,resetForLifecycle];
}
