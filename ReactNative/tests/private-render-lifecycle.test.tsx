import {useEffect,useState} from 'react';
import {ScrollView,Text,View} from 'react-native';
import {act,render,renderHook} from '@testing-library/react-native';
import {LiveRenderBoundary,ReviewContext,type ReviewState,usePreviewFixtureState,useRouteBodyConcealed} from '../review/ReviewContext';
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
    return <View><Text>{route}</Text><LiveRenderBoundary component={Body} retainBody={false}/></View>;
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

test('an explicitly retained parent draft stays inaccessible through revocation and retires on owner replacement',()=>{
  const destroyed=jest.fn();let setPrivate!:(value:string)=>void;let mounts=0;
  function Body(){const [value,setValue]=useState('Fresh native draft');setPrivate=setValue;useEffect(()=>{mounts++;return destroyed;},[]);return <Text>{value}</Text>;}
  const app={};const live={backgroundPrivacyCoverRequired:true,session:initialSession(),security:{ownerRevision:'owner-1',readRevision:1}} as unknown as AppSnapshot;
  const content=(snapshot?:AppSnapshot)=><ReviewContext.Provider value={{app,live:snapshot} as ReviewState}><LiveRenderBoundary component={Body} retainBody/></ReviewContext.Provider>;
  const view=render(content(live));act(()=>setPrivate('Retained private draft'));
  view.rerender(content());
  expect(view.queryByText('Retained private draft')).toBeNull();
  expect(view.getByTestId('lava-route-privacy-cover')).toBeTruthy();
  expect(destroyed).not.toHaveBeenCalled();
  view.rerender(content({...live,security:{...live.security,readRevision:2}}));
  expect(view.getByText('Retained private draft')).toBeTruthy();expect(mounts).toBe(1);
  view.rerender(content({...live,security:{...live.security,ownerRevision:'owner-2'}}));
  expect(view.queryByText('Retained private draft')).toBeNull();
  expect(view.getByText('Fresh native draft')).toBeTruthy();
  expect(destroyed).toHaveBeenCalledTimes(1);expect(mounts).toBe(2);
});

test.each(['owner','unavailable'])('ordinary Security scaffolds keep their native scroll identity through policy edits but retire on %s',change=>{
  const destroyed=jest.fn();let mounts=0;
  function SecurityBody(){
    const hidden=useRouteBodyConcealed();
    useEffect(()=>{mounts++;return destroyed;},[]);
    return <ScrollView testID="security-scroll" accessibilityElementsHidden={hidden} importantForAccessibility={hidden?'no-hide-descendants':'auto'} pointerEvents={hidden?'none':'auto'}><Text>Security settings</Text></ScrollView>;
  }
  const app={};const live={backgroundPrivacyCoverRequired:true,session:initialSession(),security:{ownerRevision:'owner-1',readRevision:1,unavailable:false}} as unknown as AppSnapshot;
  const content=(snapshot?:AppSnapshot)=><ReviewContext.Provider value={{app,live:snapshot} as ReviewState}><LiveRenderBoundary component={SecurityBody} directScrollRoot retireOnPolicyChange={false}/></ReviewContext.Provider>;
  const view=render(content(live));const scroll=view.getByTestId('security-scroll');
  const policy={...live,session:{...live.session,passcode:true,protectedActions:{...live.session.protectedActions,'App Unlock':true,'Update App Settings':true}},security:{...live.security,readRevision:2}};
  view.rerender(content(policy));
  expect(view.getByTestId('security-scroll')).toBe(scroll);expect(mounts).toBe(1);
  view.rerender(content());
  expect(view.queryByTestId('security-scroll')).toBeNull();
  expect(view.getByTestId('security-scroll',{includeHiddenElements:true})).toBe(scroll);
  expect(scroll.props.pointerEvents).toBe('none');expect(destroyed).not.toHaveBeenCalled();
  expect(view.getByTestId('lava-route-privacy-cover')).toBeTruthy();
  view.rerender(content({...policy,security:{...policy.security,readRevision:3}}));
  expect(view.getByTestId('security-scroll')).toBe(scroll);expect(scroll.props.pointerEvents).toBe('auto');
  view.rerender(content({...policy,security:{...policy.security,...(change==='owner'?{ownerRevision:'owner-2'}:{unavailable:true})}}));
  expect(view.getByTestId('security-scroll')).not.toBe(scroll);
  expect(destroyed).toHaveBeenCalledTimes(1);expect(mounts).toBe(2);
});

test('a retained DNS parent conceals its draft and retires old callbacks without losing the original selection context',()=>{
  let editor!:ReturnType<typeof useDNSEditor>;let mounts=0;
  function Body(){editor=useDNSEditor();useEffect(()=>{mounts++;},[]);return <Text>{editor.draft.tiers[0]?.primary??'empty'}</Text>;}
  const live={backgroundPrivacyCoverRequired:true,session:initialSession(),security:{ownerRevision:'owner-1',readRevision:1}} as unknown as AppSnapshot;
  const app={};const content=(snapshot?:AppSnapshot)=><ReviewContext.Provider value={{app,live:snapshot} as ReviewState}><LiveRenderBoundary component={Body} retainBody/></ReviewContext.Provider>;
  const screen=render(content(live));const oldSetter=editor.setDraft;
  const tier={id:'custom-dns',name:'Private resolver',primary:'https://dns.example.test/dns-query',secondary:'',transport:'DoH',metadata:''};
  const draft={context:'original-native-context',tiers:[tier]};
  act(()=>oldSetter(draft));
  screen.rerender(content());
  expect(screen.queryByText(tier.primary)).toBeNull();expect(editor.draft.tiers).toEqual([]);
  const stale={...draft,context:'retired-context',tiers:[{...tier,primary:'https://stale.example.test/dns-query'}]};
  act(()=>oldSetter(stale));
  screen.rerender(content({...live,security:{...live.security,readRevision:2}}));
  expect(editor.draft).toEqual(draft);expect(screen.getByText(tier.primary)).toBeTruthy();expect(mounts).toBe(1);
  act(()=>oldSetter(stale));expect(editor.draft).toEqual(draft);
  act(()=>editor.setDraft({...draft,tiers:[{...tier,name:'Authorized selection'}]}));
  expect(editor.draft.context).toBe('original-native-context');expect(editor.draft.tiers[0]?.name).toBe('Authorized selection');
  screen.rerender(content({...live,security:{...live.security,ownerRevision:'owner-2'}}));
  expect(editor.draft.tiers).toEqual([]);expect(screen.queryByText(tier.primary)).toBeNull();
});

test.each(['owner','policy'])('the shared DNS editor retires draft strings and old callbacks after %s',change=>{
  let editor!:ReturnType<typeof useDNSEditor>;
  function Body(){editor=useDNSEditor();return <Text>{editor.draft.tiers[0]?.primary??'empty'}</Text>;}
  const live={backgroundPrivacyCoverRequired:false,session:initialSession(),security:{unavailable:false,sourceRevision:'source-1',ownerRevision:'owner-1',displayClearRevision:'clear-1'}} as unknown as AppSnapshot;
  const app={};const view=(snapshot?:AppSnapshot)=><ReviewContext.Provider value={{app,live:snapshot} as ReviewState}><Body/></ReviewContext.Provider>;
  const screen=render(view(live));const oldSetter=editor.setDraft;
  const draft={context:'owner',tiers:[{id:'private',name:'Private resolver',primary:'private-resolver.example',secondary:'',transport:'DoH',metadata:''}]};
  act(()=>oldSetter(draft));expect(screen.getByText('private-resolver.example')).toBeTruthy();
  screen.rerender(view(change==='owner'?{...live,security:{...live.security,ownerRevision:'owner-2'}}:{...live,session:{...live.session,protectedActions:{...live.session.protectedActions,'View Activities':true}}}));
  expect(screen.queryByText('private-resolver.example')).toBeNull();
  act(()=>oldSetter(draft));expect(screen.queryByText('private-resolver.example')).toBeNull();
  screen.rerender(view(live));act(()=>oldSetter(draft));
  expect(screen.getByText('empty')).toBeTruthy();expect(screen.queryByText('private-resolver.example')).toBeNull();
  act(()=>editor.setDraft(draft));expect(screen.getByText('private-resolver.example')).toBeTruthy();
});
