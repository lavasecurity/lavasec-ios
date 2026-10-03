import type {PropsWithChildren} from 'react';
import {AppState} from 'react-native';
import {act,fireEvent,render,screen} from '@testing-library/react-native';
import {AutoSwitchScreen,VPNChainingScreen,DNSPatchScreen,CustomEntryScreen} from '../review/NativePageScreen';
import {ReviewContext,type ReviewState} from '../review/ReviewContext';
import {initialSession} from '../review/session';

const mockNavigate=jest.fn();const mockGoBack=jest.fn();const mockGetState=jest.fn();
let mockParams:{returnTo?:'DNS';returnKey?:string;id?:string;kind?:'dns'|'blocklist'}|undefined;
let mockFocused=true;
const mockSetOptions=jest.fn();
const mockNavigation={setOptions:mockSetOptions,navigate:mockNavigate,goBack:mockGoBack,getState:mockGetState};
jest.mock('@react-navigation/native',()=>({useNavigation:()=>mockNavigation,useRoute:()=>({key:'native-page',params:mockParams}),useIsFocused:()=>mockFocused,usePreventRemove:jest.fn()}));
jest.mock('../specs/NativeLavaReview',()=>({__esModule:true,default:{getGuardAccents:()=>JSON.stringify({original:{light:'#BF4000',dark:'#FF8855'}})}}));
jest.mock('../specs/LavaSliderNativeComponent',()=>({__esModule:true,default:require('react-native').View}));
jest.mock('../specs/LavaNativePageNativeComponent' ,()=>({__esModule:true,default:require('react-native').View}));

beforeEach(()=>{
  mockParams=undefined;mockFocused=true;mockSetOptions.mockClear();mockNavigate.mockClear();mockGoBack.mockClear();
  mockGetState.mockReturnValue({index:1,routes:[{name:'Settings',key:'settings'},{name:'VPNChaining',key:'native-page'}]});
  jest.spyOn(AppState,'addEventListener').mockReturnValue({remove:jest.fn()});
});
afterEach(()=>jest.restoreAllMocks());
function provider(command=jest.fn().mockResolvedValue(null),qaTools=true){
  return ({children}:PropsWithChildren)=><ReviewContext.Provider value={{app:{command},live:{qaTools,vpn:{setup:true,rows:[],generation:"",canChangeFallback:true}},session:initialSession()} as unknown as ReviewState}>{children}</ReviewContext.Provider>;
}
test('Auto-switch uses the same native content boundary and returns through its parent stack',()=>{
  render(<AutoSwitchScreen/>,{wrapper:provider()});
  const page=screen.getByTestId('auto-switch-page');expect(page.props.page).toBe('automation');
  fireEvent(page,'back');expect(mockGoBack).toHaveBeenCalledTimes(1);
});

test.each([AutoSwitchScreen])('retained native pages receive route focus without remounting',Page=>{
  const view=render(<Page/>,{wrapper:provider()});
  const id=Page===VPNChainingScreen?'vpn-chaining-page':'auto-switch-page';
  expect(screen.getByTestId(id).props.focused).toBe(true);
  mockFocused=false;view.rerender(<Page/>);
  expect(screen.getByTestId(id).props.focused).toBe(false);
  mockFocused=true;view.rerender(<Page/>);
  expect(screen.getByTestId(id).props.focused).toBe(true);
  expect(mockGoBack).not.toHaveBeenCalled();
});


test('DNS patch uses the same native scaffold boundary as Auto-switch without setup on mount',()=>{
  const command=jest.fn();
  render(<DNSPatchScreen/>,{wrapper:provider(command)});
  expect(screen.getByTestId('dns-patch-page').props.page).toBe('dnsPatch');
  expect(command).not.toHaveBeenCalled();
});

test('DNS patch opens VPN chaining through the protected parent navigator',async()=>{
  const command=jest.fn().mockResolvedValue(null);
  render(<DNSPatchScreen/>,{wrapper:provider(command)});
  fireEvent(screen.getByTestId('dns-patch-page'),'navigate',{nativeEvent:{destination:'VPNChaining'}});
  await act(async()=>{});
  expect(command).toHaveBeenCalledWith({type:'navigation.authorize',surface:'appSettings'});
  expect(mockNavigate).toHaveBeenCalledWith('VPNChaining');
});


test.each([true,false])('patch discovery acknowledges only a focused page (%s), never DNS setup',async focused=>{
  mockFocused=focused;
  const command=jest.fn().mockResolvedValue(null);
  const wrapper=({children}:PropsWithChildren)=><ReviewContext.Provider value={{app:{command},live:{discoveries:{'ios27Patch.page':true}},session:initialSession()} as unknown as ReviewState}>{children}</ReviewContext.Provider>;
  render(<DNSPatchScreen/>,{wrapper});
  await act(async()=>{});
  expect(command.mock.calls).toEqual(focused?[[{type:'discovery.seen',target:'ios27Patch.page'}]]:[]);
});

// Both forms return to their retained picker and release only their own draft.
test.each(['dns','blocklist'] as const)('custom %s Close returns without saving and releases its draft on removal',async kind=>{
  mockParams={id:'custom-draft',kind};
  const command=jest.fn().mockResolvedValue(null);
  const view=render(<CustomEntryScreen/>,{wrapper:provider(command)});
  const options=mockSetOptions.mock.calls.at(-1)![0];
  const close=options.unstable_headerLeftItems()[0];
  expect(close.identifier).toBe('lava.toolbar.close');
  expect(close.icon).toEqual({type:'sfSymbol',name:'xmark'});
  act(()=>close.onPress());
  expect(mockGoBack).toHaveBeenCalledTimes(1);
  expect(mockNavigate).not.toHaveBeenCalled();
  expect(command).not.toHaveBeenCalled();
  view.unmount();
  await act(async()=>{});
  expect(command.mock.calls).toEqual([[{type:'customEntry.dismiss',id:'custom-draft'}]]);
});

test.each([true,false])('VPN DNS review returns only to the exact retained DNS editor (%s)',async exact=>{
  mockParams={returnTo:'DNS',returnKey:'original-dns'};
  mockGetState.mockReturnValue({index:1,routes:[{name:'DNS',key:exact?'original-dns':'other-dns'},{name:'VPNChaining',key:'native-page'}]});
  const command=jest.fn().mockResolvedValue(null);
  render(<VPNChainingScreen/>,{wrapper:provider(command)});
  await act(async()=>{});
  fireEvent.press(screen.getByText('Review DNS settings'));
  await act(async()=>{});
  // Exact returns use the retained route's usePreventRemove authentication gate.
  if(!exact)expect(command).toHaveBeenCalledWith({type:'navigation.authorize',surface:'appSettings'});
  if(exact){expect(mockGoBack).toHaveBeenCalledTimes(1);expect(mockNavigate).not.toHaveBeenCalled();}
  else {expect(mockGoBack).not.toHaveBeenCalled();expect(mockNavigate).toHaveBeenCalledWith('DNS');}
});

test('VPN page stays mounted through Control Center, background and focus changes like DNS',async()=>{
  const command=jest.fn().mockResolvedValue(null);
  const view=render(<VPNChainingScreen/>,{wrapper:provider(command)});
  const panel=screen.getByTestId('vpn.configuration-panel');
  for(const state of ['inactive','background','active'] as const){
    act(()=>{for(const [event,listener] of jest.mocked(AppState.addEventListener).mock.calls)if(event==='change')listener(state);});
    expect(screen.getByTestId('vpn.configuration-panel')).toBe(panel);
  }
  mockFocused=false;view.rerender(<VPNChainingScreen/>);
  mockFocused=true;view.rerender(<VPNChainingScreen/>);
  expect(screen.getByTestId('vpn.configuration-panel')).toBe(panel);
  expect(command).not.toHaveBeenCalled();
});
