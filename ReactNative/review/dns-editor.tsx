import {createContext,useContext,useLayoutEffect,useRef,useState,type PropsWithChildren} from 'react';
import type {DNSChoice} from '../app/contract';

type Draft={tiers:DNSChoice[];context:string;systemDNS?:DNSChoice|null;systemDNSOriginalID?:string|null};
const Context=createContext<{draft:Draft;setDraft:(value:Draft)=>void}|null>(null);
const emptyDraft:Draft={tiers:[],context:''};
export function DNSEditorProvider({children,retirementKey,available=true}:PropsWithChildren<{retirementKey?:string;available?:boolean}>){
  const owner=useRef({key:retirementKey,available,epoch:0});
  if(owner.current.key!==retirementKey||owner.current.available!==available)owner.current={key:retirementKey,available,epoch:owner.current.epoch+1};
  const epoch=owner.current.epoch;
  const [state,setState]=useState({epoch,draft:emptyDraft});
  const draft=available&&state.epoch===epoch?state.draft:emptyDraft;
  useLayoutEffect(()=>{setState(current=>current.epoch===epoch&&available?current:{epoch,draft:emptyDraft});},[epoch,available]);
  // This provider outlives route bodies. A retired callback cannot republish a
  // DNS draft after a privacy boundary, even if the same scope returns later.
  const setDraft=(value:Draft)=>{if(available&&owner.current.available&&owner.current.epoch===epoch)setState({epoch,draft:value});};
  return <Context.Provider value={{draft,setDraft}}>{children}</Context.Provider>;
}
export function useDNSEditor(){const value=useContext(Context);if(!value)throw new Error('DNS editor unavailable');return value;}
export const sameDNS=(a:DNSChoice,b:DNSChoice)=>a.id===b.id&&(a.id!=='custom-dns'||a.primary.trim().toLowerCase()===b.primary.trim().toLowerCase()&&a.secondary.trim().toLowerCase()===b.secondary.trim().toLowerCase());
export const selection=(choice:DNSChoice)=>({id:choice.id,name:choice.name,primary:choice.primary,secondary:choice.secondary,...(choice.isEnabled===false?{isEnabled:false}:{})});
