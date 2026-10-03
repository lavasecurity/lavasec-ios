import {act,fireEvent,render,screen} from '@testing-library/react-native';
import {useLayoutEffect,useState,useSyncExternalStore} from 'react';
import {AppState,ScrollView,Text,TextInput,View,type AppStateStatus} from 'react-native';
import {Sheet,fullScreenModalPresentation,fullSheetPresentation,toolbarButton,nativeSearchOptions,useToolbar} from '../review/scaffold';
import {AppStore} from '../app/store';
import type {AppSnapshot} from '../app/contract';
import type {Spec} from '../specs/NativeLavaApp';
import {useAppQuery} from '../app/queries';
import {LiveRenderBoundary,ReviewContext,type ReviewState} from '../review/ReviewContext';

const mockNavigation={setOptions:jest.fn()};
jest.mock('@react-navigation/native',()=>({useNavigation:()=>mockNavigation,useIsFocused:()=>true}));
jest.mock('../specs/LavaTextFieldNativeComponent',()=>({__esModule:true,default:require('react-native').View}));
jest.mock('../specs/LavaDecorationNativeComponent',()=>({__esModule:true,default:require('react-native').View}));
function Editor(){const [value,setValue]=useState('');return <TextInput testID="sheet.editor" value={value} onChangeText={setValue}/>;}
function Contents({heading,pinned=false}:{heading?:string;pinned?:boolean}){
  return <Sheet header={pinned?<Text>{heading}</Text>:undefined}><Editor/></Sheet>;
}

test.each(['xmark','checkmark','arrow.clockwise','square.and.arrow.up'] as const)('toolbar %s delegates shape/grouping to the native bar and retains action identity',symbol=>{
  const onPress=jest.fn();const item=toolbarButton('Action',symbol,onPress,false,'action');
  expect(item).toMatchObject({type:'button',sharesBackground:symbol!=='checkmark',icon:{type:'sfSymbol',name:symbol},identifier:'action',accessibilityLabel:'Action'});
  item.onPress();expect(onPress).toHaveBeenCalledTimes(1);
  expect(toolbarButton('Action',symbol,onPress,true).disabled).toBe(true);
});
test('full sheets use native headers without duplicating a custom close control',()=>{
  expect(fullSheetPresentation).toMatchObject({presentation:'formSheet',headerShown:true,headerLargeTitleEnabled:false,headerTransparent:false});
  render(<Contents heading="Choose Blocklists"/>);
  expect(screen.queryByTestId('full-sheet.header')).toBeNull();
  expect(screen.UNSAFE_getByType(ScrollView)).toBeTruthy();
});
test('the full-screen Sudoku modal owns no title and no custom close control',()=>{
  // Sudoku uses this scaffold constant plus the shared Close item; the route
  // clears its own title so the immersive board has no heading.
  expect(fullScreenModalPresentation).toMatchObject({presentation:'fullScreenModal',headerShown:true,headerLargeTitleEnabled:false,headerTransparent:false,headerBackVisible:false});
  expect('title' in fullScreenModalPresentation).toBe(false);
});
test('pinned header updates retain the draft and the direct scroll hierarchy',()=>{
  render(<Contents heading="Choose Blocklists" pinned/>);
  fireEvent.changeText(screen.getByTestId('sheet.editor'),'my unsaved setup');
  screen.rerender(<Contents heading="Review" pinned/>);
  expect(screen.getByTestId('sheet.editor').props.value).toBe('my unsaved setup');
  expect(screen.UNSAFE_getByType(Sheet).children.map((child:{type:unknown}|string)=>typeof child==='string'?child:child.type)).toEqual([View,ScrollView]);
  expect(screen.getByTestId('sheet.pinned-header').props.collapsable).toBe(false);
});

test('native search sends edits and cancellation through the same controlled value owner',()=>{
  const change=jest.fn(); const options=nativeSearchOptions('Search domains',change);
  expect(options).toMatchObject({placement:'stacked',hideWhenScrolling:false,autoCapitalize:'none'});
  options.onChangeText!({nativeEvent:{text:'example.test'}} as never);
  expect(change).toHaveBeenLastCalledWith('example.test');
  options.onCancelButtonPress!({} as never);expect(change).toHaveBeenLastCalledWith('');
});

test('retained native header callbacks are inert through all-off resume and covered hydration',async()=>{
  const previousState=AppState.currentState;AppState.currentState='active';
  const listeners=new Set<(state:AppStateStatus)=>void>();
  const listener=jest.spyOn(AppState,'addEventListener').mockImplementation((_name,callback)=>{
    listeners.add(callback);return {remove:()=>listeners.delete(callback)};
  });
  const live={schema:1,fullApp:true,revision:1,backgroundPrivacyCoverRequired:false} as AppSnapshot;
  let publish!:(value:string)=>void;
  const native={getSnapshot:jest.fn(()=>new Promise<string>(()=>{})),
    command:jest.fn(async()=>JSON.stringify({snapshot:live,result:null})),
    onSnapshot:(callback:(value:string)=>void)=>{publish=callback;return {remove(){}};}} as unknown as Spec;
  const app=new AppStore(native,live);const disconnect=app.connect();
  const navigate=jest.fn();
  function Draft(){
    const [draft,setDraft]=useState('accepted');
    useToolbar({unstable_headerRightItems:()=>[toolbarButton('Save','checkmark',()=>{
      setDraft('changed');void app.command({type:'refresh'}).catch(()=>{});
    }),{type:'menu',label:'Options',menu:{items:[{type:'submenu',label:'Actions',items:[{type:'action',label:'Reset',onPress:()=>setDraft('reset')}]}]}}],unstable_headerLeftItems:()=>[toolbarButton('Close','xmark',navigate),{type:'custom',element:<Text>Native header content</Text>}],
    headerSearchBarOptions:nativeSearchOptions('Search',setDraft)},[draft]);
    return <Text testID="retained.header.draft">{draft}</Text>;
  }
  const value={app,live} as ReviewState;
  try {
    render(<ReviewContext.Provider value={value}><Draft/></ReviewContext.Provider>);
    const options=mockNavigation.setOptions.mock.calls.at(-1)![0];
    const save=options.unstable_headerRightItems()[0];
    const reset=options.unstable_headerRightItems()[1].menu.items[0].items[0];
    const close=options.unstable_headerLeftItems()[0];
    const emit=(state:AppStateStatus)=>act(()=>{AppState.currentState=state;listeners.forEach(callback=>callback(state));});
    emit('inactive');emit('active');
    expect(app.getSnapshot().snapshot).toBeNull();expect(app.getSnapshot().displaySnapshot).toBe(live);
    act(()=>{save.onPress();reset.onPress();close.onPress();options.headerSearchBarOptions.onChangeText({nativeEvent:{text:'lost draft'}});});
    expect(screen.getByTestId('retained.header.draft').props.children).toBe('accepted');
    expect(native.command).not.toHaveBeenCalled();expect(navigate).not.toHaveBeenCalled();
    expect(options.unstable_headerLeftItems()[1].element.props).toMatchObject({pointerEvents:'none',accessibilityElementsHidden:true});
    // A real privacy boundary restores native projection before its page reads.
    act(()=>publish(JSON.stringify({schema:1,fullApp:true,revision:2,presentationBlocked:true,backgroundPrivacyCoverRequired:true})));
    act(()=>publish(JSON.stringify({...live,revision:3,backgroundPrivacyCoverRequired:true})));
    expect(app.getPresentationHydration().required).toBe(true);
    act(()=>{save.onPress();close.onPress();options.headerSearchBarOptions.onCancelButtonPress({});});
    expect(screen.getByTestId('retained.header.draft').props.children).toBe('accepted');
    expect(native.command).not.toHaveBeenCalled();expect(navigate).not.toHaveBeenCalled();
    await act(async()=>app.completePresentationLayout(app.getPresentationHydration().epoch));
    expect(app.getPresentationHydration().required).toBe(false);
    await act(async()=>{save.onPress();close.onPress();});
    expect(screen.getByTestId('retained.header.draft').props.children).toBe('changed');
    expect(native.command).toHaveBeenCalledTimes(1);expect(navigate).toHaveBeenCalledTimes(1);
    expect(save).toMatchObject({disabled:false,identifier:'lava.toolbar.confirm',variant:'prominent'});
  } finally {disconnect();listener.mockRestore();AppState.currentState=previousState;}
});

test('a separately presented native sheet keeps its direct ScrollView covered and inert until fresh scoped reads commit',async()=>{
  const previousState=AppState.currentState;AppState.currentState='active';
  const lifecycle=jest.spyOn(AppState,'addEventListener').mockReturnValue({remove(){}});
  const live={schema:1,fullApp:true,revision:1,backgroundPrivacyCoverRequired:true} as AppSnapshot;
  let publish!:(value:string)=>void,resolve!:(value:string)=>void;
  const native={getSnapshot:()=>new Promise<string>(()=>{}),command:jest.fn(()=>new Promise<string>(done=>{resolve=done;})),
    onSnapshot:(callback:(value:string)=>void)=>{publish=callback;return {remove(){}};}} as unknown as Spec;
  const app=new AppStore(native,live),disconnect=app.connect();
  function PrivateSheet(){const query=useAppQuery<string>({type:'share.query',id:'same-id'});return <Sheet header={<Text>Private header</Text>} footer={<Text>Private footer</Text>}><Text>{query.value??'Loading filter'}</Text></Sheet>;}
  function NativeModalLayer(){const state=useSyncExternalStore(app.subscribe,app.getSnapshot),gate=useSyncExternalStore(app.subscribe,app.getPresentationHydration);
    useLayoutEffect(()=>{if(state.snapshot)app.completePresentationLayout(gate.epoch);},[state.snapshot,gate.epoch]);
    return <ReviewContext.Provider value={{app,live:state.snapshot??undefined} as ReviewState}><View testID="separate-uikit-controller"><LiveRenderBoundary component={PrivateSheet}/></View></ReviewContext.Provider>;}
  try{
    act(()=>publish(JSON.stringify({...live,revision:2,presentationBlocked:true})));act(()=>publish(JSON.stringify({...live,revision:3})));
    const view=render(<NativeModalLayer/>);await act(async()=>{});
    expect(screen.getByTestId('lava-route-privacy-cover').props.accessibilityViewIsModal).toBe(true);
    // This isolated UIKit controller has its own full-frame cover above the
    // prepared sheet. No root-overlay assertion belongs in this harness.
    const routeLayer=screen.UNSAFE_getByType(LiveRenderBoundary);
    expect(routeLayer.children).toHaveLength(2);
    const overlay=routeLayer.children.at(-1);
    expect(typeof overlay).not.toBe('string');
    expect((overlay as {props:{style:unknown}}).props.style).toMatchObject({position:'absolute',top:0,bottom:0,left:0,right:0,zIndex:1});
    expect(screen.getByText('Loading filter',{includeHiddenElements:true})).toBeTruthy();
    expect(screen.queryByText('Loading filter')).toBeNull();
    expect(screen.UNSAFE_getByType(ScrollView).props).toMatchObject({pointerEvents:'none',accessibilityElementsHidden:true,importantForAccessibility:'no-hide-descendants'});
    expect(screen.getByTestId('sheet.pinned-header',{includeHiddenElements:true}).props.pointerEvents).toBe('none');
    expect(screen.UNSAFE_getByType(Sheet).children.map((child:{type:unknown}|string)=>typeof child==='string'?child:child.type)).toEqual([View,ScrollView]);
    const footer=mockNavigation.setOptions.mock.calls.at(-1)![0].unstable_sheetFooter();const nativeFooter=render(footer);
    expect(nativeFooter.getByTestId('sheet.native-footer',{includeHiddenElements:true}).props).toMatchObject({pointerEvents:'none',accessibilityElementsHidden:true});
    expect(nativeFooter.getByTestId('sheet.native-footer',{includeHiddenElements:true}).props.children.props.style).toContainEqual({opacity:0});
    await act(async()=>resolve(JSON.stringify({snapshot:{...live,revision:3},result:'fresh private code'})));
    expect(view.queryByTestId('lava-route-privacy-cover')).toBeNull();expect(view.getByText('fresh private code')).toBeTruthy();
    expect(view.queryByText('Loading filter',{includeHiddenElements:true})).toBeNull();
    expect(view.UNSAFE_getByType(ScrollView).props).toMatchObject({pointerEvents:'auto',accessibilityElementsHidden:false});
    act(()=>publish(JSON.stringify({...live,revision:4,presentationBlocked:true})));
    expect(mockNavigation.setOptions).toHaveBeenLastCalledWith({unstable_sheetFooter:undefined});
    expect(nativeFooter.getByTestId('sheet.native-footer',{includeHiddenElements:true}).props.children.props.style).toContainEqual({opacity:0});
    nativeFooter.unmount();view.unmount();
  }finally{act(()=>disconnect());lifecycle.mockRestore();AppState.currentState=previousState;}
});

test('a native footer keeps all-off pixels while paused and conceals independently when native policy revokes the body',async()=>{
  const previousState=AppState.currentState;AppState.currentState='active';const listeners=new Set<(state:AppStateStatus)=>void>();
  const lifecycle=jest.spyOn(AppState,'addEventListener').mockImplementation((_event,listener)=>{listeners.add(listener);return {remove:()=>listeners.delete(listener)};});
  const live={schema:1,fullApp:true,revision:1,backgroundPrivacyCoverRequired:false} as AppSnapshot;let publish!:(value:string)=>void;
  const native={getSnapshot:()=>new Promise<string>(()=>{}),command:jest.fn(),onSnapshot:(callback:(value:string)=>void)=>{publish=callback;return {remove(){}};}} as unknown as Spec;
  const app=new AppStore(native,live),disconnect=app.connect();
  try{
    const body=render(<ReviewContext.Provider value={{app,live} as ReviewState}><Sheet footer={<Text>3704 rules</Text>}><Text>Body</Text></Sheet></ReviewContext.Provider>);
    const captured=mockNavigation.setOptions.mock.calls.at(-1)![0].unstable_sheetFooter;const footer=render(captured());
    const nativeFooter=()=>footer.getByTestId('sheet.native-footer',{includeHiddenElements:true});
    act(()=>{AppState.currentState='inactive';listeners.forEach(listener=>listener('inactive'));});
    expect(nativeFooter().props).toMatchObject({pointerEvents:'none',accessibilityElementsHidden:true});expect(nativeFooter().props.children.props.style).not.toContainEqual({opacity:0});
    act(()=>publish(JSON.stringify({...live,revision:2,presentationBlocked:true,backgroundPrivacyCoverRequired:true})));
    expect(nativeFooter().props.children.props.style).toContainEqual({opacity:0});
    body.unmount();expect(mockNavigation.setOptions).toHaveBeenLastCalledWith({unstable_sheetFooter:undefined});expect(captured()).toBeNull();
    await act(async()=>{AppState.currentState='active';publish(JSON.stringify({...live,revision:3}));app.completePresentationLayout(app.getPresentationHydration().epoch);});
    expect(app.getPresentationHydration().required).toBe(false);expect(captured()).toBeNull();
    expect(nativeFooter().props).toMatchObject({pointerEvents:'none',accessibilityElementsHidden:true});expect(nativeFooter().props.children.props.style).toContainEqual({opacity:0});footer.unmount();
  }finally{act(()=>disconnect());lifecycle.mockRestore();AppState.currentState=previousState;}
});
test('native toolbar renderers and saved callbacks retire with an erased private owner and cannot act after new hydration',async()=>{
  const previousState=AppState.currentState;AppState.currentState='active';const lifecycle=jest.spyOn(AppState,'addEventListener').mockReturnValue({remove(){}});
  const live={schema:1,fullApp:true,revision:1,backgroundPrivacyCoverRequired:false} as AppSnapshot;let publish!:(value:string)=>void;
  const native={getSnapshot:()=>new Promise<string>(()=>{}),command:jest.fn(async()=>JSON.stringify({snapshot:{...live,revision:3},result:null})),onSnapshot:(callback:(value:string)=>void)=>{publish=callback;return {remove(){}};}} as unknown as Spec;
  const app=new AppStore(native,live),disconnect=app.connect();
  function Owner(){const [draft]=useState('discarded private DNS');useToolbar({title:draft,unstable_headerRightItems:()=>[toolbarButton('Save','checkmark',()=>void app.command({type:'refresh'}))],headerSearchBarOptions:nativeSearchOptions('Search',()=>void app.command({type:'refresh'}))},[draft]);return <Text>{draft}</Text>;}
  function Route(){const state=useSyncExternalStore(app.subscribe,app.getSnapshot),gate=useSyncExternalStore(app.subscribe,app.getPresentationHydration);useLayoutEffect(()=>{if(state.snapshot)app.completePresentationLayout(gate.epoch);},[state.snapshot,gate.epoch]);return <ReviewContext.Provider value={{app,live:state.snapshot??undefined} as ReviewState}><LiveRenderBoundary component={Owner}/></ReviewContext.Provider>;}
  try{
    const view=render(<Route/>);const old=mockNavigation.setOptions.mock.calls.at(-1)![0],save=old.unstable_headerRightItems()[0];
    act(()=>publish(JSON.stringify({...live,revision:2,presentationBlocked:true,backgroundPrivacyCoverRequired:true})));
    expect(mockNavigation.setOptions).toHaveBeenLastCalledWith(expect.objectContaining({unstable_headerRightItems:undefined,headerSearchBarOptions:undefined,title:undefined}));
    await act(async()=>publish(JSON.stringify({...live,revision:3})));
    expect(app.getPresentationHydration().required).toBe(false);
    await act(async()=>{save.onPress();old.headerSearchBarOptions.onChangeText({nativeEvent:{text:'stale'}});});
    expect(native.command).not.toHaveBeenCalled();expect(old.unstable_headerRightItems()).toEqual([]);
    const current=mockNavigation.setOptions.mock.calls.at(-1)![0];await act(async()=>current.unstable_headerRightItems()[0].onPress());expect(native.command).toHaveBeenCalledTimes(1);
    view.unmount();
  }finally{act(()=>disconnect());lifecycle.mockRestore();AppState.currentState=previousState;}
});

test('retiring a right-only toolbar owner preserves the unowned native route Close option through remount',async()=>{
  const previousState=AppState.currentState;AppState.currentState='active';const lifecycle=jest.spyOn(AppState,'addEventListener').mockReturnValue({remove(){}});
  const close=jest.fn(),baseClose=()=>[toolbarButton('Close','xmark',close)];
  const merged:Record<string,unknown>={unstable_headerLeftItems:baseClose};mockNavigation.setOptions.mockImplementation(options=>Object.assign(merged,options));
  const live={schema:1,fullApp:true,revision:1,backgroundPrivacyCoverRequired:false} as AppSnapshot;let publish!:(value:string)=>void;
  const native={getSnapshot:()=>new Promise<string>(()=>{}),command:jest.fn(),onSnapshot:(callback:(value:string)=>void)=>{publish=callback;return {remove(){}};}} as unknown as Spec;
  const app=new AppStore(native,live),disconnect=app.connect();
  function ShareOwner(){useToolbar({title:'Private filter',unstable_headerRightItems:()=>[toolbarButton('Share','square.and.arrow.up',()=>{})]},[]);return <Text>Code</Text>;}
  function Route(){const state=useSyncExternalStore(app.subscribe,app.getSnapshot),gate=useSyncExternalStore(app.subscribe,app.getPresentationHydration);useLayoutEffect(()=>{if(state.snapshot)app.completePresentationLayout(gate.epoch);},[state.snapshot,gate.epoch]);return <ReviewContext.Provider value={{app,live:state.snapshot??undefined} as ReviewState}><LiveRenderBoundary component={ShareOwner}/></ReviewContext.Provider>;}
  try{
    const view=render(<Route/>);expect(merged.unstable_headerLeftItems).toBe(baseClose);
    act(()=>publish(JSON.stringify({...live,revision:2,presentationBlocked:true,backgroundPrivacyCoverRequired:true})));
    expect(merged.unstable_headerLeftItems).toBe(baseClose);expect(merged.unstable_headerRightItems).toBeUndefined();
    await act(async()=>publish(JSON.stringify({...live,revision:3})));
    expect(merged.unstable_headerLeftItems).toBe(baseClose);expect(typeof merged.unstable_headerRightItems).toBe('function');
    baseClose()[0]!.onPress();expect(close).toHaveBeenCalledTimes(1);view.unmount();
  }finally{act(()=>disconnect());lifecycle.mockRestore();AppState.currentState=previousState;mockNavigation.setOptions.mockReset();}
});
