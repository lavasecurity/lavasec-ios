import {useEffect,useState} from 'react';
import {Text,View} from 'react-native';
import {act,render,renderHook} from '@testing-library/react-native';
import {LiveRenderBoundary,ReviewContext,type ReviewState,usePreviewFixtureState} from '../review/ReviewContext';
import {initialSession} from '../review/session';
import {useDNSEditor} from '../review/dns-editor';
import type {AppSnapshot} from '../app/contract';

test('production fixture setters cannot retain native drafts or filter names',()=>{
  const hook=renderHook(({enabled}:{enabled:boolean})=>usePreviewFixtureState(enabled),{initialProps:{enabled:false}});
  act(()=>{
    hook.result.current.setDraft({blocked:['private.example'],allowed:[]});
    hook.result.current.setSavedDraft({blocked:[],allowed:['secret.example']});
    hook.result.current.setSession({...initialSession(),filter:'Private filter',shareFilter:'Private share'});
  });
  hook.rerender({enabled:true});
  expect(hook.result.current.draft).toEqual({blocked:[],allowed:[]});
  expect(hook.result.current.savedDraft).toEqual({blocked:[],allowed:[]});
  expect(hook.result.current.session.filter).toBe('Balanced');
  expect(hook.result.current.session.shareFilter).toBe('Balanced');
});

test('isolated fixture edits remain usable and are cleared when leaving review mode',()=>{
  const hook=renderHook(({enabled}:{enabled:boolean})=>usePreviewFixtureState(enabled),{initialProps:{enabled:true}});
  act(()=>hook.result.current.setDraft({blocked:['example.test'],allowed:[]}));
  expect(hook.result.current.draft.blocked).toEqual(['example.test']);
  hook.rerender({enabled:false});
  expect(hook.result.current.draft.blocked).toEqual([]);
  hook.rerender({enabled:true});
  expect(hook.result.current.draft.blocked).toEqual([]);
});

test('revocation discards private route state while keeping its owning navigation shell mounted',()=>{
  let epoch=0,bodyMounts=0,shellMounts=0;
  const destroyed=jest.fn();
  let updatePrivate!:(value:string)=>void;
  function Body(){
    const [value,setValue]=useState('fresh native value');updatePrivate=setValue;
    useEffect(()=>{bodyMounts++;return destroyed;},[]);
    return <Text>{value}</Text>;
  }
  function NativeRouteShell(){
    const [route]=useState('Guard / Filters / Share');
    useEffect(()=>{shellMounts++;},[]);
    return <View><Text>{route}</Text><LiveRenderBoundary component={Body}/></View>;
  }
  const app={getReadEpoch:()=>epoch};
  const view=(live:object|undefined)=><ReviewContext.Provider value={{app,live} as ReviewState}><NativeRouteShell/></ReviewContext.Provider>;
  const screen=render(view({}));
  act(()=>updatePrivate('previous QR secret'));
  expect(screen.getByText('previous QR secret')).toBeTruthy();
  epoch++;screen.rerender(view(undefined));
  expect(screen.queryByText('previous QR secret')).toBeNull();
  expect(destroyed).toHaveBeenCalledTimes(1);
  expect(screen.getByText('Guard / Filters / Share')).toBeTruthy();
  screen.rerender(view({}));
  expect(screen.getByText('fresh native value')).toBeTruthy();
  expect(bodyMounts).toBe(2);expect(shellMounts).toBe(1);
  act(()=>updatePrivate('second QR secret'));
  // Ordinary grant revisions must not reset range/scroll/form navigation state.
  epoch++;screen.rerender(view({}));
  expect(screen.getByText('second QR secret')).toBeTruthy();
  expect(bodyMounts).toBe(2);
  // Inactivity clears the owned body; query-policy changes clear query values
  // without remounting the screen or jumping its scroll position.
  screen.rerender(view(undefined));
  expect(screen.queryByText('second QR secret')).toBeNull();
  expect(bodyMounts).toBe(2);expect(shellMounts).toBe(1);
});

test('the shared DNS editor preserves an all-off draft through routine read revocation',()=>{
  let editor!:ReturnType<typeof useDNSEditor>;
  function Body(){editor=useDNSEditor();return <Text>{editor.draft.tiers[0]?.primary??'empty'}</Text>;}
  const live={backgroundPrivacyCoverRequired:false,session:initialSession(),account:{status:'Connected'},security:{unavailable:false,readRevision:1,sourceRevision:'source-1',ownerRevision:'owner-1',displayClearRevision:'clear-1'}} as unknown as AppSnapshot;
  const app={};const view=(snapshot:AppSnapshot)=><ReviewContext.Provider value={{app,live:snapshot} as ReviewState}><Body/></ReviewContext.Provider>;
  const screen=render(view(live));
  act(()=>editor.setDraft({context:'owner',tiers:[{id:'private',name:'Private resolver',primary:'private-resolver.example',secondary:'',transport:'DoH',metadata:''}]}));
  screen.rerender(view({...live,account:{...live.account,status:'Refreshing'},session:{...live.session,passcode:!live.session.passcode},security:{...live.security,readRevision:2,sourceRevision:'source-2',displayClearRevision:'clear-2'}}));
  expect(screen.getByText('private-resolver.example')).toBeTruthy();
});

test.each(['concealment','owner','policy'])('the shared DNS editor retires draft strings and old callbacks after %s',change=>{
  let editor!:ReturnType<typeof useDNSEditor>;
  function Body(){editor=useDNSEditor();return <Text>{editor.draft.tiers[0]?.primary??'empty'}</Text>;}
  const live={backgroundPrivacyCoverRequired:false,session:initialSession(),security:{unavailable:false,sourceRevision:'source-1',ownerRevision:'owner-1',displayClearRevision:'clear-1'}} as unknown as AppSnapshot;
  const app={};const view=(snapshot?:AppSnapshot)=><ReviewContext.Provider value={{app,live:snapshot} as ReviewState}><Body/></ReviewContext.Provider>;
  const screen=render(view(live));const oldSetter=editor.setDraft;
  const draft={context:'owner',tiers:[{id:'private',name:'Private resolver',primary:'private-resolver.example',secondary:'',transport:'DoH',metadata:''}]};
  act(()=>oldSetter(draft));expect(screen.getByText('private-resolver.example')).toBeTruthy();
  screen.rerender(view(change==='concealment'?undefined:change==='owner'?{...live,security:{...live.security,ownerRevision:'owner-2'}}:{...live,session:{...live.session,protectedActions:{...live.session.protectedActions,'View Activities':true}}}));
  expect(screen.queryByText('private-resolver.example')).toBeNull();
  act(()=>oldSetter(draft));expect(screen.queryByText('private-resolver.example')).toBeNull();
  screen.rerender(view(live));act(()=>oldSetter(draft));
  expect(screen.getByText('empty')).toBeTruthy();expect(screen.queryByText('private-resolver.example')).toBeNull();
  act(()=>editor.setDraft(draft));expect(screen.getByText('private-resolver.example')).toBeTruthy();
});
