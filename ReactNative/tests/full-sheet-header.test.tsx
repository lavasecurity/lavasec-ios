import {act,fireEvent,render,screen} from '@testing-library/react-native';
import {createRef,useLayoutEffect,useState,useSyncExternalStore} from 'react';
import {AppState,ScrollView,StyleSheet,Text,TextInput,View,type AppStateStatus,type ScrollViewInstance,type ViewStyle} from 'react-native';
import {HeaderHeightContext} from '@react-navigation/elements';
import {SafeAreaInsetsContext} from 'react-native-safe-area-context';
import {Sheet,fullScreenModalPresentation,fullSheetPresentation,toolbarButton,nativeSearchOptions,useToolbar} from '../review/scaffold';
import {AppStore} from '../app/store';
import type {AppSnapshot} from '../app/contract';
import type {Spec} from '../specs/NativeLavaApp';
import {useAppQuery} from '../app/queries';
import {LiveRenderBoundary,ReviewContext,type ReviewState} from '../review/ReviewContext';
import {foundation} from '../src/foundation';
import {CatalogSheet} from '../review/story-scaffold';

const mockNavigation={setOptions:jest.fn(),addListener:jest.fn((_name:string,_listener:(event:{data:{closing:boolean}})=>void)=>()=>{})};
jest.mock('@react-navigation/native',()=>({useNavigation:()=>mockNavigation,useIsFocused:()=>true}));
jest.mock('../specs/NativeLavaReview',()=>({__esModule:true,default:{getGuardAccents:()=>JSON.stringify({})}}));
jest.mock('../specs/LavaTextFieldNativeComponent',()=>({__esModule:true,default:require('react-native').View}));
jest.mock('../specs/LavaDecorationNativeComponent',()=>({__esModule:true,default:require('react-native').View}));
function Editor(){const [value,setValue]=useState('');return <TextInput testID="sheet.editor" value={value} onChangeText={setValue}/>;}
function Contents({heading,pinned=false}:{heading?:string;pinned?:boolean}){
  return <Sheet header={pinned?<Text>{heading}</Text>:undefined}><Editor/></Sheet>;
}
function ancestorStyle(element:ReturnType<typeof screen.getByTestId>,matches:(style:ViewStyle)=>boolean):ViewStyle{
  for(let ancestor=element.parent;ancestor;ancestor=ancestor.parent){
    const style=StyleSheet.flatten(ancestor.props.style) as ViewStyle|undefined;
    if(style&&matches(style))return style;
  }
  throw new Error('Expected a styled sheet content ancestor.');
}

test.each(['xmark','checkmark','arrow.clockwise','square.and.arrow.up'] as const)('toolbar %s delegates shape/grouping to the native bar and retains action identity',symbol=>{
  const onPress=jest.fn();const item=toolbarButton('Action',symbol,onPress,false,'action');
  expect(item).toMatchObject({type:'button',sharesBackground:symbol!=='checkmark',icon:{type:'sfSymbol',name:symbol},identifier:'action',accessibilityLabel:'Action'});
  item.onPress();expect(onPress).toHaveBeenCalledTimes(1);
  expect(toolbarButton('Action',symbol,onPress,true).disabled).toBe(true);
});
test('full sheets use native headers without duplicating a custom close control',()=>{
  expect(fullSheetPresentation).toMatchObject({presentation:'formSheet',headerShown:true,headerLargeTitleEnabled:false,headerTransparent:true});
  render(<Contents heading="Choose Blocklists"/>);
  expect(screen.queryByTestId('full-sheet.header')).toBeNull();
  expect(screen.UNSAFE_getByType(ScrollView)).toBeTruthy();
});
test('the full-screen Sudoku modal owns no title and no custom close control',()=>{
  // Sudoku uses this scaffold constant plus the shared Close item; the route
  // clears its own title so the immersive board has no heading.
  expect(fullScreenModalPresentation).toMatchObject({presentation:'fullScreenModal',headerShown:true,headerLargeTitleEnabled:false,headerTransparent:true,headerBackVisible:false});
  expect('title' in fullScreenModalPresentation).toBe(false);
});
test('pinned header updates retain the draft and the direct scroll hierarchy',()=>{
  render(<Contents heading="Choose Blocklists" pinned/>);
  fireEvent.changeText(screen.getByTestId('sheet.editor'),'my unsaved setup');
  screen.rerender(<Contents heading="Review" pinned/>);
  expect(screen.getByTestId('sheet.editor').props.value).toBe('my unsaved setup');
  expect(screen.UNSAFE_getByType(Sheet).children.map((child:{type:unknown}|string)=>typeof child==='string'?child:child.type)).toEqual([ScrollView]);
  expect(screen.UNSAFE_getByType(ScrollView).props.stickyHeaderIndices).toEqual([0]);
  expect(screen.getByTestId('sheet.pinned-header').props.collapsable).toBe(false);
});
test.each([false,true])('sheet content owns asymmetric safe edges without narrowing its scroll or replacing the editor (pinned=%s)',pinned=>{
  const content=(left:number,right:number)=><SafeAreaInsetsContext.Provider value={{top:0,bottom:21,left,right}}>
    <HeaderHeightContext.Provider value={54}><Contents heading="Choose Blocklists" pinned={pinned}/></HeaderHeightContext.Provider>
  </SafeAreaInsetsContext.Provider>;
  render(content(59,44));const scroll=screen.UNSAFE_getByType(ScrollView),editor=screen.getByTestId('sheet.editor');
  const bodyStyle=()=>pinned?ancestorStyle(editor,style=>style.maxWidth!==undefined&&style.paddingHorizontal===foundation.space.screenHorizontal):StyleSheet.flatten(scroll.props.contentContainerStyle);
  const headerStyle=()=>ancestorStyle(screen.getByText('Choose Blocklists'),style=>style.paddingHorizontal===foundation.space.screenHorizontal&&style.paddingTop===foundation.space.md);
  const expected=(left:number,right:number)=>({width:'100%',maxWidth:foundation.layout.readingWidth+left+right,
    paddingLeft:foundation.space.screenHorizontal+left,paddingRight:foundation.space.screenHorizontal+right});
  expect(bodyStyle()).toMatchObject(expected(59,44));
  expect(StyleSheet.flatten(scroll.props.style)).toEqual({flex:1,backgroundColor:expect.anything()});
  expect(scroll.props.automaticallyAdjustKeyboardInsets).toBe(true);
  expect(scroll.props.contentInsetAdjustmentBehavior).toBe('never');
  expect(scroll.props.contentInset).toEqual({top:54});
  if(pinned){
    expect(headerStyle()).toMatchObject({
      paddingLeft:foundation.space.screenHorizontal+59,paddingRight:foundation.space.screenHorizontal+44});
    expect(StyleSheet.flatten(scroll.props.contentContainerStyle).paddingLeft).toBeUndefined();
  }
  fireEvent.changeText(editor,'retained asymmetric draft');
  screen.rerender(content(44,59));expect(bodyStyle()).toMatchObject(expected(44,59));
  screen.rerender(content(0,0));
  expect(screen.UNSAFE_getByType(ScrollView)).toBe(scroll);expect(screen.getByTestId('sheet.editor')).toBe(editor);
  expect(editor.props.value).toBe('retained asymmetric draft');
  expect(bodyStyle()).toMatchObject({maxWidth:foundation.layout.readingWidth,paddingHorizontal:foundation.space.screenHorizontal});
  expect(bodyStyle().paddingLeft).toBeUndefined();expect(bodyStyle().paddingRight).toBeUndefined();
  if(pinned){const style=headerStyle();
    expect(style.paddingLeft).toBeUndefined();expect(style.paddingRight).toBeUndefined();}
  expect(scroll.props.contentInset).toEqual({top:54});
});
test('pinned controls follow the measured native bar through height changes',()=>{
  render(<HeaderHeightContext.Provider value={70}><Contents heading="Choose Blocklists" pinned/></HeaderHeightContext.Provider>);
  expect(screen.UNSAFE_getByType(ScrollView).props).toMatchObject({contentInset:{top:70},contentOffset:{x:0,y:-70},scrollIndicatorInsets:{top:70},contentInsetAdjustmentBehavior:'never'});
  fireEvent.changeText(screen.getByTestId('sheet.editor'),'unsaved picker draft');
  fireEvent.scroll(screen.UNSAFE_getByType(ScrollView),{nativeEvent:{contentOffset:{x:0,y:200}}});
  screen.rerender(<HeaderHeightContext.Provider value={54}><Contents heading="Choose Blocklists" pinned/></HeaderHeightContext.Provider>);
  expect(screen.UNSAFE_getByType(ScrollView).props.contentInset).toEqual({top:54});
  expect(screen.UNSAFE_getByType(ScrollView).props.contentOffset).toEqual({x:0,y:216});
  expect(screen.getByTestId('sheet.editor').props.value).toBe('unsaved picker draft');
});
test('initial sheet presentation settles the pinned offset once without resetting later scrolling',()=>{
  const scroll=createRef<ScrollViewInstance>();
  render(<HeaderHeightContext.Provider value={56}><Sheet scrollRef={scroll} header={<Text>Search</Text>}><Editor/></Sheet></HeaderHeightContext.Provider>);
  const scrollTo=jest.spyOn(scroll.current!,'scrollTo').mockImplementation(()=>{});
  const transition=mockNavigation.addListener.mock.calls.at(-1)![1] as (event:{data:{closing:boolean}})=>void;
  act(()=>transition({data:{closing:false}}));
  expect(scrollTo).toHaveBeenCalledWith({x:0,y:-56,animated:false});
  fireEvent.scroll(screen.UNSAFE_getByType(ScrollView),{nativeEvent:{contentOffset:{x:0,y:200}}});
  fireEvent.changeText(screen.getByTestId('sheet.editor'),'retained draft');
  act(()=>transition({data:{closing:false}}));
  expect(scrollTo).toHaveBeenCalledTimes(1);
  expect(screen.getByTestId('sheet.editor').props.value).toBe('retained draft');
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
    const view=render(<ReviewContext.Provider value={value}><Draft/></ReviewContext.Provider>);
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
    expect(screen.getByTestId('retained.header.draft').props.children).toBe('accepted');
    view.rerender(<ReviewContext.Provider value={{...value,live:{...live,revision:3,backgroundPrivacyCoverRequired:true}}}><Draft/></ReviewContext.Provider>);
    const current=mockNavigation.setOptions.mock.calls.at(-1)![0];
    await act(async()=>{current.unstable_headerRightItems()[0].onPress();current.unstable_headerLeftItems()[0].onPress();});
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
    return <ReviewContext.Provider value={{app,live:state.snapshot??undefined} as ReviewState}><View testID="separate-uikit-controller"><LiveRenderBoundary component={PrivateSheet} retainBody={false}/></View></ReviewContext.Provider>;}
  try{
    act(()=>publish(JSON.stringify({...live,revision:2,presentationBlocked:true})));act(()=>publish(JSON.stringify({...live,revision:3})));
    const view=render(<NativeModalLayer/>);await act(async()=>{});
    fireEvent(screen.UNSAFE_getByType(ScrollView),'layout',{nativeEvent:{layout:{x:0,y:0,width:390,height:844}}});
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
    expect(screen.UNSAFE_getByType(Sheet).children.map((child:{type:unknown}|string)=>typeof child==='string'?child:child.type)).toEqual([ScrollView]);
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
  function Route(){const state=useSyncExternalStore(app.subscribe,app.getSnapshot),gate=useSyncExternalStore(app.subscribe,app.getPresentationHydration);useLayoutEffect(()=>{if(state.snapshot)app.completePresentationLayout(gate.epoch);},[state.snapshot,gate.epoch]);return <ReviewContext.Provider value={{app,live:state.snapshot??undefined} as ReviewState}><LiveRenderBoundary component={Owner} retainBody={false}/></ReviewContext.Provider>;}
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
  function Route(){const state=useSyncExternalStore(app.subscribe,app.getSnapshot),gate=useSyncExternalStore(app.subscribe,app.getPresentationHydration);useLayoutEffect(()=>{if(state.snapshot)app.completePresentationLayout(gate.epoch);},[state.snapshot,gate.epoch]);return <ReviewContext.Provider value={{app,live:state.snapshot??undefined} as ReviewState}><LiveRenderBoundary component={ShareOwner} retainBody={false}/></ReviewContext.Provider>;}
  try{
    const view=render(<Route/>);expect(merged.unstable_headerLeftItems).toBe(baseClose);
    act(()=>publish(JSON.stringify({...live,revision:2,presentationBlocked:true,backgroundPrivacyCoverRequired:true})));
    expect(merged.unstable_headerLeftItems).toBe(baseClose);expect(merged.unstable_headerRightItems).toBeUndefined();
    await act(async()=>publish(JSON.stringify({...live,revision:3})));
    expect(merged.unstable_headerLeftItems).toBe(baseClose);expect(typeof merged.unstable_headerRightItems).toBe('function');
    baseClose()[0]!.onPress();expect(close).toHaveBeenCalledTimes(1);view.unmount();
  }finally{act(()=>disconnect());lifecycle.mockRestore();AppState.currentState=previousState;mockNavigation.setOptions.mockReset();}
});


test.each([false,true])('short and empty content preserves the inset without inventing catalog scroll space (pinned=%s)',pinned=>{
  const content=(empty:boolean)=><HeaderHeightContext.Provider value={56}><Sheet scrollMode={pinned?'list':'form'} header={pinned?<Text>Search</Text>:undefined}>
    <Text>{empty?'No results':'A long result list'}</Text>
  </Sheet></HeaderHeightContext.Provider>;
  render(content(false));const scroll=screen.UNSAFE_getByType(ScrollView);
  fireEvent(scroll,'layout',{nativeEvent:{layout:{x:0,y:0,width:390,height:700}}});
  screen.rerender(content(true));
  expect(screen.UNSAFE_getByType(ScrollView)).toBe(scroll);
  if(pinned){
    expect(scroll.props.contentInsetAdjustmentBehavior).toBe('automatic');
    expect(scroll.props.contentInset).toBeUndefined();
    expect(scroll.props.contentOffset).toBeUndefined();
    expect(scroll.props.stickyHeaderIndices).toBeUndefined();
  }else expect(scroll.props).toMatchObject({automaticallyAdjustContentInsets:false,contentInsetAdjustmentBehavior:'never',contentInset:{top:56},contentOffset:{x:0,y:-56}});
  expect(StyleSheet.flatten(scroll.props.contentContainerStyle).minHeight).toBe(pinned?undefined:644);
  expect(scroll.props.bounces).toBe(pinned?false:undefined);
  expect(scroll.props.alwaysBounceVertical).toBe(pinned?false:undefined);
});


test('changing a catalog search reveals its new results below the controls without resetting unchanged visits',()=>{
  const content=(search:string,header=56)=><HeaderHeightContext.Provider value={header}>
    <CatalogSheet sections={search?[]:[{title:'All',items:['A result']}]} categoryTitles={['All']} search={search} onSearch={()=>{}}
      searchLabel="Search" renderRow={item=><Text key={item}>{item}</Text>} empty={<Text>No results</Text>}/>
  </HeaderHeightContext.Provider>;
  render(content(''));
  const ref=screen.UNSAFE_getByType(Sheet).props.scrollRef;
  const scrollTo=jest.spyOn(ref.current,'scrollTo').mockImplementation(()=>{});
  scrollTo.mockClear();
  fireEvent.scroll(screen.UNSAFE_getAllByType(ScrollView)[0]!,{nativeEvent:{contentOffset:{x:0,y:300}}});
  screen.rerender(content('no match'));
  expect(scrollTo).toHaveBeenLastCalledWith({y:0,animated:false});
  expect(screen.getByText('No results')).toBeOnTheScreen();
  screen.rerender(content('no match'));
  screen.rerender(content('no match',70));
  expect(scrollTo).toHaveBeenCalledTimes(1);
  screen.rerender(content('',70));
  expect(scrollTo).toHaveBeenLastCalledWith({y:0,animated:false});
});

test('a pinned form header keeps editor sizing instead of adopting catalog scroll bounds',()=>{
  render(<HeaderHeightContext.Provider value={56}><Contents heading="Details" pinned/></HeaderHeightContext.Provider>);
  const scroll=screen.UNSAFE_getByType(ScrollView);
  fireEvent(scroll,'layout',{nativeEvent:{layout:{x:0,y:0,width:390,height:700}}});
  expect(StyleSheet.flatten(scroll.props.contentContainerStyle).minHeight).toBe(644);
  expect(scroll.props.bounces).toBeUndefined();
});

test('catalog controls live outside scrolling results and reserve their measured height through rotation',()=>{
  const content=(header:number)=><HeaderHeightContext.Provider value={header}>
    <CatalogSheet sections={[{title:'All',items:['A result']}]} search="" onSearch={()=>{}}
      searchLabel="Search" renderRow={item=><Text key={item}>{item}</Text>}/>
  </HeaderHeightContext.Provider>;
  const view=render(content(70));const scroll=screen.getByTestId('sheet.results');
  const controls=screen.getByTestId('sheet.pinned-header');const input=screen.getByLabelText('Search');
  expect(StyleSheet.flatten(scroll.props.style).marginTop).toBe(70);
  for(let ancestor=controls.parent;ancestor;ancestor=ancestor.parent)expect(ancestor).not.toBe(scroll);
  expect(StyleSheet.flatten(controls.props.style)).toMatchObject({position:'absolute',top:70});
  fireEvent(controls,'layout',{nativeEvent:{layout:{x:0,y:70,width:390,height:128}}});
  expect(screen.UNSAFE_getAllByType(ScrollView)[0]!.props.scrollIndicatorInsets).toEqual({top:128});
  view.rerender(content(54));
  expect(screen.getByTestId('sheet.results')).toBe(scroll);
  expect(screen.getByLabelText('Search')).toBe(input);
  expect(StyleSheet.flatten(controls.props.style).top).toBe(54);
  expect(StyleSheet.flatten(scroll.props.style).marginTop).toBe(54);
});
