import {useEffect,useMemo,useState,useSyncExternalStore} from 'react';
import {usePreventRemove,useRoute} from '@react-navigation/native';
import {mayInteractWithPresentation} from '../app/read-cache';
import {FilterScreen} from './FilterScreens';
import {FilterDetailOwnerContext} from './filter-route';
import {LiveRenderBoundary,useReview} from './ReviewContext';

const noSubscribe=()=>()=>{};
export function FilterRoute(){
  const {app,live}=useReview();const route=useRoute();
  const [initialID]=useState(live?.session?.filterID);
  const id=(route.params as {id?:string}|undefined)?.id??initialID;
  const owner=useMemo(()=>({id}),[id]);
  const interactive=useSyncExternalStore(app?.subscribe??noSubscribe,()=>mayInteractWithPresentation(app));
  usePreventRemove(!!app&&!interactive,()=>{});
  useEffect(()=>{
    if(!app||!id)return;
    return()=>{void app.command({type:'filter.close',id}).catch(()=>{});};
  },[app,id]);
  return <FilterDetailOwnerContext.Provider value={owner}><LiveRenderBoundary component={FilterScreen} retainBody directScrollRoot/></FilterDetailOwnerContext.Provider>;
}
