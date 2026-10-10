import type {AppSnapshot} from '../app/contract';
import {localized, localizedFormat, localizedNumber} from '../app/presentation';
import type {PreviewSession} from './session';
import {filterFixtures} from './session';

export type ConnectionPart = 'phone' | 'filter' | 'vpn' | 'dns';
export type ConnectionStage = {
  id: ConnectionPart;
  title: string;
  shortTitle: string;
  symbol: string;
  /** Display-ready copy or a verbatim identity; never look up this value again. */
  value: string;
  /** Localized before composing; native provider metadata remains verbatim. */
  detail?: string;
  explanation: string;
  setupSummary: string;
  muted?: boolean;
  destination?: 'Filters' | 'VPNChaining' | 'DNS';
};

// The same identity and glyph follow a connection part through Settings,
// Explore, and contextual links. These describe configuration, never health.
export const connectionParts = {
  phone: {title:'Device',symbol:'iphone'},
  filter: {title:'Filter',symbol:'line.3.horizontal.decrease.circle'},
  vpn: {title:'VPN chaining',symbol:'point.3.connected.trianglepath.dotted'},
  dns: {title:'DNS',symbol:'network'},
} as const;

export function activeFilterSummary(live: AppSnapshot | undefined, session: PreviewSession) {
  // Name and count must share one identity. Protection's global rule count can
  // lag a just-selected filter, so it must not be paired with a different name.
  const filter = live
    ? live.filters?.find(item=>item.id===live.session?.activeFilterID)
    : filterFixtures.find(item=>item.name===session.activeFilter);
  return {emoji:filter&&'emoji' in filter?filter.emoji:undefined,name:filter?.name ?? (live ? localized('Filter unavailable') : session.activeFilter),
    missing:!!live&&!filter,count:filter?.count ? localizedFormat('%@ rules',filter.count) : undefined};
}

export function todaySummary(live: AppSnapshot | undefined, session: PreviewSession) {
  const today=live?.protection?.today;
  if(today?.countsEnabled===false || !today && session.logs['Filtering Counts']===false)
    return {value:'Counts are off',detail:undefined};
  if(today){
    const total=today.allowed+today.blocked;
    return total===0 ? {value:'No requests yet',detail:undefined}
      : {value:localizedFormat('%@%% blocked',localizedNumber(Math.round(today.blocked/total*100))),
        emphasis:`${localizedNumber(Math.round(today.blocked/total*100))}%`,
        allowed:today.allowed,blocked:today.blocked};
  }
  return {value:live?.protection?.activity || 'No requests yet',detail:undefined};
}

export function connectionStages(live: AppSnapshot | undefined, session: PreviewSession): ConnectionStage[] {
  const filter=activeFilterSummary(live,session);
  const saved=live?.connection;
  const selected=live?.dns?.providers?.find(provider=>provider.selected);
  const primary=saved?.dns.primary;
  // Native resolver names/details are already localized, and custom provider
  // identities must stay verbatim. Translate only app-owned fallback labels
  // before inserting them into a sentence or a composed configuration detail.
  const dnsName=primary?.name ?? (session.deviceDNS ? localized('Device DNS') : selected?.name ?? (live ? localized('DNS settings') : session.provider));
  const stages: ConnectionStage[]=[
    {...connectionParts.phone,id:'phone',shortTitle:'Device',value:localized('This device'),
      explanation:'An app asks for a website’s address before connecting.',setupSummary:localized('This device starts the request.')},
    {...connectionParts.filter,id:'filter',shortTitle:'Filter',value:filter.name,detail:filter.count,destination:'Filters',
      explanation:'Lava checks website names against your filter on this device.',
      setupSummary:filter.missing?localized('Your active filter is unavailable.'):
        filter.count?localizedFormat("You're currently using the %@ filter, with %@.",filter.name,filter.count):
          localizedFormat("You're currently using the %@ filter.",filter.name)},
  ];
  // Eligibility is the existing native gate. A muted stage stays on the same
  // connector axis; absence means unavailable, not an implied bypass branch.
  if(saved?.vpn.eligible ?? !!live){
    const enabled=saved?.vpn.enabled;
    const fallback=saved?.vpn.fallbackEnabled;
    const value=localized(enabled ? 'Enabled' : enabled===false ? 'Disabled' : 'View setup');
    const detail=localized(fallback===true?'DNS fallback: Enabled':fallback===false?'DNS fallback: Disabled':'DNS fallback: unavailable');
    stages.push({...connectionParts.vpn,id:'vpn',shortTitle:enabled===false ? 'VPN off' : 'VPN',
      value,detail,
      muted:enabled!==true,destination:'VPNChaining',
      explanation:enabled ? 'Your VPN carries allowed DNS requests.' : enabled===false ? 'With VPN chaining off, allowed DNS requests go straight to DNS.' : 'VPN chaining can send allowed DNS requests through your own VPN.',
      setupSummary:`${localized('VPN chaining')}: ${value} · ${detail}`});
  }
  const fallback=saved?.dns.fallback;
  const fallbackDetail=saved?.dns.usesWireGuard
    ? saved.vpn.fallbackEnabled===false?localized('Fallback: disabled'):saved.vpn.fallbackEnabled===true
      ? localizedFormat('Fallback: %@',[primary?.name,fallback?.name].filter(Boolean).join(', ')):localized('Fallback: unavailable')
    : saved ? fallback ? localizedFormat('Fallback: %@',fallback.name) : undefined
      : session.fallback ? localized('Fallback enabled') : undefined;
  const profileState=live?.dnsPatch?.state;
  const dnsSummary=!live?.dnsPatch?.available
    ? 'Your primary DNS is %@. For more details, check DNS settings.'
    : profileState==='enabled'
      ? 'Your primary DNS is %@. The DNS profile is active. For more details, check DNS settings.'
      : profileState==='checking'||profileState==='error'
        ? 'Your primary DNS is %@. The DNS profile status is unavailable. For more details, check DNS settings.'
        : 'Your primary DNS is %@. The DNS profile is inactive. For more details, check DNS settings.';
  stages.push({...connectionParts.dns,id:'dns',shortTitle:'DNS',value:saved?.dns.usesWireGuard?localized('WireGuard Config'):dnsName,
    detail:saved?.dns.usesWireGuard?fallbackDetail:[primary?.detail,primary?.transport,fallbackDetail].filter(Boolean).join(' · '),
    destination:'DNS',explanation:'DNS finds a website’s address.',setupSummary:localizedFormat(dnsSummary,dnsName)});
  return stages;
}

export type DemoScene={id:string;parts:readonly ConnectionPart[];caption:string};
export const demoEnding={title:'Explore the steps',caption:'Tap a step to see what it does.',nextCaption:'That’s the whole journey. Now it’s your turn: tap a step to take a closer look.'} as const;
export function connectionDemo(stages:readonly ConnectionStage[]):DemoScene[] {
  const vpn=stages.find(stage=>stage.id==='vpn');
  const controls:ConnectionPart[]=vpn?['filter','vpn','dns']:['filter','dns'];
  return [
    {id:'device',parts:['phone'],caption:'It all starts here, on your device. Before it opens anything, it asks one question: where does this website live?'},
    {id:'lookup-intro',parts:['phone','dns'],caption:'That question goes to DNS, the internet’s address book. It matches each website name to its address.'},
    {id:'route',parts:controls,caption:'Every request takes a journey along the path you set. Let’s look at each step.'},
    {id:'filter-policy',parts:['filter'],caption:'First comes your filter. It checks each request against your lists, then lets it through or stops it here.'},
    ...(vpn?[{id:'vpn',parts:['vpn'] as const,caption:'Then, if VPN chaining is on, your request travels through your VPN on its way to DNS.'}]:[]),
    {id:'dns-choice',parts:['dns'],caption:'And last comes DNS. You get to choose who answers your device’s questions.'},
    {id:'blocked-intro',parts:['phone'],caption:'Let’s try a website you’ve blocked. First, your device sends the request to your filter.'},
    {id:'blocked-stop',parts:['phone','filter'],caption:'Your filter sees that this website is blocked and stops the request right here. It never reaches DNS.'},
    {id:'allowed-intro',parts:['phone'],caption:'Now let’s try a website you’ve allowed. The request goes to your filter, just like before.'},
    {id:'allowed-pass',parts:['phone','filter'],caption:'This time, your filter sees that this website is allowed and lets the request continue.'},
    ...(vpn?[{id:'vpn-follow',parts:['phone','filter','vpn'] as const,caption:'From here, the request travels through your VPN if chaining is on, then heads to DNS.'}]:[]),
    {id:'lookup-complete',parts:stages.map(stage=>stage.id),caption:'DNS finds the website’s address and sends it back, so your device knows where to connect.'},
    {id:'ending',parts:controls,caption:demoEnding.nextCaption},
  ];
}
export function demoSection(frame:number,stages:readonly ConnectionStage[]):string {
  const hasVPN=stages.some(stage=>stage.id==='vpn');
  const blockedStart=hasVPN?6:5;const allowedStart=blockedStart+2;
  if(frame<blockedStart)return 'How your device looks up addresses';
  if(frame<allowedStart)return 'When a website is blocked';
  if(frame<connectionDemo(stages).length-1)return 'When a website is allowed';
  return demoEnding.title;
}
export function demoReadingTime(caption:string):number {
  return Math.max(2600,Math.min(6500,caption.length*55));
}
