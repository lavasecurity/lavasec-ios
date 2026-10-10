import type {NavigationAction, NavigationState} from '@react-navigation/native';

type State = {index?:number;routes:readonly {key?:string;name:string;state?:State}[]};
const nativeRedirectTarget=(screen:string)=>screen==='vpnChaining'?'VPNChaining':screen==='phoneQA'?'DeviceQA':screen;

/** A dispatched native request is admitted only after its intended stack commits. */
export function nativeRedirectMatches(state:State,tab:string,screen:string):boolean {
  const route=state.routes[state.index??0],root=tab==='SettingsTab'?'Settings':'Guard',target=nativeRedirectTarget(screen);
  if(route?.name!==tab||!route.state)return false;
  const stack=route.state.routes.slice(0,(route.state.index??0)+1).map(item=>item.name);
  return stack.length===(target===root?1:2)&&stack[0]===root&&(target===root||stack[1]===target);
}

// Replace the destination through its nested navigator's state parameter.
// Address the existing tab navigator by key, leaving the other tab's mounted
// navigator and history alone.
export function nativeRedirectAction(state:NavigationState,tab:string,screen:string):NavigationAction | undefined {
  if(!state.routes.some(route=>route.name===tab))return;
  const root=tab==='SettingsTab'?'Settings':'Guard';
  const target=nativeRedirectTarget(screen);
  const stack={index:target===root?0:1,routes:[{name:root},...(target===root?[]:[{name:target}])]};
  return {type:'NAVIGATE',target:state.key,payload:{name:tab,params:{state:stack}}};
}

// A child push stays in its parent's authentication turn. Leaving a tab or
// popping/replacing a child revokes it; a background transition is also revoked
// independently by the native SecurityController.
export class NavigationTurn {
  private previous?: {tab:string;path:string[]};
  private external = false;
  markExternalRequest() {this.external=true;}
  advance(state:State):boolean {
    const root=state.routes[state.index??0];
    if(!root)return false;
    const next={tab:root.name,path:[root.key??root.name]};
    let child=root.state;
    while(child){
      const routes=child.routes.slice(0,(child.index??0)+1);
      next.path.push(...routes.map(route=>route.key??route.name));
      child=routes[routes.length-1]?.state;
    }
    const old=this.previous, external=this.external;
    this.previous=next;this.external=false;
    if(!old||external)return false;
    // Any ordinary tab change ends the previous grant. An entry that actually
    // authenticated marks itself external before navigation, preserving only
    // that newly issued grant (as native redirects already do above).
    if(old.tab!==next.tab)return true;
    return !old.path.every((key,index)=>next.path[index]===key);
  }
}
