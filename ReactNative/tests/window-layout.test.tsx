import {fireEvent,render,screen} from '@testing-library/react-native';
import {useState} from 'react';
import {Animated,KeyboardAvoidingView,StyleSheet,TextInput,View,ScrollView} from 'react-native';
import {SafeAreaInsetsContext} from 'react-native-safe-area-context';
import {PresentationContext,Text} from '../app/presentation';
import {useTextScale} from '../app/text-metrics';
import {windowLayout,scaleWindowStyle,scaleScaffoldStyle,WindowSizeContext,pageContentWidth,pageHeaderInset} from '../src/window-layout';
import {Screen} from '../review/primitives';
import {LavaPlusStory} from '../review/plus-scaffold';
import {SudokuKeypad,sudokuMetrics} from '../review/sudoku-scaffold';
import {newGame} from '../review/sudoku-model';
import {StoryColumns,StoryInset,StoryStack,GuardSummaries,ConnectionScene} from '../review/story-scaffold';
import {Sheet} from '../review/scaffold';
import {FlowSheet} from '../review/form-scaffold';
import {LavaActionButton,LavaIconButton} from '../src/components.ios';
import {DetailField} from '../review/detail-scaffold';
import {foundation} from '../src/foundation';

let mockWindow={width:390,height:844,scale:3,fontScale:1};
const mockNavigation={setOptions:jest.fn(),addListener:()=>()=>{}};
jest.mock('react-native/Libraries/Utilities/useWindowDimensions',()=>({__esModule:true,default:()=>mockWindow}));
jest.mock('@react-navigation/native',()=>({useNavigation:()=>mockNavigation,useIsFocused:()=>true}));
jest.mock('../specs/NativeLavaReview',()=>({__esModule:true,default:{getGuardAccents:()=>JSON.stringify({})}}));
jest.mock('../specs/LavaDecorationNativeComponent',()=>({__esModule:true,default:require('react-native').View}));
jest.mock('../specs/LavaTextFieldNativeComponent',()=>({__esModule:true,default:require('react-native').View}));
beforeEach(()=>{mockWindow={width:390,height:844,scale:3,fontScale:1};mockNavigation.setOptions.mockClear();});

test.each([[390,844,1,false],[844,390,1,true],[1032,1376,1.4,false],[1376,1032,1.4,true],[420,1032,1,false],[680,500,1+20/1200,true]])(
  '%i by %i uses its own shape and short-side sizing', (width,height,scale,landscape)=>{
    const layout=windowLayout({width,height});
    expect(layout.scale).toBeCloseTo(scale as number);expect(layout.landscape).toBe(landscape);
    expect(layout.readingWidth).toBeLessThanOrEqual(880);
  });

test('window geometry scales spacing and targets without scaling ratios, strokes or text twice',()=>{
  const style=scaleWindowStyle({width:'100%',minHeight:44,padding:16,gap:12,borderRadius:20,borderWidth:1,flex:1,opacity:.5,fontSize:17},1.4);
  expect(style).toMatchObject({width:'100%',borderRadius:28,borderWidth:1,flex:1,opacity:.5,fontSize:17});
  expect(style.minHeight).toBeCloseTo(61.6);expect(style.padding).toBeCloseTo(22.4);expect(style.gap).toBeCloseTo(16.8);
});

test('native title follows the page cap and restores system margins in a compact window',()=>{
  mockWindow={...mockWindow,width:1032,height:1376};
  render(<Screen wide><View/></Screen>);
  expect(mockNavigation.setOptions).toHaveBeenLastCalledWith({lavaHeaderContentInset:101.2});
  mockWindow={...mockWindow,width:1376,height:1032};screen.rerender(<Screen wide><View/></Screen>);
  expect(mockNavigation.setOptions).toHaveBeenLastCalledWith({lavaHeaderContentInset:123.2});
  screen.rerender(<Screen wide="compact"><View/></Screen>);
  expect(StyleSheet.flatten(screen.getByTestId('screen.scroll').props.contentContainerStyle).maxWidth).toBe(880);
  expect(mockNavigation.setOptions).toHaveBeenLastCalledWith({lavaHeaderContentInset:273.2});
  screen.rerender(<Screen><View/></Screen>);
  expect(mockNavigation.setOptions).toHaveBeenLastCalledWith({lavaHeaderContentInset:273.2});
  mockWindow={...mockWindow,width:420,height:1032};screen.rerender(<Screen><View/></Screen>);
  expect(mockNavigation.setOptions).toHaveBeenLastCalledWith({lavaHeaderContentInset:-1});
});

test('phone titles retain UIKit margins in either orientation',()=>{
  for(const size of [{width:390,height:844},{width:844,height:390}]){
    const layout=windowLayout(size);
    expect(pageHeaderInset(layout,pageContentWidth(layout))).toBe(-1);
    expect(pageContentWidth(layout,'compact')).toBe(pageContentWidth(layout,true));
  }
  render(<Screen><View/></Screen>);
  expect(mockNavigation.setOptions).not.toHaveBeenCalled();
});

test('shared page clearance stays close to the native title and retains content on resize',()=>{
  mockWindow={...mockWindow,width:1032,height:1376};
  function Draft(){const [value,setValue]=useState('');return <TextInput testID="padded.draft" value={value} onChangeText={setValue}/>;}
  const content=()=><SafeAreaInsetsContext.Provider value={{top:32,bottom:20,left:0,right:0}}>
    <Screen wide><Draft/></Screen>
  </SafeAreaInsetsContext.Provider>;
  render(content());
  const scroll=screen.getByTestId('screen.scroll'),draft=screen.getByTestId('padded.draft');
  const style=()=>StyleSheet.flatten(scroll.props.contentContainerStyle);
  expect(style().paddingTop).toBe(24);expect(style().paddingHorizontal).toBeCloseTo(25.2);
  expect(style().minHeight).toBeUndefined();expect(style().justifyContent).toBeUndefined();
  expect(style().height).toBeUndefined();expect(style().maxHeight).toBeUndefined();
  expect((screen.toJSON() as {type:string}).type).toBe('RCTScrollView');
  fireEvent.changeText(draft,'Keep my draft');
  mockWindow={...mockWindow,width:1376,height:1032};screen.rerender(content());
  expect(style().paddingTop).toBe(24);
  mockWindow={...mockWindow,width:680,height:1032};screen.rerender(content());
  expect(style().paddingTop).toBeCloseTo(16+8*200/480);
  mockWindow={...mockWindow,width:420,height:1032};screen.rerender(content());
  expect(style().paddingTop).toBe(16);expect(style().paddingBottom).toBe(96);
  expect(screen.getByTestId('padded.draft')).toBe(draft);expect(draft.props.value).toBe('Keep my draft');
  mockWindow={...mockWindow,width:1032,height:1376};screen.rerender(content());
  expect(style().paddingTop).toBe(24);
});

test('shared scaffold spacing grows more than type and preserves geometry and paired negative insets',()=>{
  const layout=windowLayout({width:1032,height:1376});
  const style=scaleScaffoldStyle({padding:20,gap:16,minHeight:44,fontSize:17,borderWidth:1,
    paddingVertical:12,marginVertical:-12,left:22,width:'100%'},layout);
  expect(style).toMatchObject({padding:36,gap:28,minHeight:61.599999999999994,fontSize:17,borderWidth:1,width:'100%'});
  expect(style.left).toBeCloseTo(30.8);expect(style.paddingVertical).toBeCloseTo(-style.marginVertical);
  for(const shortSide of [420,480,500,680,834,960,1032,1600]){
    const value=windowLayout({width:shortSide,height:1800});
    expect(value.scale).toBeGreaterThanOrEqual(1);expect(value.scale).toBeLessThanOrEqual(1.4);
    expect(value.insetScale).toBeGreaterThanOrEqual(value.scale);expect(value.insetScale).toBeLessThanOrEqual(1.8);
    expect(value.spacingScale).toBeGreaterThanOrEqual(value.scale);expect(value.spacingScale).toBeLessThanOrEqual(1.75);
    expect(value.topPadding).toBeGreaterThanOrEqual(16);expect(value.topPadding).toBeLessThanOrEqual(24);
    expect(windowLayout({width:1800,height:shortSide})).toMatchObject({scale:value.scale,insetScale:value.insetScale,spacingScale:value.spacingScale});
  }
});

test('story panels and stacks adopt the shared roomy policy in a tablet and shrink in a narrow window',()=>{
  mockWindow={...mockWindow,width:1032,height:1376};
  render(<StoryStack><StoryInset><Text>Protection</Text></StoryInset></StoryStack>);
  const tree=screen.toJSON() as {props:{style:object};children:{props:{style:object}}[]};
  expect(StyleSheet.flatten(tree.props.style)).toMatchObject({gap:28});
  expect(StyleSheet.flatten(tree.children[0]!.props.style)).toMatchObject({padding:36,gap:28});
  mockWindow={...mockWindow,width:420,height:1032};
  screen.rerender(<StoryStack><StoryInset><Text>Protection</Text></StoryInset></StoryStack>);
  const compact=screen.toJSON() as typeof tree;
  expect(StyleSheet.flatten(compact.props.style)).toMatchObject({gap:16});
  expect(StyleSheet.flatten(compact.children[0]!.props.style)).toMatchObject({padding:20,gap:16});
});

test.each([[1194,834],[1376,1032]])('landscape Plus benefits stay paired in a %i by %i window',(width,height)=>{
  mockWindow={...mockWindow,width,height};
  render(<LavaPlusStory/>);
  fireEvent(screen.getByTestId('carousel.surface'),'layout',{nativeEvent:{layout:{width:830,height:500}}});
  expect(screen.getByTestId('plus.scene.routines')).toHaveStyle({flexDirection:'row'});
});

test('tablet keypad columns occupy their reserved chrome width and keep measured key heights',()=>{
  mockWindow={...mockWindow,width:1376,height:1032};
  render(<SudokuKeypad game={newGame()} width={500} height={500} layout="column" notesMode={false} assist={false}
    canEnter canErase={false} onEnter={()=>{}} onErase={()=>{}} panHandlers={{}}/>);
  const group=screen.getByTestId('sudoku-digit-group');
  expect(StyleSheet.flatten(group.parent?.parent?.props.style).width).toBeCloseTo(sudokuMetrics.keypadHeight*1.4);
  expect(screen.getByTestId('sudoku-digit-1')).toHaveStyle({width:sudokuMetrics.keyHeight*1.4,height:500/9});
  expect(screen.getByTestId('sudoku-keypad-touch',{includeHiddenElements:true})).toHaveStyle({width:sudokuMetrics.keyHeight*1.4});
});

function Scales(){return <View testID="metrics" accessibilityValue={{text:String(useTextScale())}}/>;}
test('authored connection offsets stay aligned with their enlarged nodes',()=>{
  const scaled=scaleWindowStyle({width:44,height:44,left:22,top:52,bottom:0},1.4);
  expect(scaled.left).toBeCloseTo(scaled.width/2);
  expect(scaled.top-scaled.height).toBeCloseTo(8*1.4);
  expect(scaled.bottom).toBe(0);
});

test('authored translations stay proportional while animation values and transforms retain their owners',()=>{
  const measured=new Animated.Value(12);
  const style=scaleWindowStyle({width:140,transform:[{translateX:-48},{translateY:12},{scale:0.5},{rotate:'30deg'},{translateX:measured}]},1.4);
  expect(style.transform[0]!.translateX as number/style.width).toBeCloseTo(-48/140);
  expect(style.transform[1]).toEqual({translateY:16.799999999999997});
  expect(style.transform[2]).toEqual({scale:0.5});
  expect(style.transform[3]).toEqual({rotate:'30deg'});
  expect(style.transform[4]!.translateX).toBe(measured);
});

test('tablet base type composes with user text preference once, including control metrics',()=>{
  mockWindow={...mockWindow,width:1032,height:1376};
  render(<PresentationContext.Provider value={{locale:'en',textScales:{body:1.5}}}><Text testID="copy" style={{fontSize:17,lineHeight:22}}>Protection Off</Text><Scales/></PresentationContext.Provider>);
  expect(screen.getByTestId('copy')).toHaveStyle({fontSize:35.699999999999996,lineHeight:46.199999999999996});
  expect(Number(screen.getByTestId('metrics').props.accessibilityValue.text)).toBeCloseTo(2.1);
});

test('tablet portrait and narrow windows retain the phone stack and mounted drafts through rotation',()=>{
  function Draft(){const [value,setValue]=useState('');return <TextInput testID="draft" value={value} onChangeText={setValue}/>;}
  const content=()=><StoryColumns primary={<Draft/>} secondary={<View/>}/>;
  mockWindow={...mockWindow,width:1032,height:1376};render(content());
  const draft=screen.getByTestId('draft');fireEvent.changeText(draft,'Keep my draft');
  const direction=()=>StyleSheet.flatten(screen.getByTestId('story.columns').props.style).flexDirection;
  expect(direction()).toBe('column');
  mockWindow={...mockWindow,width:1376,height:1032};screen.rerender(content());expect(direction()).toBe('row');
  mockWindow={...mockWindow,width:420,height:1032};screen.rerender(content());expect(direction()).toBe('column');
  expect(screen.getByTestId('draft')).toBe(draft);expect(draft.props.value).toBe('Keep my draft');
});

test('larger tablet base sizing preserves the summary pair and horizontal Explore path',()=>{
  mockWindow={...mockWindow,width:1032,height:1376};
  render(<><GuardSummaries today={{value:'25% blocked'}} filter={{name:'Work'}} onActivity={()=>{}} onFilters={()=>{}}/>
    <ConnectionScene stages={[]} onSelect={()=>{}}/></>);
  expect(StyleSheet.flatten(screen.getByTestId('guard.summaries').props.style).flexDirection).toBe('row');
  expect(screen.getByTestId('connection.path.horizontal')).toBeOnTheScreen();
});

test('native sheet content and detached footer size from the sheet viewport',()=>{
  mockWindow={...mockWindow,width:1376,height:1032};
  render(<Sheet footer={<Text testID="footer" style={{fontSize:17}}>Save</Text>}><Text testID="field" style={{fontSize:17}}>Work</Text></Sheet>);
  fireEvent(screen.UNSAFE_getByType(ScrollView),'layout',{nativeEvent:{layout:{x:0,y:0,width:420,height:800}}});
  expect(screen.getByTestId('field')).toHaveStyle({fontSize:17});
  const footer=mockNavigation.setOptions.mock.calls.at(-1)![0].unstable_sheetFooter();
  const detached=render(footer);expect(detached.getByTestId('footer')).toHaveStyle({fontSize:17});
});

test('native-hosted forms follow their measured shape and retain the editor through resize',()=>{
  mockWindow={...mockWindow,width:1376,height:1032};
  function Draft(){const [value,setValue]=useState('');return <TextInput testID="form.draft" value={value} onChangeText={setValue}/>;}
  const content=()=><FlowSheet footer={<Text testID="form.footer" style={{fontSize:17}}>Save</Text>}><Draft/></FlowSheet>;
  render(content());
  const draft=screen.getByTestId('form.draft');fireEvent.changeText(draft,'Keep my draft');
  const measure=(width:number,height:number)=>fireEvent(screen.UNSAFE_getByType(KeyboardAvoidingView),'layout',{nativeEvent:{layout:{x:0,y:0,width,height}}});
  measure(420,800);
  expect(screen.getByTestId('form.footer')).toHaveStyle({fontSize:17});
  expect(screen.UNSAFE_getByType(ScrollView).findAllByProps({testID:'form.footer'})).toHaveLength(0);
  measure(800,420);
  expect(screen.UNSAFE_getByType(ScrollView).findAllByProps({testID:'form.footer'}).length).toBeGreaterThan(0);
  expect(screen.getByTestId('form.draft')).toBe(draft);
  expect(draft.props.value).toBe('Keep my draft');
  measure(0,0);
  expect(screen.getByTestId('form.footer')).toHaveStyle({fontSize:17});
});

test('rounded icon controls preserve their corner proportion at tablet sizing',()=>{
  mockWindow={...mockWindow,width:1032,height:1376};
  render(<LavaIconButton title="Close" icon="close" shape="rounded" onPress={()=>{}} testID="rounded.control"/>);
  expect(screen.getByTestId('rounded.control')).toHaveStyle({width:61.599999999999994,height:61.599999999999994,borderRadius:22.4});
});

test.each(['actionLabel','rowTitle'] as const)('action glyphs retain their slot proportion for %s on phone and tablet',labelRole=>{
  const content=()=><LavaActionButton title="Add" icon="add" labelRole={labelRole} onPress={()=>{}}/>;
  render(content());
  const glyph=()=>screen.UNSAFE_getAllByProps({symbol:'plus'})[0]!;
  const pointSize=labelRole==='rowTitle'?13:foundation.control.glyph;
  const slot=labelRole==='rowTitle'?16:foundation.control.glyphSlot;
  expect(glyph().props.fontPointSize).toBe(pointSize);
  expect(StyleSheet.flatten(glyph().props.style).width).toBe(slot);
  mockWindow={...mockWindow,width:1032,height:1376};screen.rerender(content());
  expect(glyph().props.fontPointSize).toBeCloseTo(pointSize*1.4);
  expect(StyleSheet.flatten(glyph().props.style).width).toBeCloseTo(slot*1.4);
});

test('detail input floors grow with their form and retain the phone baseline',()=>{
  const content=()=><><DetailField title="Name"/><DetailField title="Details" multiline/></>;
  render(content());
  expect(screen.getByLabelText('Name')).toHaveStyle({minHeight:44});
  expect(screen.getByLabelText('Details')).toHaveStyle({minHeight:132});
  mockWindow={...mockWindow,width:1032,height:1376};screen.rerender(content());
  expect(StyleSheet.flatten(screen.getByLabelText('Name').props.style).minHeight).toBeCloseTo(61.6);
  expect(StyleSheet.flatten(screen.getByLabelText('Details').props.style).minHeight).toBeCloseTo(184.8);
});

test('fixed export or measured game text can retain its independent pixel geometry',()=>{
  render(<WindowSizeContext.Provider value={{width:1032,height:1376}}><Text responsive={false} allowFontScaling={false} testID="fixed" style={{fontSize:25}}>5</Text></WindowSizeContext.Provider>);
  expect(screen.getByTestId('fixed')).toHaveStyle({fontSize:25});
});
