import {fireEvent,render,screen,within} from '@testing-library/react-native';
import {useState} from 'react';
import {KeyboardAvoidingView,Platform,ScrollView,StyleSheet,TextInput,View,type ViewStyle} from 'react-native';
import {SafeAreaInsetsContext} from 'react-native-safe-area-context';
import {LavaAppearanceContext} from '../src/appearance';
import {colors} from '../src/colors';
import {lavaTokens} from '../src/generated/tokens';
import {FormDivider,FlowSheet,FormSteps,LicenseReader} from '../review/form-scaffold';
import {foundation} from '../src/foundation';

jest.mock('@react-navigation/native',()=>({useNavigation:()=>({}),useIsFocused:()=>true}));
jest.mock('react-native-safe-area-context',()=>require('react-native-safe-area-context/jest/mock').default);
jest.mock('../specs/LavaDecorationNativeComponent',()=>({__esModule:true,default:require('react-native').View}));
jest.mock('../specs/LavaTextFieldNativeComponent',()=>({__esModule:true,default:require('react-native').View}));

const platformDescriptor=Object.getOwnPropertyDescriptor(Platform,'OS')!;
afterEach(()=>{Object.defineProperty(Platform,'OS',platformDescriptor);jest.restoreAllMocks();});
const separators=()=>screen.UNSAFE_getAllByType(View).filter(view=>view.props.symbol==='form.separator');
function ancestorStyle(element:ReturnType<typeof screen.getByTestId>,matches:(style:ViewStyle)=>boolean):ViewStyle{
  for(let ancestor=element.parent;ancestor;ancestor=ancestor.parent){
    const style=StyleSheet.flatten(ancestor.props.style) as ViewStyle|undefined;
    if(style&&matches(style))return style;
  }
  throw new Error('Expected a styled form content ancestor.');
}

test.each(['light','dark'] as const)('form steps retain native selection corners and independently dim disabled paint in %s appearance',scheme=>{
  const select=jest.fn();
  const content=(disabled=false)=><LavaAppearanceContext.Provider value={scheme}><FormSteps titles={['Topic','Details','Review']} current={1} furthest={1} onSelect={select} disabled={disabled}/></LavaAppearanceContext.Provider>;
  render(content());
  const steps=screen.getAllByRole('button');
  expect(steps).toHaveLength(3);
  steps.forEach((step,index)=>{
    const style=StyleSheet.flatten(step.props.style);
    expect(style.borderRadius).toBe(lavaTokens.surface.selectionCornerRadius);
    expect(style.opacity).toBe(1);
    expect(style.backgroundColor).toBeUndefined();
    const views=within(step).UNSAFE_getAllByType(View);
    const fill=views.find(view=>view.props.pointerEvents==='none'&&StyleSheet.flatten(view.props.style)?.backgroundColor);
    expect(fill).toBeDefined();
    expect(fill!.props.accessibilityElementsHidden).toBe(true);
    expect(fill!.props.importantForAccessibility).toBe('no-hide-descendants');
    expect(StyleSheet.flatten(fill!.props.style)).toMatchObject({position:'absolute',borderRadius:lavaTokens.surface.selectionCornerRadius,borderCurve:'continuous',backgroundColor:index===1?colors.softGreen:colors.cardBackground,opacity:index===2?0.5:1});
    const label=views.find(view=>view.props.pointerEvents!=='none'&&StyleSheet.flatten(view.props.style)?.opacity===(index===2?0.5:1));
    expect(label).toBeDefined();
  });
  fireEvent.press(screen.getByRole('button',{name:'3. Review'}));
  expect(select).not.toHaveBeenCalled();
  fireEvent.press(screen.getByRole('button',{name:'1. Topic'}));
  expect(select).toHaveBeenCalledWith(0);
  select.mockClear();
  screen.rerender(content(true));
  screen.getAllByRole('button').forEach(step=>{
    expect(step.props.accessibilityState.disabled).toBe(true);
    expect(StyleSheet.flatten(step.props.style).opacity).toBe(1);
    const views=within(step).UNSAFE_getAllByType(View);
    expect(views.filter(view=>StyleSheet.flatten(view.props.style)?.opacity===0.5)).toHaveLength(2);
    fireEvent.press(step);
  });
  expect(select).not.toHaveBeenCalled();
});

test('the native editor can own iOS keyboard avoidance without changing other flow sheets',()=>{
  Object.defineProperty(Platform,'OS',{configurable:true,value:'ios'});
  render(<FlowSheet nativeKeyboardAvoidance><View/></FlowSheet>);
  expect(screen.UNSAFE_getByType(KeyboardAvoidingView).props.behavior).toBeUndefined();
  screen.rerender(<FlowSheet><View/></FlowSheet>);
  expect(screen.UNSAFE_getByType(KeyboardAvoidingView).props.behavior).toBe('padding');
});

test.each([true,false])('flow sheet safely pads its content, header and separate footer while preserving the editor (scrolls=%s)',scrolls=>{
  const dimensions=jest.spyOn(require('react-native'),'useWindowDimensions');dimensions.mockReturnValue({width:874,height:402,scale:3,fontScale:1});
  function Draft(){const [value,setValue]=useState('');return <TextInput testID="safe-form.editor" value={value} onChangeText={setValue}/>;}
  const content=(left:number,right:number)=><SafeAreaInsetsContext.Provider value={{top:0,bottom:21,left,right}}>
    <FlowSheet scrolls={scrolls} centered nativeKeyboardAvoidance header={<View testID="safe-form.header"/>} footer={<View testID="safe-form.footer"/>}><Draft/></FlowSheet>
  </SafeAreaInsetsContext.Provider>;
  render(content(59,44));const editor=screen.getByTestId('safe-form.editor'),footer=screen.getByTestId('safe-form.footer');
  const scroll=scrolls?screen.UNSAFE_getByType(ScrollView):undefined;
  const bodyStyle=()=>scrolls?StyleSheet.flatten(scroll!.props.contentContainerStyle):ancestorStyle(editor,style=>style.paddingTop===16&&style.paddingBottom===24);
  const headerStyle=()=>ancestorStyle(screen.getByTestId('safe-form.header'),style=>style.paddingTop===12&&style.paddingBottom===10);
  const footerStyle=()=>ancestorStyle(footer,style=>style.maxWidth!==undefined&&style.paddingTop===12);
  const safe=(left:number,right:number)=>({paddingLeft:foundation.space.screenHorizontal+left,paddingRight:foundation.space.screenHorizontal+right});
  expect(bodyStyle()).toMatchObject(safe(59,44));
  expect(headerStyle()).toMatchObject(safe(59,44));
  expect(footerStyle()).toMatchObject({...safe(59,44),maxWidth:foundation.layout.readingWidth+59+44,paddingBottom:45});
  if(scrolls){expect(bodyStyle().maxWidth).toBe(foundation.layout.readingWidth+59+44);expect(scroll!.props.contentInsetAdjustmentBehavior).toBe('automatic');expect(scroll!.props.style).toBeUndefined();}
  expect(screen.UNSAFE_getByType(KeyboardAvoidingView).props.behavior).toBeUndefined();
  fireEvent.changeText(editor,'retained flow draft');screen.rerender(content(44,59));expect(bodyStyle()).toMatchObject(safe(44,59));
  dimensions.mockReturnValue({width:402,height:874,scale:3,fontScale:1});screen.rerender(content(0,0));
  expect(screen.getByTestId('safe-form.editor')).toBe(editor);expect(editor.props.value).toBe('retained flow draft');
  expect(screen.getByTestId('safe-form.footer')).toBe(footer);
  expect(bodyStyle().paddingLeft).toBeUndefined();expect(bodyStyle().paddingRight).toBeUndefined();
  expect(bodyStyle().paddingHorizontal).toBe(foundation.space.screenHorizontal);
  expect(footerStyle().maxWidth).toBe(foundation.layout.readingWidth);
  expect(footerStyle().paddingLeft).toBeUndefined();
  expect(headerStyle().paddingLeft).toBeUndefined();
  if(scrolls)expect(screen.UNSAFE_getByType(ScrollView)).toBe(scroll);
});
test('compact flow actions inherit their body safe padding once',()=>{
  const dimensions=jest.spyOn(require('react-native'),'useWindowDimensions');dimensions.mockReturnValue({width:874,height:402,scale:3,fontScale:1});
  const insets={top:0,bottom:21,left:59,right:44};
  render(<SafeAreaInsetsContext.Provider value={insets}><FlowSheet footer={<View testID="compact-safe.footer"/>}><View/></FlowSheet></SafeAreaInsetsContext.Provider>);
  const scroll=screen.UNSAFE_getByType(ScrollView),footer=screen.getByTestId('compact-safe.footer');
  expect(StyleSheet.flatten(scroll.props.contentContainerStyle)).toMatchObject({maxWidth:foundation.layout.readingWidth+59+44,
    paddingLeft:foundation.space.screenHorizontal+59,paddingRight:foundation.space.screenHorizontal+44,paddingBottom:0});
  expect(ancestorStyle(footer,style=>style.paddingBottom===24)).toEqual({paddingBottom:24});
});
test('license scrolling retains its original vertical padding and scroll identity as safe edges change',()=>{
  render(<SafeAreaInsetsContext.Provider value={{top:0,bottom:21,left:59,right:44}}><LicenseReader text="license text"/></SafeAreaInsetsContext.Provider>);
  const reader=screen.UNSAFE_getByType(ScrollView);expect(reader.props.contentInsetAdjustmentBehavior).toBe('automatic');
  expect(StyleSheet.flatten(reader.props.contentContainerStyle)).toEqual({padding:16,paddingLeft:75,paddingRight:60});
  screen.rerender(<SafeAreaInsetsContext.Provider value={{top:59,bottom:34,left:0,right:0}}><LicenseReader text="license text"/></SafeAreaInsetsContext.Provider>);
  expect(screen.UNSAFE_getByType(ScrollView)).toBe(reader);expect(StyleSheet.flatten(reader.props.contentContainerStyle)).toEqual({padding:16});
});

test.each(['light','dark'] as const)('iOS form separators use native semantic paint in app %s appearance without an action or accessibility target',scheme=>{
  Object.defineProperty(Platform,'OS',{configurable:true,value:'ios'});
  render(<LavaAppearanceContext.Provider value={scheme}><FormDivider/></LavaAppearanceContext.Provider>);
  const [line]=separators();
  expect(separators()).toHaveLength(1);
  expect(line!.props.colorScheme).toBe(scheme);
  expect(line!.props.guardianGestures).toBe(false);
  expect(line!.props.pointerEvents).toBe('none');
  expect(line!.props.accessible).toBe(false);
  expect(line!.props.accessibilityElementsHidden).toBe(true);
  expect(line!.props.importantForAccessibility).toBe('no-hide-descendants');
  expect(line!.props.onGuardianGesture).toBeUndefined();
  expect(StyleSheet.flatten(line!.props.style)).toEqual({height:StyleSheet.hairlineWidth,width:'100%'});
  expect(screen.queryAllByRole('button')).toHaveLength(0);
});

test('Android keeps the shared passive semantic separator and the same responsive hairline allocation',()=>{
  Object.defineProperty(Platform,'OS',{configurable:true,value:'android'});
  render(<FormDivider/>);
  expect(separators()).toHaveLength(0);
  const [line]=screen.UNSAFE_getAllByType(View);
  expect(StyleSheet.flatten(line!.props.style)).toEqual({height:StyleSheet.hairlineWidth,width:'100%',backgroundColor:colors.separator});
  expect(line!.props.pointerEvents).toBe('none');
  expect(line!.props.accessible).toBe(false);
  expect(line!.props.importantForAccessibility).toBe('no-hide-descendants');
});

test('feedback footer uses the same separator through width changes and retires it when the footer joins landscape content',()=>{
  Object.defineProperty(Platform,'OS',{configurable:true,value:'ios'});
  const dimensions=jest.spyOn(require('react-native'),'useWindowDimensions');
  dimensions.mockReturnValue({width:393,height:852,scale:3,fontScale:1});
  const content=(feedback:boolean)=><FlowSheet feedback={feedback} footer={<View testID="form.footer"/>}><View testID="form.body"/></FlowSheet>;
  render(content(true));
  expect(separators()).toHaveLength(1);
  expect(StyleSheet.flatten(separators()[0]!.props.style)).toEqual({height:StyleSheet.hairlineWidth,width:'100%'});
  expect(screen.getAllByTestId('form.footer')).toHaveLength(1);
  const portraitFooterStyle=StyleSheet.flatten(screen.getByTestId('form.footer').parent!.props.style);
  dimensions.mockReturnValue({width:768,height:1024,scale:2,fontScale:1});
  screen.rerender(content(true));
  expect(separators()).toHaveLength(1);
  expect(StyleSheet.flatten(separators()[0]!.props.style)).toEqual({height:StyleSheet.hairlineWidth,width:'100%'});
  expect(StyleSheet.flatten(screen.getByTestId('form.footer').parent!.props.style)).toEqual(portraitFooterStyle);
  screen.rerender(content(false));
  expect(separators()).toHaveLength(0);
  dimensions.mockReturnValue({width:852,height:393,scale:3,fontScale:1});
  screen.rerender(content(true));
  expect(separators()).toHaveLength(0);
  expect(screen.getAllByTestId('form.footer')).toHaveLength(1);
});
