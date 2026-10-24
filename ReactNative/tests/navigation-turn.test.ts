import {NavigationTurn, nativeRedirectAction,nativeRedirectMatches} from '../app/navigation-turn';
import type {NavigationState} from '@react-navigation/native';
const state=(tab:string,path:string[])=>({index:0,routes:[{name:tab,key:tab,state:{index:path.length-1,routes:path.map(key=>({name:key,key}))}}]});
test('Settings selection retains its newly authorized grant and child pushes share it',()=>{
  const turn=new NavigationTurn();
  expect(turn.advance(state('GuardTab',['Guard']))).toBe(false);
  turn.markExternalRequest();
  expect(turn.advance(state('SettingsTab',['Settings']))).toBe(false);
  expect(turn.advance(state('SettingsTab',['Settings','Customization']))).toBe(false);
  expect(turn.advance(state('SettingsTab',['Settings','Customization','Guardian']))).toBe(false);
  expect(turn.advance(state('SettingsTab',['Settings','Customization']))).toBe(true);
  expect(turn.advance(state('SettingsTab',['Settings']))).toBe(true);
});
test('an unprotected Settings entry still revokes the previous tab authentication turn',()=>{
  const turn=new NavigationTurn();
  turn.advance(state('GuardTab',['Guard','Filters','Filter']));
  expect(turn.advance(state('SettingsTab',['Settings']))).toBe(true);
});
test('reselection is inert and leaving Settings revokes the turn',()=>{
  const turn=new NavigationTurn();
  turn.advance(state('SettingsTab',['Settings','Account']));
  expect(turn.advance(state('SettingsTab',['Settings','Account']))).toBe(false);
  expect(turn.advance(state('GuardTab',['Guard']))).toBe(true);
});
test('a freshly authorized external request is not revoked by its stack reset',()=>{
  const turn=new NavigationTurn();
  turn.advance(state('SettingsTab',['Settings','Account']));
  turn.markExternalRequest();
  expect(turn.advance(state('SettingsTab',['Settings','Security']))).toBe(false);
  expect(turn.advance(state('SettingsTab',['Settings']))).toBe(true);
});

test.each([['SettingsTab','DNS'],['GuardTab','Guard']] as const)('native redirect to %s addresses only its nested navigator', (tab,screen)=>{
  const before={stale:false,type:'tab',key:'tabs',index:0,routeNames:['GuardTab','SettingsTab'],routes:[
    {name:'GuardTab',key:'guard-tab',state:{...state('GuardTab',['Guard','Activity']).routes[0]!.state}},
    {name:'SettingsTab',key:'settings-tab',state:{...state('SettingsTab',['Settings','Account']).routes[0]!.state}},
  ]} as NavigationState;
  const action=nativeRedirectAction(before,tab,screen);
  expect(action).toEqual({type:'NAVIGATE',target:'tabs',payload:{name:tab,params:{state:{index:tab==='GuardTab'?0:1,routes:tab==='GuardTab'?[{name:'Guard'}]:[{name:'Settings'},{name:'DNS'}]}}}});
  expect(before.routes[0]!.state!.routes.map(route=>route.name)).toEqual(['Guard','Activity']);
  expect(before.routes[1]!.state!.routes.map(route=>route.name)).toEqual(['Settings','Account']);
});

test('a native VPN redirect creates a pushed VPN route instead of leaving Settings behind a modal',()=>{
  const before={stale:false,type:'tab',key:'tabs',index:0,routeNames:['SettingsTab'],routes:[{name:'SettingsTab',key:'settings'}]} as NavigationState;
  expect(nativeRedirectAction(before,'SettingsTab','vpnChaining')).toEqual({type:'NAVIGATE',target:'tabs',payload:{name:'SettingsTab',params:{state:{index:1,routes:[{name:'Settings'},{name:'VPNChaining'}]}}}});
});

test.each([['Feedback','Feedback'],['phoneQA','DeviceQA'],['DeviceQA','DeviceQA'],['Customization','Customization'],['Network','Network']])('native Settings redirect %s preserves a page Back destination', (input, destination)=>{
  const before={stale:false,type:'tab',key:'tabs',index:0,routeNames:['SettingsTab'],routes:[{name:'SettingsTab',key:'settings'}]} as NavigationState;
  expect(nativeRedirectAction(before,'SettingsTab',input)).toEqual({type:'NAVIGATE',target:'tabs',payload:{name:'SettingsTab',params:{state:{index:1,routes:[{name:'Settings'},{name:destination}]}}}});
});

test.each(['Explore','DomainCheck'])('the %s deep link pushes a page above Guard with a normal Back destination',destination=>{
  const before={stale:false,type:'tab',key:'tabs',index:1,routeNames:['GuardTab','SettingsTab'],routes:[
    {name:'GuardTab',key:'guard',state:{...state('GuardTab',['Guard','Activity']).routes[0]!.state}},
    {name:'SettingsTab',key:'settings',state:{...state('SettingsTab',['Settings','Account']).routes[0]!.state}},
  ]} as NavigationState;
  expect(nativeRedirectAction(before,'GuardTab',destination)).toEqual({type:'NAVIGATE',target:'tabs',payload:{name:'GuardTab',params:{state:{index:1,routes:[{name:'Guard'},{name:destination}]}}}});
  expect(before.routes[1]?.state?.routes.map(route=>route.name)).toEqual(['Settings','Account']);
});

test.each([['SettingsTab','vpnChaining','VPNChaining'],['SettingsTab','phoneQA','DeviceQA'],['GuardTab','Explore','Explore'],['GuardTab','DomainCheck','DomainCheck'],['GuardTab','Guard','Guard']])('native redirect admission matches the committed normalized %s/%s destination', (tab,input,target)=>{
  const root=tab==='SettingsTab'?'Settings':'Guard';
  const active={index:0,routes:[{name:tab,state:{index:target===root?0:1,routes:[{name:root},...(target===root?[]:[{name:target}])]}}]};
  expect(nativeRedirectMatches(active,tab,input)).toBe(true);
  expect(nativeRedirectMatches(active,tab==='SettingsTab'?'GuardTab':'SettingsTab',input)).toBe(false);
  expect(nativeRedirectMatches({index:0,routes:[{name:tab,state:{index:2,routes:[{name:root},{name:target},{name:'Different child'}]}}]},tab,input)).toBe(false);
});

test('every domain-check link owns a fresh native visit, including an already-focused checker',()=>{
  const before=state('GuardTab',['Guard','DomainCheck']) as NavigationState;
  const action=nativeRedirectAction(before,'GuardTab','DomainCheck',7)!;
  expect(action).toMatchObject({payload:{params:{state:{routes:[{name:'Guard'},{name:'DomainCheck',key:'domain-check-link-7'}]}}}});
  expect(nativeRedirectMatches(before,'GuardTab','DomainCheck',7)).toBe(false);
  const committed={index:0,routes:[{name:'GuardTab',state:(action as any).payload.params.state}]};
  expect(nativeRedirectMatches(committed,'GuardTab','DomainCheck',7)).toBe(true);
  expect(nativeRedirectMatches(committed,'GuardTab','DomainCheck',8)).toBe(false);
  expect(nativeRedirectAction(before,'GuardTab','DomainCheck',8)).toMatchObject({payload:{params:{state:{routes:[{name:'Guard'},{name:'DomainCheck',key:'domain-check-link-8'}]}}}});
});

// Plus is a detour owned by the requesting page, including a swipe cancellation.
// Popping it must not revoke the still-mounted parent or rebuild its scroll body.
test('returning from Plus keeps the VPN visit grant; leaving that visit still retires it',()=>{
  const turn=new NavigationTurn();
  expect(turn.advance(state('SettingsTab',['Settings','VPNChaining']))).toBe(false);
  expect(turn.advance(state('SettingsTab',['Settings','VPNChaining','Upgrade']))).toBe(false);
  expect(turn.advance(state('SettingsTab',['Settings','VPNChaining']))).toBe(false);
  expect(turn.advance(state('SettingsTab',['Settings','VPNChaining','Upgrade']))).toBe(false);
  expect(turn.advance(state('SettingsTab',['Settings','VPNChaining','Upgrade']))).toBe(false);
  expect(turn.advance(state('SettingsTab',['Settings','VPNChaining']))).toBe(false);
  expect(turn.advance(state('SettingsTab',['Settings']))).toBe(true);
  expect(turn.advance(state('GuardTab',['Guard']))).toBe(true);
});
