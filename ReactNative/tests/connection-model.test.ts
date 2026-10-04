import type {AppSnapshot} from '../app/contract';
import {activeFilterSummary,connectionStages,connectionDemo,demoEnding,demoSection,demoReadingTime,todaySummary} from '../review/connection-model';
import {initialSession} from '../review/session';
import {translations} from '../app/translations';

const session=initialSession();
const snapshot=(extra:Partial<AppSnapshot>={}):AppSnapshot=>({
  qaTools:false,
  session:{...session,filterID:'old',activeFilterID:'new'},
  protection:{rules:999999,today:{countsEnabled:true,allowed:83,blocked:17}},
  filters:[{id:'new',name:'Personal',count:'12',lists:[],frozen:false,shareable:true,shareSummary:''}],
  connection:{filter:{id:'new',name:'Personal',count:'12'},dns:{primary:{name:'Device DNS',detail:'Wi-Fi',transport:'IP'},fallback:{name:'Quad9',detail:'',transport:'DoH'}},vpn:{eligible:true,enabled:false}},
  ...extra,
} as AppSnapshot);

test('Guard pairs filter name and count by identity, never the stale protection counter',()=>{
  const live=snapshot();
  expect(activeFilterSummary(live,session)).toEqual({name:'Personal',missing:false,count:'12 rules'});
  expect(activeFilterSummary({...live,filters:[]},session)).toEqual({name:'Filter unavailable',missing:true,count:undefined});
  const legitimateName={...live,filters:[{...live.filters![0]!,name:'Filter unavailable'}]};
  expect(activeFilterSummary(legitimateName,session)).toMatchObject({name:'Filter unavailable',missing:false});
  expect(connectionStages(legitimateName,session).find(stage=>stage.id==='filter')?.setupSummary).toContain('currently using the Filter unavailable filter');
});
test('public Today distinguishes counts off, zero requests, and a real zero percent',()=>{
  const live=snapshot();
  expect(todaySummary(live,session)).toEqual({value:'17% blocked',emphasis:'17%',allowed:83,blocked:17});
  expect(todaySummary({...live,protection:{...live.protection,today:{countsEnabled:true,allowed:0,blocked:0}}},session).value).toBe('No requests yet');
  expect(todaySummary({...live,protection:{...live.protection,today:{countsEnabled:true,allowed:100,blocked:0}}},session).value).toBe('0% blocked');
  expect(todaySummary({...live,protection:{...live.protection,today:{countsEnabled:false,allowed:100,blocked:20}}},session).value).toBe('Counts are off');
});
test('DNS uses native ordered choices, not the selected alternative when Device DNS is primary',()=>{
  const dns=connectionStages(snapshot(),session).find(stage=>stage.id==='dns')!;
  expect(dns.value).toBe('Device DNS');expect(dns.detail).toContain('Fallback: Quad9');
  const live=snapshot();
  const noFallback=connectionStages({...live,connection:{...live.connection!,dns:{...live.connection!.dns,fallback:null}}},{...session,fallback:true}).find(stage=>stage.id==='dns')!;
  expect(noFallback.detail).not.toContain('Fallback');
});
test('DNS profile status stays unknown when the platform cannot inspect DNS profiles',()=>{
  const live=snapshot();
  const dns=connectionStages({...live,dnsPatch:{available:false,state:'absent',busy:false}},session).find(stage=>stage.id==='dns')!;
  expect(dns.setupSummary).toBe('Your primary DNS is Device DNS. For more details, check DNS settings.');
  const summary='Your primary DNS is %@. For more details, check DNS settings.';
  expect(Object.values(translations)).toHaveLength(10);
  expect(Object.values(translations).every(locale=>typeof locale[summary]==='string')).toBe(true);
});
test('VPN eligibility controls presence; off and on retain their ordered path position',()=>{
  const live=snapshot();const off=connectionStages(live,session);
  expect(off.map(stage=>stage.id)).toEqual(['phone','filter','vpn','dns']);
  expect(off[2]).toMatchObject({shortTitle:'VPN off',muted:true});
  expect(off[2]?.explanation).toBe('With VPN chaining off, allowed DNS requests go straight to DNS.');
  const on=connectionStages({...live,connection:{...live.connection!,vpn:{eligible:true,enabled:true}}},session);
  expect(on.map(stage=>stage.id)).toEqual(off.map(stage=>stage.id));
  expect(on[2]).toMatchObject({shortTitle:'VPN',value:'Enabled',muted:false});
  expect(on[2]?.explanation).toBe('Your VPN carries allowed DNS requests.');
  const setup=connectionStages(snapshot({connection:undefined}),session);
  expect(setup.find(stage=>stage.id==='vpn')?.explanation).toBe('VPN chaining can send allowed DNS requests through your own VPN.');
  expect(connectionStages({...live,connection:{...live.connection!,vpn:{eligible:false,enabled:false}}},session).map(stage=>stage.id)).toEqual(['phone','filter','dns']);
});
test('the lesson explains actual routing and keeps blocked and allowed paths distinct',()=>{
  const live=snapshot();const off=connectionDemo(connectionStages(live,session));
  expect(off).toHaveLength(13);
  expect(off[0]).toEqual({id:'device',parts:['phone'],caption:'It all starts here, on your device. Before it opens anything, it asks one question: where does this website live?'});
  expect(off[7]).toEqual({id:'blocked-stop',parts:['phone','filter'],caption:'Your filter sees that this website is blocked and stops the request right here. It never reaches DNS.'});
  expect(off[10]).toEqual({id:'vpn-follow',parts:['phone','filter','vpn'],caption:'From here, the request travels through your VPN if chaining is on, then heads to DNS.'});
  expect(off[11]!.parts).toEqual(['phone','filter','vpn','dns']);
  const on=connectionDemo(connectionStages({...live,connection:{...live.connection!,vpn:{eligible:true,enabled:true}}},session));
  expect(on[10]!.id).toBe('vpn-follow');
  expect(on[10]!.caption).toBe(off[10]!.caption);
  const unavailable=connectionDemo(connectionStages({...live,connection:{...live.connection!,vpn:{eligible:false,enabled:false}}},session));
  expect(unavailable).toHaveLength(11);
  expect(unavailable.every(scene=>!scene.parts.includes('vpn'))).toBe(true);
});
test('caption reading time has a readable minimum and a bounded maximum',()=>{
  expect(demoReadingTime('Short.')).toBe(2600);
  expect(demoReadingTime('A'.repeat(1000))).toBe(6500);
});

test('connection copy is device-neutral while retaining the origin identity and glyph',()=>{
  const stages=connectionStages(snapshot(),session);
  expect(stages[0]).toMatchObject({id:'phone',title:'Device',shortTitle:'Device',value:'This device',symbol:'iphone'});
  expect(stages.find(stage=>stage.id==='filter')?.explanation).toBe('Lava checks website names against your filter on this device.');
});

test('the ending invites inspection using the same candidate narration caption',()=>{
  const stages=connectionStages(snapshot(),session),scenes=connectionDemo(stages);
  expect(demoSection(scenes.length-1,stages)).toBe(demoEnding.title);
  expect(scenes.at(-1)?.caption).toBe(demoEnding.nextCaption);
  expect(demoEnding.nextCaption).toBe('That’s the whole journey. Now it’s your turn: tap a step to take a closer look.');
  expect(demoEnding.caption).toBe('Tap a step to see what it does.');
});

test('all routing variants share stable approved script IDs and ten localized captions',()=>{
  const script=require('../narration/script.json') as {approved:boolean;scenes:{id:string;locales:Record<string,string>}[]};
  expect(script.approved).toBe(true);
  expect(script.scenes).toHaveLength(13);
  const live=snapshot();const seen=new Set<string>();
  for(const enabled of [false,true])for(const scene of connectionDemo(connectionStages({...live,connection:{...live.connection!,vpn:{eligible:true,enabled}}},session))){
    seen.add(scene.id);
    const authored=script.scenes.find(entry=>entry.id===scene.id)!;
    expect(authored.locales.en).toBe(scene.caption);
    expect(Object.keys(authored.locales)).toHaveLength(10);
    for(const [locale,caption] of Object.entries(authored.locales))expect(translations[locale]?.[scene.caption]).toBe(caption);
    if(scene.id==='blocked-stop')expect(scene.parts).not.toContain('dns');
  }
  expect(seen.size).toBe(13);
});


test('WireGuard configuration uses the native fallback availability and saved resolver order',()=>{
  const live=snapshot();
  const projected=(enabled:boolean|null)=>connectionStages({...live,connection:{...live.connection!,
    dns:{...live.connection!.dns,usesWireGuard:true,editable:enabled!==false},
    vpn:{eligible:true,enabled:true,fallbackEnabled:enabled}}},session);
  expect(projected(true).find(stage=>stage.id==='dns')).toMatchObject({value:'WireGuard Config',detail:'Fallback: Device DNS, Quad9'});
  expect(projected(false).find(stage=>stage.id==='dns')).toMatchObject({value:'WireGuard Config',detail:'Fallback: disabled'});
  expect(projected(false).find(stage=>stage.id==='vpn')).toMatchObject({value:'Enabled',detail:'DNS fallback: Disabled'});
  expect(projected(null).find(stage=>stage.id==='dns')?.detail).toBe('Fallback: unavailable');
  expect(projected(null).find(stage=>stage.id==='vpn')?.detail).toBe('DNS fallback: unavailable');
});
