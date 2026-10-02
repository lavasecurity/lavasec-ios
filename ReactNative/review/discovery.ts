import {useEffect} from 'react';
import {useIsFocused} from '@react-navigation/native';
import type {DiscoveryID} from '../app/contract';
import {useReview} from './ReviewContext';

// A retained/background route must not consume its discovery indicator.
// This records presentation only, independently of feature setup or permissions.
export function useDiscoveryVisit(id: DiscoveryID | undefined) {
  const {app,live}=useReview();
  const focused=useIsFocused();
  const unseen=id!==undefined&&live?.discoveries?.[id]===true;
  useEffect(()=>{
    if(focused&&unseen&&id) void app?.command({type:'discovery.seen',target:id}).catch(()=>{});
  },[app,focused,id,unseen]);
}
