import {AppState,PlatformColor,StyleSheet,View,type AppStateStatus} from 'react-native';
import {act,fireEvent,render,screen} from '@testing-library/react-native';
import NativeApp from '../specs/NativeLavaApp';
import {PasscodeFlowAdapter,PasscodeRuntime} from '../review/PasscodeFlowAdapter.ios';
import {PasscodeScreen} from '../src/flows/passcode/PasscodeScreen';
import {Symbol} from '../review/primitives';
import {colors} from '../src/colors';
import type {PasscodeState} from '../src/flows/passcode/types';
const mockNavigation={setOptions:jest.fn(),isFocused:()=>true};
let mockHeaderHeight=0;
let mockSafeAreaInsets={top:0,right:0,bottom:0,left:0};
jest.mock('@react-navigation/native',()=>({NavigationContainer:({children}:any)=>children,DefaultTheme:{},DarkTheme:{},useNavigation:()=>mockNavigation,useIsFocused:()=>true}));
jest.mock('@react-navigation/elements',()=>({useHeaderHeight:()=>mockHeaderHeight}));
jest.mock('@react-navigation/native-stack',()=>({createNativeStackNavigator:()=>({Navigator:({children}:any)=>children,Screen:({children}:any)=>typeof children==='function'?children():children})}));
jest.mock('react-native-safe-area-context',()=>({...require('react-native-safe-area-context/jest/mock').default,useSafeAreaInsets:()=>mockSafeAreaInsets}));
jest.mock('../specs/NativeLavaApp',()=>({__esModule:true,default:{getSnapshot:jest.fn(),onSnapshot:jest.fn(),command:jest.fn(async()=>JSON.stringify({}))}}));
jest.mock('../specs/NativeLavaAppearance',()=>({__esModule:true,default:{getSnapshot:jest.fn(async()=>({preference:'system',revision:0})),onSnapshot:jest.fn(()=>({remove:jest.fn()}))}}));
jest.mock('../specs/LavaPasscodeInputNativeComponent',()=>({__esModule:true,default:require('react-native').View}));
jest.mock('../specs/LavaDecorationNativeComponent',()=>({__esModule:true,default:require('react-native').View}));
jest.mock('../specs/LavaInlineSymbolTextNativeComponent',()=>({__esModule:true,default:'NativeInlineSymbolText'}));
jest.mock('../specs/NativeLavaReview',()=>({__esModule:true,default:{getGuardAccents:()=>JSON.stringify({})}}));
const deferred=()=>{let resolve!:(value:string)=>void;const promise=new Promise<string>(yes=>{resolve=yes;});return {promise,resolve};};
const publicState:PasscodeState={id:'auth-visit',authenticating:true,title:'Enter Passcode',subtitle:'Unlock Lava',message:''};
const wire=(revision:number,state:PasscodeState|null=publicState)=>JSON.stringify({revision,passcode:state,presentation:{locale:'en',textScales:null}});
const originalState=AppState.currentState;
let deliver:(value:string)=>void;
let lifecycle:(state:AppStateStatus)=>void;
let reads:ReturnType<typeof deferred>[];
beforeEach(()=>{
  Object.defineProperty(AppState,'currentState',{configurable:true,value:'active'});reads=[];
  mockHeaderHeight=0;mockSafeAreaInsets={top:0,right:0,bottom:0,left:0};
  mockNavigation.setOptions.mockClear();
  jest.mocked(NativeApp!.getSnapshot).mockImplementation(()=>{const read=deferred();reads.push(read);return read.promise;});
  jest.mocked(NativeApp!.onSnapshot).mockImplementation(listener=>{deliver=listener;return {remove:jest.fn()};});
  jest.spyOn(AppState,'addEventListener').mockImplementation((_name,listener)=>{lifecycle=listener as (state:AppStateStatus)=>void;return {remove:jest.fn()};});
  jest.mocked(NativeApp!.command).mockClear();
});
afterEach(()=>jest.restoreAllMocks());
afterAll(()=>Object.defineProperty(AppState,'currentState',{configurable:true,value:originalState}));
const changeState=(value:AppStateStatus)=>{Object.defineProperty(AppState,'currentState',{configurable:true,value});lifecycle(value);};
test('a delayed query cannot replace a newer native passcode validation event',async()=>{
  render(<PasscodeRuntime ownerID={publicState.id} initialSnapshot={wire(1)}/>);
  await act(async()=>{});
  expect(screen.UNSAFE_getByType(Symbol).props).toMatchObject({name:'lock.shield.fill',size:47,height:154/3,pointSize:44,weight:'semibold',responsive:false});
  await act(async()=>deliver(wire(3,{...publicState,message:'Wrong passcode'})));
  expect(screen.getByTestId('passcode.message')).toHaveProp('title','Wrong passcode');
  await act(async()=>reads[0]!.resolve(wire(2)));
  expect(screen.getByTestId('passcode.message')).toHaveProp('title','Wrong passcode');
});
test('background clearing rejects late queries and events and resumes through a new native read',async()=>{
  render(<PasscodeRuntime ownerID={publicState.id} initialSnapshot={wire(1)}/>);
  await act(async()=>changeState('background'));expect(screen.queryByTestId('passcode-screen')).toBeNull();
  await act(async()=>{reads[0]!.resolve(wire(2));deliver(wire(3));});expect(screen.queryByTestId('passcode-screen')).toBeNull();
  await act(async()=>changeState('active'));expect(reads).toHaveLength(2);
  await act(async()=>reads[1]!.resolve(wire(4)));expect(screen.getByTestId('passcode-screen')).toBeTruthy();
});
test('a query begun before a background cycle stays retired even after foreground',async()=>{
  render(<PasscodeRuntime ownerID={publicState.id} initialSnapshot={wire(1)}/>);
  await act(async()=>{changeState('background');changeState('active');});
  await act(async()=>reads[0]!.resolve(wire(10,{...publicState,message:'Retired response'})));
  expect(screen.queryByTestId('passcode.message')).toBeNull();expect(screen.queryByTestId('passcode-screen')).toBeNull();
  await act(async()=>reads[1]!.resolve(wire(2)));expect(screen.getByTestId('passcode-screen')).toBeTruthy();
});
test('the runtime renders only the exact native request owner',async()=>{
  render(<PasscodeRuntime ownerID={publicState.id} initialSnapshot={wire(1,{...publicState,id:'other-visit'})}/>);
  expect(screen.queryByTestId('passcode-screen')).toBeNull();await act(async()=>deliver(wire(2)));expect(screen.getByTestId('passcode-screen')).toBeTruthy();
});
test('authentication waits for its native header admission and uses only the remaining safe viewport',async()=>{
  const header=deferred();jest.mocked(NativeApp!.command).mockReturnValueOnce(header.promise);
  mockHeaderHeight=103;mockSafeAreaInsets={top:0,right:20,bottom:0,left:12};
  render(<PasscodeRuntime ownerID={publicState.id} initialSnapshot={wire(1)}/>);
  expect(screen.queryByTestId('passcode-screen')).toBeNull();
  expect(jest.mocked(NativeApp!.command).mock.calls.map(([request])=>JSON.parse(request))).toEqual([
    {type:'passcode.header',id:publicState.id,title:'Authentication',cancelTitle:'Cancel',showCancel:true},
  ]);
  expect(mockNavigation.setOptions).not.toHaveBeenCalled();
  await act(async()=>header.resolve('{}'));
  expect(screen.UNSAFE_getByType(PasscodeScreen).props.contentInsets).toEqual({top:0,right:20,bottom:0,left:12});
  expect(StyleSheet.flatten(screen.getByTestId('passcode-screen').props.style)).toMatchObject({paddingTop:24,paddingRight:44,paddingBottom:24,paddingLeft:36});
  fireEvent(screen.getByTestId('passcode-screen'),'touchEnd');
  expect(JSON.parse(jest.mocked(NativeApp!.command).mock.calls.at(-1)![0])).toEqual({type:'passcode.command',id:publicState.id,action:'focus'});
});
test('retired header acknowledgements cannot mount credentials after background or owner replacement',async()=>{
  const oldHeader=deferred();jest.mocked(NativeApp!.command).mockReturnValueOnce(oldHeader.promise);
  const view=render(<PasscodeRuntime ownerID={publicState.id} initialSnapshot={wire(1)}/>);
  await act(async()=>changeState('background'));
  await act(async()=>oldHeader.resolve('{}'));
  expect(screen.queryByTestId('passcode-screen')).toBeNull();
  await act(async()=>changeState('active'));
  const newHeader=deferred();jest.mocked(NativeApp!.command).mockReturnValueOnce(newHeader.promise);
  await act(async()=>reads[1]!.resolve(wire(2)));
  view.rerender(<PasscodeRuntime ownerID="replacement-owner" initialSnapshot={wire(2)}/>);
  await act(async()=>newHeader.resolve('{}'));
  expect(screen.queryByTestId('passcode-screen')).toBeNull();
});
test('a rejected native header never mounts the credential atoms',async()=>{
  jest.mocked(NativeApp!.command).mockRejectedValueOnce(new Error('Authentication cancelled.'));
  render(<PasscodeRuntime ownerID={publicState.id} initialSnapshot={wire(1)}/>);
  await act(async()=>{});
  expect(screen.queryByTestId('passcode-screen')).toBeNull();
});
test('the shared screen takes metadata and native atoms and exposes a refocus port',()=>{
  const onRefocus=jest.fn();render(<PasscodeScreen state={publicState} onRefocus={onRefocus} glyph={<View/>} digits={<View testID="native-digits"/>} input={<View testID="native-input"/>}/>);
  expect(Object.keys(screen.UNSAFE_getByType(PasscodeScreen).props.state).sort()).toEqual(['authenticating','id','message','subtitle','title']);
  fireEvent(screen.getByTestId('passcode-screen'),'touchEnd');expect(onRefocus).toHaveBeenCalledTimes(1);
  expect(screen.getByTestId('native-input')).toBeTruthy();expect(screen.getByTestId('native-digits')).toBeTruthy();
});
test.each([true,false])('the iOS adapter reserves the measured bar after initial layout without replacing its native input (authenticating %s)',authenticating=>{
  const state={...publicState,authenticating};
  const view=render(<PasscodeFlowAdapter state={state}/>);
  const input=()=>screen.UNSAFE_getAllByType(View).find(node=>node.props.kind==='field');
  const initialInput=input();
  expect(initialInput).toBeDefined();
  expect(screen.UNSAFE_getByType(PasscodeScreen).props.contentInsets).toEqual({top:0,right:0,bottom:0,left:0});
  expect(StyleSheet.flatten(screen.getByTestId('passcode-screen').props.style)).toMatchObject({paddingTop:24,paddingBottom:24});
  mockHeaderHeight=44;view.rerender(<PasscodeFlowAdapter state={state}/>);
  expect(screen.UNSAFE_getByType(PasscodeScreen).props.contentInsets).toEqual({top:44,right:0,bottom:0,left:0});
  expect(StyleSheet.flatten(screen.getByTestId('passcode-screen').props.style)).toMatchObject({paddingTop:68,paddingBottom:24,gap:28});
  expect(input()).toBe(initialInput);
});
test('the iOS adapter counts residual safe areas once and does not add the status inset already included in the bar',()=>{
  mockHeaderHeight=103;mockSafeAreaInsets={top:59,right:20,bottom:34,left:12};
  const view=render(<PasscodeFlowAdapter state={publicState}/>);
  expect(screen.UNSAFE_getByType(PasscodeScreen).props.contentInsets).toEqual({top:103,right:20,bottom:34,left:12});
  expect(StyleSheet.flatten(screen.getByTestId('passcode-screen').props.style)).toMatchObject({paddingTop:127,paddingRight:44,paddingBottom:58,paddingLeft:36});
  // A native host may consume these edges when its available viewport changes.
  // Its new frame supplies keyboard avoidance; the shared screen adds no second
  // keyboard offset and retains only the currently reported residual insets.
  mockSafeAreaInsets={top:0,right:0,bottom:0,left:0};view.rerender(<PasscodeFlowAdapter state={publicState}/>);
  expect(StyleSheet.flatten(screen.getByTestId('passcode-screen').props.style)).toMatchObject({paddingTop:127,paddingRight:24,paddingBottom:24,paddingLeft:24});
});
test('the shared default keeps its generic error paint and only the subtitle centers wrapped lines',()=>{
  const state={...publicState,message:'Wrong passcode'};
  render(<PasscodeScreen state={state} glyph={<View/>} digits={<View/>} input={<View/>}/>);
  expect(StyleSheet.flatten(screen.getByText(state.title).props.style)).toMatchObject({color:colors.primaryText});
  expect(StyleSheet.flatten(screen.getByText(state.title).props.style).textAlign).toBeUndefined();
  expect(StyleSheet.flatten(screen.getByText(state.subtitle).props.style).textAlign).toBe('center');
  expect(StyleSheet.flatten(screen.getByText(state.message).props.style)).toMatchObject({color:colors.errorText});
  expect(StyleSheet.flatten(screen.getByText(state.message).props.style).textAlign).toBeUndefined();
});
test('the iOS adapter authors separate semantic text leaves with the original box and paragraph alignment',()=>{
  const state={...publicState,message:'Wrong passcode'};
  render(<PasscodeFlowAdapter state={state}/>);
  expect(screen.getByTestId('passcode.title').props).toMatchObject({title:state.title,symbol:'',textStyle:'title1',fontSize:28,fontWeight:'bold',textColor:PlatformColor('label'),contentAlignment:'center',multilineAlignment:'leading'});
  expect(screen.getByTestId('passcode.subtitle').props).toMatchObject({title:state.subtitle,symbol:'',textStyle:'subheadline',fontSize:15,fontWeight:'regular',textColor:colors.secondaryText,contentAlignment:'center',multilineAlignment:'center'});
  expect(screen.getByTestId('passcode.message').props).toMatchObject({title:state.message,symbol:'',textStyle:'footnote',fontSize:13,fontWeight:'semibold',textColor:PlatformColor('systemRed'),contentAlignment:'center',multilineAlignment:'leading'});
  const titleGroup=screen.UNSAFE_getAllByType(View).find(node=>StyleSheet.flatten(node.props.style)?.gap===8)!;
  expect(StyleSheet.flatten(titleGroup.props.style)).toMatchObject({alignItems:'center',alignSelf:'stretch'});
  expect(StyleSheet.flatten(screen.getByTestId('passcode-screen').props.style)).toMatchObject({gap:28,padding:24});
});
test('platform text slots replace only the supplied runs and preserve optional message spacing',()=>{
  const state={...publicState,message:''};
  const props={glyph:<View/>,digits:<View/>,input:<View/>,titleContent:<View testID="platform-title"/>,messageContent:<View testID="platform-message"/>};
  const view=render(<PasscodeScreen state={state} {...props}/>);
  expect(screen.getByTestId('platform-title')).toBeTruthy();expect(screen.queryByText(state.title)).toBeNull();
  expect(screen.getByText(state.subtitle)).toBeTruthy();expect(screen.queryByTestId('platform-message')).toBeNull();
  view.rerender(<PasscodeScreen state={{...state,message:'Wrong passcode'}} {...props}/>);
  expect(screen.getByTestId('platform-message')).toBeTruthy();expect(screen.queryByText('Wrong passcode')).toBeNull();
});
