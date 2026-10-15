import {act,fireEvent,render,screen,waitFor} from '@testing-library/react-native';
import {AppState,Keyboard,type AppStateStatus} from 'react-native';
import {DomainCheckScreen,type DomainCheckResult} from '../review/DomainCheckScreen';
import {GuardScreen} from '../review/screens';
import {ReviewContext,type ReviewState} from '../review/ReviewContext';
import {initialSession} from '../review/session';
import type {AppSnapshot} from '../app/contract';

const mockNavigate=jest.fn();const mockUpgrade=jest.fn();
let mockFocused=true;
jest.mock('../review/plus-entry',()=>({usePlusEntry:()=>mockUpgrade}));
jest.mock('@react-navigation/native',()=>({useNavigation:()=>({navigate:mockNavigate,setOptions:jest.fn(),addListener:()=>()=>{},goBack:jest.fn(),getState:()=>({routes:[],index:0})}),useIsFocused:()=>mockFocused,usePreventRemove:jest.fn(),useScrollToTop:jest.fn()}));
jest.mock('react-native-safe-area-context',()=>require('react-native-safe-area-context/jest/mock').default);
jest.mock('../specs/LavaDecorationNativeComponent',()=>({__esModule:true,default:require('react-native').View}));
jest.mock('../specs/LavaTextFieldNativeComponent',()=>({__esModule:true,default:require('react-native').View}));
jest.mock('../specs/LavaSliderNativeComponent',()=>({__esModule:true,default:require('react-native').View}));
jest.mock('../specs/LavaChoiceNativeComponent',()=>require('./native-choice-mock'));
jest.mock('../specs/NativeLavaReview',()=>({__esModule:true,default:{getGuardAccents:()=>JSON.stringify({original:{light:'#BF4000',dark:'#FF8855'}})}}));

const checked:DomainCheckResult={status:'checked',domain:'sites.google.com',decision:'allow',reason:'defaultAllow',
  filterID:'active',filterName:'Balanced',filterEmoji:'🌿',proof:'native-proof',ignoredURLParts:true,repairedScheme:false,alreadyAllowed:false,alreadyBlocked:false};
function deferred<T>(){let resolve!:(value:T)=>void;let reject!:(value:Error)=>void;
  const promise=new Promise<T>((yes,no)=>{resolve=yes;reject=no;});return {promise,resolve,reject};}
function mount(command:jest.Mock<any,any>=jest.fn(async(request:any)=>checked),component=DomainCheckScreen){
  const live={schema:1,domainCheckAvailable:true,security:{ownerRevision:'owner',readRevision:1},
    session:{...initialSession(),activeFilterID:'active',savedBlocklists:[]},savedDraft:{blocked:[],allowed:[]},
    protection:{title:'Protection Off',subtitle:'Tap once to add local protection',action:'Turn On',mood:'sleeping'}} as unknown as AppSnapshot;
  const app={command,subscribe:()=>()=>{},getSnapshot:():{snapshot:AppSnapshot|null}=>({snapshot:live})};
  const context={app,live,session:live.session,look:'original'} as unknown as ReviewState;
  const Component=component;return {command,live,context,app,...render(<ReviewContext.Provider value={context}><Component/></ReviewContext.Provider>)};
}
function submit(input='sites.google.com'){
  fireEvent(screen.getByTestId('domain-check.input'),'change',{nativeEvent:{text:input}});
  fireEvent.press(screen.getByText('Check'));
}
beforeEach(()=>{mockFocused=true;mockNavigate.mockClear();mockUpgrade.mockClear();(AppState.addEventListener as jest.Mock).mockImplementation(()=>({remove:jest.fn()}));Object.defineProperty(AppState,'currentState',{configurable:true,value:'active'});});

test('Guard exposes one text label and the existing right-chevron accessory',async()=>{
  const view=mount(jest.fn(async()=>null),GuardScreen);
  const row=screen.getByTestId('guard.check-domain');
  expect(row.props.accessibilityLabel).toBe('Check a domain');
  expect(screen.getByTestId('guard.check-domain.accessory')).toBeTruthy();
  expect(row.findAllByProps({symbol:'magnifyingglass'}).length).toBeGreaterThan(0);
  expect(screen.queryByText('Use copied text or type a domain')).toBeNull();
  const tools=screen.getByTestId('guard.tools');
  expect(tools.findAllByProps({testID:'guard.check-domain'}).length).toBeGreaterThan(0);
  expect(tools.findAllByProps({testID:'guard.explore'}).length).toBeGreaterThan(0);
  expect(view.command).not.toHaveBeenCalledWith(expect.objectContaining({type:'domainCheck.paste.query'}));
  fireEvent.press(row);expect(mockNavigate).toHaveBeenCalledWith('DomainCheck');
  await act(async()=>{});
});

test('clearing the native URL field retires the checked verdict and its actions',async()=>{
  mount();submit();
  await screen.findByText('Allowed');
  const field=screen.getByTestId('domain-check.input');
  expect(field.props.clearButtonMode).toBe('always');
  for(const [title,symbol] of [['Allow this','arrow.right.circle.fill'],['Block this','xmark.circle.fill']]){
    const row=screen.getByRole('button',{name:title});
    const glyphs=row.findAllByProps({symbol});
    expect(glyphs.length).toBeGreaterThan(0);
    expect(glyphs[0].props.tone).toBe('primary');
  }
  fireEvent(field,'change',{nativeEvent:{text:''}});
  expect(screen.queryByText('Allowed')).toBeNull();
  expect(screen.queryByText('Allow this')).toBeNull();
  expect(screen.queryByText('Block this')).toBeNull();
  expect(screen.getByRole('button',{name:'Check'})).toBeDisabled();
});

test('entry, editing and repasting stay idle until an explicit Check',async()=>{
  const command=jest.fn(async()=>checked);mount(command);
  expect(screen.getByTestId('domain-check.input').props.value).toBe('');
  expect(screen.queryByText('Paste')).toBeNull();
  expect(command).not.toHaveBeenCalled();
  const field=screen.getByTestId('domain-check.input');
  fireEvent(field,'change',{nativeEvent:{text:'https://sites.google.com/private'}});
  expect(command).not.toHaveBeenCalled();
  fireEvent.press(screen.getByText('Check'));await screen.findByText('Allowed');
  expect(screen.getByText('Domain checked: sites.google.com')).toBeTruthy();
  expect(screen.getByText('Current filter: 🌿 Balanced')).toBeTruthy();
  expect(screen.queryByText('Only the domain is checked. The rest of the link is ignored.')).toBeNull();
  expect(screen.getByText('An allowed result does not guarantee the site is safe.')).toBeTruthy();
  for(let repeat=0;repeat<2;repeat++){
    fireEvent(field,'change',{nativeEvent:{text:''}});
    fireEvent(field,'change',{nativeEvent:{text:'https://sites.google.com/private'}});
    expect(screen.queryByText('Allowed')).toBeNull();
    expect(command).toHaveBeenCalledTimes(repeat+1);
    fireEvent.press(screen.getByText('Check'));await screen.findByText('Allowed');
  }
  expect(command).toHaveBeenCalledTimes(3);
  expect(command).toHaveBeenLastCalledWith(expect.objectContaining({type:'domainCheck.query',input:'https://sites.google.com/private',refresh:false}));
});

test('Allow and Block use native proof and the existing scoped review',async()=>{
  const command=jest.fn(async(request:any)=>request.type==='domainCheck.stage'?{id:'active',standaloneReview:'review-token'}:checked);
  mount(command);submit();await screen.findByText('Allowed');
  fireEvent.press(screen.getByText('Block this'));
  await waitFor(()=>expect(mockNavigate).toHaveBeenCalledWith('Review',{id:'active',standaloneReview:'review-token'}));
  expect(command).toHaveBeenCalledWith(expect.objectContaining({type:'domainCheck.stage',proof:'native-proof',decision:'blocked'}));
  expect(command).not.toHaveBeenCalledWith(expect.objectContaining({type:'filter.apply'}));
});

test('missing filter data cannot produce an allow result or stage a rule',async()=>{
  const command=jest.fn(async()=>({status:'unavailable',domain:'example.com'}));
  mount(command);submit();await screen.findByText('Cannot check this filter yet. Open Filters to review its preparation.');
  expect(screen.queryByText(/^Domain checked:/)).toBeNull();
  expect(screen.queryByTestId('domain-check.result')).toBeNull();
  expect(screen.queryByText('Allow this')).toBeNull();
  expect(screen.queryByText('Block this')).toBeNull();
  expect(command).not.toHaveBeenCalledWith(expect.objectContaining({type:'domainCheck.stage'}));
  expect(screen.queryByText('Allowed')).toBeNull();
});

test.each(['resolved','rejected'])('a retained checker restores controls after a rule action %s while blurred',async outcome=>{
  const pending=deferred<{id:string;standaloneReview:string}>();
  const command=jest.fn((request:any)=>request.type==='domainCheck.stage'?pending.promise:
    request.type==='domainCheck.query'?Promise.resolve(checked):Promise.resolve(null));
  const view=mount(command);submit();await screen.findByText('Allowed');
  fireEvent.press(screen.getByText('Block this'));
  await waitFor(()=>expect(command).toHaveBeenCalledWith(expect.objectContaining({type:'domainCheck.stage'})));
  expect(screen.getByTestId('domain-check.input').props.editable).toBe(false);
  mockFocused=false;
  view.rerender(<ReviewContext.Provider value={view.context}><DomainCheckScreen/></ReviewContext.Provider>);
  await act(async()=>{
    if(outcome==='resolved')pending.resolve({id:'active',standaloneReview:'blurred-review'});
    else pending.reject(Error('Authentication cancelled.'));
  });
  expect(mockNavigate).not.toHaveBeenCalled();
  if(outcome==='resolved')expect(command).toHaveBeenCalledWith({type:'domains.cancel',token:'blurred-review'});
  mockFocused=true;
  view.rerender(<ReviewContext.Provider value={view.context}><DomainCheckScreen/></ReviewContext.Provider>);
  await waitFor(()=>expect(screen.getByTestId('domain-check.input').props.editable).toBe(true));
  expect(screen.getByRole('button',{name:'Check'})).toBeEnabled();
  await waitFor(()=>expect(screen.getByRole('button',{name:'Block this'})).toBeEnabled());
});

test('dismissal retires the native visit and discards late results',async()=>{
  const query=deferred<DomainCheckResult>();
  const command=jest.fn((request:any)=>request.type==='domainCheck.query'?query.promise:Promise.resolve(null));
  const view=mount(command);submit();await waitFor(()=>expect(command).toHaveBeenCalledWith(expect.objectContaining({type:'domainCheck.query'})));
  view.unmount();await act(async()=>query.resolve(checked));
  expect(command).toHaveBeenCalledWith(expect.objectContaining({type:'domainCheck.cancel'}));
  expect(mockNavigate).not.toHaveBeenCalled();
});


test('rule limits offer the existing upgrade flow and refresh proof before retry',async()=>{
  let stages=0;
  const command=jest.fn(async(request:any)=>request.type==='domainCheck.stage'?++stages===1?{rejection:{title:'Rule limit',message:'Upgrade to add more domains.',limitReached:true}}:{id:'active',standaloneReview:'upgraded-review'}:checked);
  mount(command);submit();await screen.findByText('Allowed');
  fireEvent.press(screen.getByText('Block this'));
  await waitFor(()=>expect(mockUpgrade).toHaveBeenCalledWith('blockedDomains',expect.any(Function)));
  const resume=mockUpgrade.mock.calls[0][1];
  let result:any;await act(async()=>{result=await resume();});
  expect(result).toEqual({name:'Review',params:{id:'active',standaloneReview:'upgraded-review'}});
  expect(command).toHaveBeenCalledWith(expect.objectContaining({type:'domainCheck.query',input:'sites.google.com'}));
});

test('protection changes retire paused copy and recheck the submitted domain',async()=>{
  const command=jest.fn(async()=>({...checked,...(state.paused?{protection:'paused'}:{})}));
  const state={paused:true};const view=mount(command);submit();
  await screen.findByText('Lava is paused');
  state.paused=false;view.live.protection.paused=false;view.live.protection.status=3;
  view.rerender(<ReviewContext.Provider value={{...view.context,live:{...view.live}}}><DomainCheckScreen/></ReviewContext.Provider>);
  await screen.findByText('Allowed');
  expect(screen.queryByText('Lava is paused')).toBeNull();
});


test('opening the fixture page without a native app does not trigger a preview alert',()=>{
  const alert=jest.spyOn(require('../app/presentation').Alert,'alert').mockImplementation(()=>{});
  const context={session:initialSession(),look:'original'} as ReviewState;
  try {render(<ReviewContext.Provider value={context}><DomainCheckScreen/></ReviewContext.Provider>);
    expect(alert).not.toHaveBeenCalled();submit();expect(alert).toHaveBeenCalledTimes(1);
  } finally {alert.mockRestore();}
});


test('UIKit committing unchanged text on blur does not retire the submitted check',async()=>{
  const query=deferred<DomainCheckResult>();
  const command=jest.fn((request:any)=>request.type==='domainCheck.query'?query.promise:Promise.resolve(null));
  mount(command);
  const field=screen.getByTestId('domain-check.input');
  fireEvent(field,'change',{nativeEvent:{text:'sites.google.com'}});
  fireEvent.press(screen.getByText('Check'));
  fireEvent(field,'change',{nativeEvent:{text:'sites.google.com'}});
  await act(async()=>query.resolve(checked));
  expect(screen.getByText('Allowed')).toBeTruthy();
});

test('the empty checker uses the ordinary keyboard-aware page scaffold',async()=>{
  mount();
  expect(screen.queryByText('Allow this')).toBeNull();
  expect(screen.queryByText('Block this')).toBeNull();
  expect(screen.queryByText('Cancel')).toBeNull();
  const scroll=screen.getByTestId('screen.scroll');
  expect(scroll.props.contentInsetAdjustmentBehavior).toBe('automatic');
  expect(scroll.props.automaticallyAdjustKeyboardInsets).toBe(true);
  expect(scroll.props.contentOffset).toBeUndefined();
  expect(scroll.props.contentInset).toBeUndefined();
  const field=screen.getByTestId('domain-check.input');
  expect(field.props.autoFocus).toBeFalsy();
  expect(field.props.keyboardType).toBe('url');
  expect(field.props.textContentType).toBe('URL');
  expect(field.props.autoCorrect).toBe(false);
  await act(async()=>{});
});

test('routine native snapshots retain the result without issuing another check',async()=>{
  const command=jest.fn(async(request:any)=>checked);
  const view=mount(command);submit();await screen.findByText('Allowed');
  const queries=command.mock.calls.filter(([request])=>request.type==='domainCheck.query').length;
  for(let revision=2;revision<5;revision++){
    view.live.revision=revision;view.live.security!.sourceRevision=String(revision);
    view.live.security!.displayClearRevision=String(revision);
    view.live.protection.status=revision;
    // Native JSON dictionaries can arrive with a different property order.
    view.live.savedDraft={allowed:[],blocked:[]};
    view.rerender(<ReviewContext.Provider value={{...view.context,live:{...view.live}}}><DomainCheckScreen/></ReviewContext.Provider>);
    expect(screen.getByText('Allowed')).toBeOnTheScreen();
  }
  expect(command.mock.calls.filter(([request])=>request.type==='domainCheck.query')).toHaveLength(queries);
});

test('submitting an empty domain only dismisses the keyboard',async()=>{
  const dismiss=jest.spyOn(Keyboard,'dismiss').mockImplementation(()=>{});
  const command=jest.fn(async()=>checked);mount(command);
  const field=screen.getByTestId('domain-check.input');
  fireEvent(field,'submit',{nativeEvent:{text:'   '}});
  expect(command).not.toHaveBeenCalled();
  expect(dismiss).toHaveBeenCalledTimes(1);
  expect(screen.queryByText('Allowed')).toBeNull();
  expect(screen.getByRole('button',{name:'Check'})).toBeDisabled();
  await act(async()=>{});
  dismiss.mockRestore();
});

test('authority revalidation keeps the panel painted and disables its old proof',async()=>{
  const refresh=deferred<DomainCheckResult>();let queries=0;
  const command=jest.fn((request:any)=>request.type==='domainCheck.query'?++queries===1?Promise.resolve(checked):refresh.promise:Promise.resolve(null));
  const view=mount(command);submit();await screen.findByText('Allowed');
  view.live.security!.readRevision=2;
  view.rerender(<ReviewContext.Provider value={{...view.context,live:{...view.live}}}><DomainCheckScreen/></ReviewContext.Provider>);
  expect(screen.getByText('Allowed')).toBeOnTheScreen();
  fireEvent.press(screen.getByText('Block this'));
  expect(command).not.toHaveBeenCalledWith(expect.objectContaining({type:'domainCheck.stage'}));
  await act(async()=>refresh.resolve({...checked,proof:'refreshed-proof'}));
  expect(screen.getByText('Allowed')).toBeOnTheScreen();
  expect(command).toHaveBeenLastCalledWith(expect.objectContaining({type:'domainCheck.query',refresh:true}));
});

test('an authority change supersedes a pending refresh and restores actions with the latest proof',async()=>{
  const stale=deferred<DomainCheckResult>();const latest=deferred<DomainCheckResult>();let queries=0;
  const command=jest.fn((request:any)=>request.type==='domainCheck.query'?++queries===1?Promise.resolve(checked):queries===2?stale.promise:latest.promise:
    request.type==='domainCheck.stage'?Promise.resolve({id:'active',standaloneReview:'latest-review'}):Promise.resolve(null));
  const view=mount(command);submit();await screen.findByText('Allowed');
  for(const revision of [2,3]){
    view.live.security!.readRevision=revision;
    view.rerender(<ReviewContext.Provider value={{...view.context,live:{...view.live}}}><DomainCheckScreen/></ReviewContext.Provider>);
    expect(screen.getByText('Allowed')).toBeOnTheScreen();
  }
  expect(queries).toBe(3);
  await act(async()=>stale.reject(Error('Authentication cancelled.')));
  fireEvent.press(screen.getByText('Block this'));
  expect(command).not.toHaveBeenCalledWith(expect.objectContaining({type:'domainCheck.stage'}));
  await act(async()=>latest.resolve({...checked,proof:'latest-authority-proof'}));
  fireEvent.press(screen.getByText('Block this'));
  await waitFor(()=>expect(command).toHaveBeenCalledWith(expect.objectContaining({type:'domainCheck.stage',proof:'latest-authority-proof'})));
  expect(screen.getByText('Allowed')).toBeOnTheScreen();
});

test('transient authority loss refreshes again with the same authentication revision',async()=>{
  const stale=deferred<DomainCheckResult>();const latest=deferred<DomainCheckResult>();let queries=0;
  const command=jest.fn((request:any)=>request.type==='domainCheck.query'?++queries===1?Promise.resolve(checked):queries===2?stale.promise:latest.promise:
    request.type==='domainCheck.stage'?Promise.resolve({id:'active',standaloneReview:'active-review'}):Promise.resolve(null));
  const view=mount(command);submit();await screen.findByText('Allowed');
  view.live.security!.readRevision=2;
  const repaint=()=>view.rerender(<ReviewContext.Provider value={{...view.context,live:{...view.live}}}><DomainCheckScreen/></ReviewContext.Provider>);
  repaint();expect(queries).toBe(2);
  let authorized=false;view.app.getSnapshot=()=>({snapshot:authorized?view.live:null});
  Object.defineProperty(AppState,'currentState',{configurable:true,value:'inactive'});repaint();
  expect(screen.getByText('Allowed',{includeHiddenElements:true})).toBeOnTheScreen();
  authorized=true;Object.defineProperty(AppState,'currentState',{configurable:true,value:'active'});repaint();
  expect(queries).toBe(3);
  await act(async()=>stale.reject(Error('Read access changed.')));
  expect(screen.queryByText('Read access changed.')).toBeNull();
  fireEvent.press(screen.getByText('Block this'));
  expect(command).not.toHaveBeenCalledWith(expect.objectContaining({type:'domainCheck.stage'}));
  await act(async()=>latest.resolve({...checked,proof:'active-authority-proof'}));
  fireEvent.press(screen.getByText('Block this'));
  await waitFor(()=>expect(command).toHaveBeenCalledWith(expect.objectContaining({type:'domainCheck.stage',proof:'active-authority-proof'})));
  expect(command.mock.calls.filter(([request])=>request.type==='domainCheck.paste.query')).toHaveLength(0);
});

test('background and resume retain the verdict and refresh proof without rereading the clipboard',async()=>{
  const listeners:Array<(state:AppStateStatus)=>void>=[];
  const subscription=jest.spyOn(AppState,'addEventListener').mockImplementation((_event,listener)=>{
    listeners.push(listener);return {remove:jest.fn()};
  });
  const refresh=deferred<DomainCheckResult>();let queries=0;
  const command=jest.fn((request:any)=>request.type==='domainCheck.query'?++queries===1?Promise.resolve(checked):refresh.promise:
    request.type==='domainCheck.stage'?Promise.resolve({id:'active',standaloneReview:'resumed-review'}):Promise.resolve(null));
  try{
    mount(command);submit();await screen.findByText('Allowed');
    await act(async()=>{Object.defineProperty(AppState,'currentState',{configurable:true,value:'background'});listeners.forEach(listener=>listener('background'));});
    expect(screen.getByText('Allowed',{includeHiddenElements:true})).toBeOnTheScreen();
    expect(command).toHaveBeenCalledWith(expect.objectContaining({type:'domainCheck.cancel'}));
    fireEvent.press(screen.getByText('Block this',{includeHiddenElements:true}));
    expect(command).not.toHaveBeenCalledWith(expect.objectContaining({type:'domainCheck.stage'}));
    await act(async()=>{Object.defineProperty(AppState,'currentState',{configurable:true,value:'active'});listeners.forEach(listener=>listener('active'));});
    expect(screen.getByText('Allowed')).toBeOnTheScreen();
    fireEvent.press(screen.getByText('Block this'));
    expect(command).not.toHaveBeenCalledWith(expect.objectContaining({type:'domainCheck.stage'}));
    await act(async()=>refresh.resolve({...checked,proof:'resumed-proof'}));
    fireEvent.press(screen.getByText('Block this'));
    await waitFor(()=>expect(command).toHaveBeenCalledWith(expect.objectContaining({type:'domainCheck.stage',proof:'resumed-proof'})));
    expect(command.mock.calls.filter(([request])=>request.type==='domainCheck.paste.query')).toHaveLength(0);
  }finally{subscription.mockRestore();}
});

test('an actual filter revision hides the old verdict until the new check completes',async()=>{
  const refresh=deferred<DomainCheckResult>();let queries=0;
  const command=jest.fn((request:any)=>++queries===1?Promise.resolve(checked):refresh.promise);
  const view=mount(command);submit();await screen.findByText('Allowed');
  view.live.domainCheckRevision='new-rules';
  view.rerender(<ReviewContext.Provider value={{...view.context,live:{...view.live}}}><DomainCheckScreen/></ReviewContext.Provider>);
  expect(screen.queryByText('Allowed')).toBeNull();
  expect(screen.queryByText('Block this')).toBeNull();
  await act(async()=>refresh.resolve({...checked,decision:'block',proof:'new-rules-proof'}));
  expect(screen.getByText('Blocked')).toBeOnTheScreen();
  expect(screen.queryByText('An allowed result does not guarantee the site is safe.')).toBeNull();
});

test.each(['Read access changed.','Authentication cancelled.'])('a cancelled check stays quiet and can be checked again (%s)',async message=>{
  let queries=0;
  const command=jest.fn(async(request:any)=>{
    if(request.type==='domainCheck.query'&&++queries===1)throw Error(message);
    return checked;
  });
  mount(command);submit();await act(async()=>{});
  expect(screen.queryByText(message)).toBeNull();
  expect(screen.queryByText('Allow this')).toBeNull();
  expect(screen.getByRole('button',{name:'Check'})).toBeEnabled();
  fireEvent.press(screen.getByText('Check'));
  await screen.findByText('Allowed');
  expect(queries).toBe(2);
});

test.each(['Read access changed.','Authentication cancelled.'])('a cancelled refresh keeps the verdict quiet and requires a renewed proof (%s)',async message=>{
  const refresh=deferred<DomainCheckResult>();let queries=0;
  const command=jest.fn((request:any)=>request.type==='domainCheck.query'?++queries===2?refresh.promise:Promise.resolve({...checked,proof:'renewed-proof'}):
    Promise.resolve({id:'active',standaloneReview:'review-token'}));
  const view=mount(command);submit();await screen.findByText('Allowed');
  view.live.security!.readRevision=2;
  view.rerender(<ReviewContext.Provider value={{...view.context,live:{...view.live}}}><DomainCheckScreen/></ReviewContext.Provider>);
  await act(async()=>refresh.reject(Error(message)));
  expect(screen.queryByText(message)).toBeNull();
  expect(screen.getByText('Allowed')).toBeOnTheScreen();
  expect(screen.getByRole('button',{name:'Block this'})).toBeDisabled();
  fireEvent.press(screen.getByText('Check'));await act(async()=>{});
  fireEvent.press(screen.getByText('Block this'));
  await waitFor(()=>expect(command).toHaveBeenCalledWith(expect.objectContaining({type:'domainCheck.stage',proof:'renewed-proof'})));
});

test.each(['Read access changed.','Authentication cancelled.'])('a cancelled rule action stays quiet and does not navigate (%s)',async message=>{
  let stages=0;
  const command=jest.fn(async(request:any)=>{
    if(request.type==='domainCheck.stage'){
      if(++stages===1)throw Error(message);
      return {id:'active',standaloneReview:'review-token'};
    }
    return checked;
  });
  mount(command);submit();await screen.findByText('Allowed');
  await act(async()=>fireEvent.press(screen.getByText('Block this')));
  expect(screen.queryByText(message)).toBeNull();
  expect(mockNavigate).not.toHaveBeenCalled();
  fireEvent.press(screen.getByText('Block this'));
  await waitFor(()=>expect(mockNavigate).toHaveBeenCalledWith('Review',{id:'active',standaloneReview:'review-token'}));
});

test.each(['domainCheck.query','domainCheck.stage'])('an actionable failure remains visible for %s',async failingType=>{
  const command=jest.fn(async(request:any)=>{
    if(request.type===failingType)throw Error('Check the domain again.');
    return checked;
  });
  mount(command);submit();
  if(failingType==='domainCheck.stage'){
    await screen.findByText('Allowed');fireEvent.press(screen.getByText('Block this'));
  }
  await screen.findByText('Check the domain again.');
  expect(mockNavigate).not.toHaveBeenCalled();
});
