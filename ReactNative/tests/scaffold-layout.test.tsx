import {act, fireEvent, render, screen} from '@testing-library/react-native';
import {ScrollView,StyleSheet,Text, TextInput, View,type ViewStyle} from 'react-native';
import {useState} from 'react';
import {PresentationContext} from '../app/presentation';
import {AccessorySlot,AdaptivePair,Control, DomainInput, Group, ListRow, StableVariants,Toggle} from '../review/scaffold';
import {DisclosureRow,Row,RowAccessory,RowContent,Screen} from '../review/primitives';
import {StoryColumns,StoryLink} from '../review/story-scaffold';
import {SettingsControl,SettingsDisclosure,SettingsGuardPreview,SettingsIntro,SettingsSurface} from '../review/settings-scaffold';
import {LavaControlContent,LavaRowLabel,LavaToggleRow} from '../src';
import {foundation} from '../src/foundation';

jest.mock('react-native-safe-area-context',()=>({SafeAreaProvider:require('react-native').View,SafeAreaView:require('react-native').View}));
jest.mock('@react-navigation/native',()=>({useNavigation:()=>({}),useIsFocused:()=>true}));
jest.mock('../specs/LavaTextFieldNativeComponent',()=>({__esModule:true,default:require('react-native').View}));
jest.mock('../specs/LavaDecorationNativeComponent',()=>({__esModule:true,default:require('react-native').View}));

test('responsive columns share one page scroll and preserve drafts across rotation',()=>{
  const dimensions=jest.spyOn(require('react-native'),'useWindowDimensions');
  dimensions.mockReturnValue({width:852,height:393,scale:3,fontScale:1});
  function Draft(){const [value,setValue]=useState('');return <TextInput testID="column.draft" value={value} onChangeText={setValue}/>;}
  const content=()=><Screen wide><StoryColumns primary={<Draft/>} secondary={<Text>Second column</Text>}/></Screen>;
  render(content());
  expect(screen.UNSAFE_getAllByType(ScrollView)).toHaveLength(1);
  expect(screen.getByTestId('screen.scroll').props.contentInsetAdjustmentBehavior).toBe('automatic');
  expect(StyleSheet.flatten(screen.getByTestId('screen.scroll').props.contentContainerStyle).height).toBeUndefined();
  fireEvent.changeText(screen.getByTestId('column.draft'),'Keep this draft');
  dimensions.mockReturnValue({width:393,height:852,scale:3,fontScale:1});
  screen.rerender(content());
  expect(screen.UNSAFE_getAllByType(ScrollView)).toHaveLength(1);
  // The real-Yoga regression checks the first native resize frame without a
  // JS rerender. This journey checks that the same input keeps its draft.
  expect(screen.getByTestId('column.draft').props.value).toBe('Keep this draft');
  dimensions.mockRestore();
});

test('task rows remain identifiable and tappable without promising a forward page',()=>{
  const open=jest.fn();
  const content=(intent:'page'|'task'|'external')=><Row intent={intent} icon="doc.text" title="Configuration saved" summary="Last updated on Sep 12, 2026" onPress={open}/>;
  render(content('task'));
  const symbols=()=>screen.UNSAFE_getAllByType(View).map(view=>view.props.symbol).filter(Boolean);
  expect(symbols()).toEqual(['doc.text']);
  fireEvent.press(screen.getByRole('button',{name:'Configuration saved, Last updated on Sep 12, 2026'}));
  expect(open).toHaveBeenCalledTimes(1);
  screen.rerender(content('page'));
  expect(symbols()).toEqual(['doc.text','chevron.right']);
  screen.rerender(content('external'));
  expect(symbols()).toEqual(['doc.text','arrow.up.right']);
});

test('navigation inside a story reuses utility-row anatomy without a phantom leading glyph or nested action',()=>{
  const utility=jest.fn(),story=jest.fn();
  const content=(scale:number)=><PresentationContext.Provider value={{locale:'en',textScales:{headline:scale}}}>
    <Row title="Account & Backup" icon="person.crop.circle" intent="page" onPress={utility}/>
    <StoryLink title="Explore this connection" onPress={story}/>
  </PresentationContext.Provider>;
  render(content(1));
  const rows=()=>screen.UNSAFE_getAllByType(RowContent);
  const anatomy=()=>rows().map(row=>row.findAllByType(View)[0]!);
  expect(rows()).toHaveLength(2);
  expect(anatomy()[0]!.props.style).toEqual(anatomy()[1]!.props.style);
  expect(StyleSheet.flatten(anatomy()[0]!.props.style)).toMatchObject({paddingHorizontal:foundation.row.horizontalInset,paddingVertical:foundation.row.verticalInset,minHeight:foundation.row.standard});
  expect(rows()[0]!.findAllByProps({symbol:'person.crop.circle'}).length).toBeGreaterThan(0);
  expect(rows()[1]!.findAllByType(View).filter((view:ReturnType<typeof screen.getByTestId>)=>StyleSheet.flatten(view.props.style)?.width===foundation.control.glyphSlot)).toHaveLength(0);
  expect(screen.getByTestId('row.Account & Backup.accessory').props.style).toEqual(screen.getByTestId('row.Explore this connection.accessory').props.style);
  expect(screen.getByTestId('row.Explore this connection.accessory')).toHaveStyle({width:foundation.row.disclosureWidth});
  expect(screen.getAllByRole('button')).toHaveLength(2);
  fireEvent.press(screen.getByRole('button',{name:'Explore this connection'}));
  expect(story).toHaveBeenCalledTimes(1);expect(utility).not.toHaveBeenCalled();
  screen.rerender(content(2));
  expect(screen.getByText('Account & backup').props.style).toEqual(screen.getByText('Explore this connection').props.style);
  expect(screen.getByText('Explore this connection').props.numberOfLines).toBeUndefined();
});

test('noninteractive row content keeps status slots on the same axes without exposing a destination',()=>{
  render(<RowContent title="Not signed in" summary="name@example.com" verbatimSummary intent="task" leading={<View testID="status.busy"/>} trailing={<Text testID="status.pending">Pending</Text>}/>);
  const content=screen.UNSAFE_getByType(RowContent);
  const views:ReturnType<typeof screen.getByTestId>[]=content.findAllByType(View);
  const leading=views.find(view=>StyleSheet.flatten(view.props.style)?.width===foundation.control.glyphSlot)!;
  expect(leading.findAllByProps({testID:'status.busy'}).length).toBeGreaterThan(0);
  expect(screen.getByTestId('row.Not signed in.accessory')).toHaveStyle({width:foundation.row.disclosureWidth});
  expect(screen.getByText('name@example.com')).toBeOnTheScreen();
  expect(screen.queryAllByRole('button')).toHaveLength(0);
  expect(views.filter(view=>view.props.symbol==='chevron.right')).toHaveLength(0);
});

test('plain and grouped disclosures share row content, right-to-down state and a single controlled target',()=>{
  const change=jest.fn();
  const examples=(expanded:boolean)=><>
    <DisclosureRow title="Example notice" expanded={expanded} onChange={change}/>
    <SettingsDisclosure title="Delete local logs" icon="trash" expanded={expanded} onChange={change}><Text>Actions stay here</Text></SettingsDisclosure>
  </>;
  render(examples(false));
  const rows=screen.UNSAFE_getAllByType(RowContent);
  expect(rows).toHaveLength(2);
  expect(rows[0]!.findAllByType(View)[0]!.props.style).toEqual(rows[1]!.findAllByType(View)[0]!.props.style);
  const buttons=screen.getAllByRole('button');
  expect(buttons).toHaveLength(2);
  for(const button of buttons){
    expect(button).toHaveProp('accessibilityState',{expanded:false});
    expect(button.findAllByProps({symbol:'chevron.right'}).length).toBeGreaterThan(0);
  }
  expect(screen.queryByText('Actions stay here')).toBeNull();
  fireEvent.press(screen.getByRole('button',{name:'Example notice'}));
  expect(change).toHaveBeenLastCalledWith(true);
  // The parent remains the state authority; a tap alone does not flip the glyph.
  expect(screen.getByRole('button',{name:'Example notice'})).toHaveProp('accessibilityState',{expanded:false});
  screen.rerender(examples(true));
  expect(screen.getByText('Actions stay here')).toBeOnTheScreen();
  screen.getAllByRole('button').forEach((button,index)=>{
    expect(button).toBe(buttons[index]);
    expect(button).toHaveProp('accessibilityState',{expanded:true});
    expect(button.findAllByProps({symbol:'chevron.down'}).length).toBeGreaterThan(0);
  });
  fireEvent.press(screen.getByRole('button',{name:'Delete local logs'}));
  expect(change).toHaveBeenLastCalledWith(false);
});

test('settings, grouped controls and live toggles share the actual labeled control owner with surfaces outside it',()=>{
  render(<>
    <Control title="Grouped control"><View testID="grouped.control"/></Control>
    <SettingsControl title="Settings control"><View testID="settings.control"/></SettingsControl>
    <Toggle title="Live switch" value={false} onChange={()=>{}}/>
    <LavaToggleRow title="Gallery switch" value={false} onValueChange={()=>{}}/>
  </>);
  const controls=screen.UNSAFE_getAllByType(LavaControlContent);
  expect(controls).toHaveLength(4);
  controls.forEach(control=>{
    expect(control.findAllByType(View)[0]!.props.style).toEqual(controls[0]!.findAllByType(View)[0]!.props.style);
    expect(StyleSheet.flatten(control.findAllByType(View)[0]!.props.style).backgroundColor).toBeUndefined();
    expect(control.findAllByType(LavaRowLabel)).toHaveLength(1);
  });
  expect(screen.UNSAFE_getAllByType(LavaToggleRow).map(toggle=>toggle.props.optimistic)).toEqual([true,undefined]);
  expect(screen.getByText('Grouped control').props.style).toEqual(screen.getByText('Settings control').props.style);
  expect(screen.getByText('Live switch').props.style).toEqual(screen.getByText('Gallery switch').props.style);
});

test('conditional group rows do not remount an existing editor or discard its draft',()=>{
  function Editor(){const [value,setValue]=useState('');return <TextInput testID="retained-editor" value={value} onChangeText={setValue}/>;}
  const content=(extra:boolean)=><Group>{extra&&<Text key="condition">Conditional setting</Text>}<Editor key="editor"/></Group>;
  render(content(false));
  fireEvent.changeText(screen.getByTestId('retained-editor'),'draft stays here');
  screen.rerender(content(true));
  expect(screen.getByTestId('retained-editor').props.value).toBe('draft stays here');
  screen.rerender(content(false));
  expect(screen.getByTestId('retained-editor').props.value).toBe('draft stays here');
});

test('the domain editor follows the app text override and adopts the native measured line height',()=>{
  const changed=jest.fn();const submitted=jest.fn();
  const content=(scale:number)=><PresentationContext.Provider value={{locale:'en',textScales:{body:scale}}}><DomainInput label="Domain" placeholder="example.com" onChange={changed} onSubmit={submitted}/></PresentationContext.Provider>;
  render(content(2));
  const field=()=>screen.UNSAFE_getAllByType(View).find(view=>view.props.inputLabel==='Domain')!;
  expect(field().props.fontPointSize).toBe(34);
  act(()=>field().props.onSizeChange({nativeEvent:{height:43}}));
  expect(field().props.style).toMatchObject({height:43});
  act(()=>field().props.onChange({nativeEvent:{text:'example.com'}}));
  act(()=>field().props.onSubmit({nativeEvent:{text:'example.com'}}));
  expect(changed).toHaveBeenCalledWith('example.com');
  expect(submitted).toHaveBeenCalledWith('example.com');
  screen.rerender(content(3));
  expect(field().props.fontPointSize).toBe(51);
  expect(field().props.style).toMatchObject({height:66});
  act(()=>field().props.onSizeChange({nativeEvent:{height:62}}));
  expect(field().props.style).toMatchObject({height:62});
});

test('label-value rows keep both labels readable when text scale or available width increases pressure',()=>{
  const content=(scale:number)=><PresentationContext.Provider value={{locale:'en',textScales:{body:scale}}}><AdaptivePair label={<Text>Primary DNS</Text>}><Text>A long resolver value</Text></AdaptivePair></PresentationContext.Provider>;
  render(content(1));
  const row=()=>screen.UNSAFE_getAllByType(View).find(view=>view.props.onLayout)!;
  fireEvent(row(),'layout',{nativeEvent:{layout:{width:360}}});
  expect(row().props.style).toMatchObject({flexDirection:'row'});
  screen.rerender(content(3));
  expect(row().props.style).toMatchObject({flexDirection:'column'});
  expect(screen.getByText('Primary DNS')).toBeOnTheScreen();
  expect(screen.getByText('A long resolver value')).toBeOnTheScreen();
  screen.rerender(content(1));
  fireEvent(row(),'layout',{nativeEvent:{layout:{width:250}}});
  expect(row().props.style).toMatchObject({flexDirection:'column'});
});

test('a stable variant slot exposes only the selected content to accessibility',()=>{
  const variants=[{key:'short',content:<Text>Short preview</Text>},{key:'long',content:<Text>A longer preview for another Guard</Text>}];
  render(<StableVariants selectedKey="short" variants={variants}/>);
  expect(screen.getByText('Short preview')).toBeOnTheScreen();
  expect(screen.queryByText('A longer preview for another Guard')).toBeNull();
  screen.rerender(<StableVariants selectedKey="long" variants={variants}/>);
  expect(screen.queryByText('Short preview')).toBeNull();
  expect(screen.getByText('A longer preview for another Guard')).toBeOnTheScreen();
});


test('the Guard appearance tile consumes the canonical navigation accessory within one persistent destination target',()=>{
  const open=jest.fn();
  const preview=(description:string)=><SettingsGuardPreview look="original" title="Original" subtitle={description} onPress={open}/>;
  render(preview('Your Lava'));
  const target=screen.getByTestId('Choose Lava Guard');
  const accessory=screen.UNSAFE_getByType(RowAccessory);
  expect(accessory.props.intent).toBe('page');
  expect(screen.getByTestId('customization.guard.accessory')).toHaveStyle({width:foundation.row.disclosureWidth});
  const wrappers:ViewStyle[]=screen.UNSAFE_getByType(ListRow).findAllByType(View)
    .flatMap((view:ReturnType<typeof screen.getByTestId>)=>{
      const style=StyleSheet.flatten(view.props.style) as ViewStyle|undefined;
      return style?.minWidth!==undefined?[style]:[];
    });
  expect(wrappers.some(style=>style.minWidth===foundation.row.disclosureWidth)).toBe(true);
  expect(wrappers.some(style=>style.minWidth===foundation.control.accessory)).toBe(false);
  expect(screen.getAllByRole('button')).toHaveLength(1);
  fireEvent.press(target);expect(open).toHaveBeenCalledTimes(1);
  screen.rerender(preview('A longer description that can wrap without introducing a separate action.'));
  expect(screen.getByTestId('Choose Lava Guard')).toBe(target);
  expect(screen.UNSAFE_getByType(RowAccessory)).toBe(accessory);
});

test('transparent groups retain between-row dividers and row identity independently of surface paint',()=>{
  const content=(plain:boolean,separators=true)=><Group plain={plain} separators={separators}>
    <TextInput key="draft" testID="catalog.draft" defaultValue="Unchanged"/>
    <Text key="second">Second row</Text><Text key="third">Third row</Text>
  </Group>;
  const dividers=()=>screen.UNSAFE_getAllByType(View).filter(view=>
    StyleSheet.flatten(view.props.style)?.height===StyleSheet.hairlineWidth);
  render(content(true));
  const draft=screen.getByTestId('catalog.draft');
  expect(dividers()).toHaveLength(2);
  for(const divider of dividers())expect(StyleSheet.flatten(divider.props.style)).toEqual(expect.objectContaining({marginLeft:foundation.row.horizontalInset}));
  screen.rerender(content(false));
  expect(screen.getByTestId('catalog.draft')).toBe(draft);
  expect(dividers()).toHaveLength(2);
  screen.rerender(content(true,false));
  expect(screen.getByTestId('catalog.draft')).toBe(draft);
  expect(dividers()).toHaveLength(0);
});

test('switchable accessory lanes retain native width through edit and empty states',()=>{
  const content=(editing:boolean)=><AccessorySlot switchable>{editing?null:<View testID="switch"/>}</AccessorySlot>;
  render(content(true));
  const slot=()=>screen.UNSAFE_getByType(AccessorySlot).findAllByType(View)[0]!;
  const width=()=>StyleSheet.flatten(slot().props.style).minWidth;
  expect(width()).toBe(foundation.nativeSwitch.width);
  screen.rerender(content(false));
  fireEvent(slot(),'layout',{nativeEvent:{layout:{width:80,height:44,x:0,y:0}}});
  expect(width()).toBe(80);
  screen.rerender(content(true));
  expect(width()).toBe(80);
  fireEvent(slot(),'layout',{nativeEvent:{layout:{width:44,height:44,x:0,y:0}}});
  expect(width()).toBe(80);
});

test('independent trailing controls retain their target slot even if disclosure was requested',()=>{
  render(<ListRow title="Custom list" separateTrailing trailingRole="disclosure" onPress={()=>{}}
    trailing={<View testID="delete.slot"/>}/>);
  const widths=screen.UNSAFE_getByType(ListRow).findAllByType(View)
    .map((view:ReturnType<typeof screen.getByTestId>)=>(StyleSheet.flatten(view.props.style) as ViewStyle|undefined)?.minWidth);
  expect(widths).toContain(foundation.control.accessory);
});

jest.mock('../specs/NativeLavaReview',()=>({__esModule:true,default:{getGuardAccents:()=>JSON.stringify({original:{light:'#BF4000',dark:'#FF8855'}})}}));

test('settings introductions use row-sized regular paragraphs and helpers remain outside row surfaces',()=>{
  const helper='Uses the DNS resolver from the current Wi-Fi or cellular network while Lava still filters locally.';
  // The catalog key renders its English value.
  const shown='Uses the DNS provider from your current Wi-Fi or cellular network while Lava still filters on this device.';
  const change=jest.fn();
  const content=(value:boolean)=><>
    <SettingsIntro summary="Choose who looks up website addresses for your device."/>
    <SettingsSurface testID="settings.control.surface" footer={helper}>
      <Toggle title="Use Device DNS Setting" value={value} accessibilityHint={helper} onChange={change}/>
    </SettingsSurface>
  </>;
  render(content(false));
  expect(screen.getByText('Choose who looks up website addresses for your device.')).toHaveStyle({fontSize:foundation.type.supporting.fontSize,fontWeight:foundation.type.supporting.fontWeight});
  const surface=screen.getByTestId('settings.control.surface');
  expect(surface.findAllByProps({children:shown})).toHaveLength(0);
  expect(screen.getByText(shown)).toBeOnTheScreen();
  expect(screen.getByRole('switch')).toHaveProp('accessibilityHint',shown);
  fireEvent(screen.getByRole('switch'),'valueChange',true);
  expect(change).toHaveBeenCalledWith(true);
  screen.rerender(content(true));
  expect(screen.getByText(shown)).toBeOnTheScreen();
  expect(screen.getByRole('switch')).toHaveProp('value',true);
});

test('the page scroll view is the screen root, so UIKit keeps driving the large title',()=>{
  // UIKit reads `headerLargeTitle` from the scroll view it finds as the screen's
  // DIRECT child. Wrapping it — a safe-area provider per page, a layout view —
  // leaves the navigation item without a scroll view to track, and the large
  // title fails to lay out and is missing through a push (PR #724 follow-up).
  // `Sheet` keeps the same rule for form-sheet sizing; this pins it for pages.
  render(<Screen><Text>Body</Text></Screen>);
  const root=screen.toJSON();
  expect(Array.isArray(root)).toBe(false);
  expect((root as {type:string}|null)?.type).toBe('RCTScrollView');
  expect((root as {props:{testID?:string}}).props.testID).toBe('screen.scroll');
});
