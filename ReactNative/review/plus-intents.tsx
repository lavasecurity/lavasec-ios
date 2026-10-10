import {createContext,useContext,useEffect,useMemo,type ReactNode} from 'react';

export const plusMessages = {
  customBlocklist:'Upgrade to Lava Plus to add your blocklists',
  customDNS:'Upgrade to Lava Plus to add custom DNS',
  blockedDomains:'Upgrade to Lava Plus to block more domains',
  allowedDomains:'Upgrade to Lava Plus to add more exceptions',
  rules:'Upgrade to Lava Plus to use more blocklist rules',
  filters:'Upgrade to Lava Plus to add more filters',
  frozenFilter:'Upgrade to Lava Plus to manage this filter',
  guards:'Upgrade to Lava Plus to unlock all Lava Guards',
  vpn:'Upgrade to Lava Plus to use VPN chaining',
  fullImport:'Use Lava Plus for full import',
} as const;
export type PlusReason = keyof typeof plusMessages;
export type PlusDestination = {name:'CustomEntry';params:{id:string;kind:'dns'|'blocklist'}}|{name:'Filter';params:{id:string}}|{name:'Review';params:{id:string;standaloneReview:string}};
export type PlusResume = () => Promise<PlusDestination|void>;
// Callbacks stay with the mounted source screen, never in persisted navigation
// params. Privacy-owner retirement and source removal discard pending work.
let plusIntentSerial=0;
export class PlusIntents {
  private pending=new Map<string,PlusResume>();
  add(resume:PlusResume){const id=String(++plusIntentSerial);this.pending.set(id,resume);return id;}
  remove(id:string){this.pending.delete(id);}
  take(id:string){const resume=this.pending.get(id);this.pending.delete(id);return resume;}
  clear(){this.pending.clear();}
}
const context=createContext<PlusIntents|null>(null);
export function PlusIntentProvider({retirementKey,children}:{retirementKey?:string;children:ReactNode}){
  const intents=useMemo(()=>new PlusIntents(),[retirementKey]);
  useEffect(()=>()=>intents.clear(),[intents]);
  return <context.Provider value={intents}>{children}</context.Provider>;
}
export function usePlusIntents(){return useContext(context)!;}
