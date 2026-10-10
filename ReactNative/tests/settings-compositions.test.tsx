import {useState,type PropsWithChildren} from 'react';
import {Linking,ScrollView} from 'react-native';
import {fireEvent,render,screen} from '@testing-library/react-native';
import {SettingsGuardPreview,SettingsGuardRow,SettingsGuardSpotlight} from '../review/settings-scaffold';
import {SettingsScreen,CustomizationScreen,GuardianScreen} from '../review/SettingsScreens';
import {AddAction,ListRow,Sheet,Toggle} from '../review/scaffold';
import {Row,Section} from '../review/primitives';
import {FilterScreen} from '../review/FilterScreens';
import {ReviewContext} from '../review/ReviewContext';
import {initialSession} from '../review/session';
import {initialPreviewDraft} from '../review/preview-model';
import {AppearanceStore} from '../review/appearance-store';
import type {AppSnapshot} from '../app/contract';
const mockNavigate=jest.fn();
const mockSetOptions=jest.fn();
jest.mock('@react-navigation/native',()=>({usePreventRemove:jest.fn(),useNavigation:()=>({addListener:jest.fn(()=>()=>{}),navigate:mockNavigate,setOptions:mockSetOptions}),useIsFocused:()=>true,useRoute:()=>({params:{}}),useScrollToTop:jest.fn()}));
jest.mock('react-native-safe-area-context',()=>({SafeAreaProvider:require('react-native').View,SafeAreaView:require('react-native').View,SafeAreaInsetsContext:require('react').createContext(null),useSafeAreaInsets:()=>({top:59,bottom:34,left:0,right:0})}));
jest.mock('../specs/LavaDecorationNativeComponent',()=>({__esModule:true,default:require('react-native').View}));
jest.mock('../specs/LavaTextFieldNativeComponent',()=>({__esModule:true,default:require('react-native').View}));
jest.mock('../specs/LavaSliderNativeComponent',()=>({__esModule:true,default:require('react-native').View}));
jest.mock('../specs/LavaChoiceNativeComponent',()=>require('./native-choice-mock'));
jest.mock('../specs/NativeLavaReview',()=>({__esModule:true,default:{getGuardAccents:()=>JSON.stringify({original:{light:'#BF4000',dark:'#FF8855'}})}}));
function Provider({children,live,editing=false}:PropsWithChildren<{live?:AppSnapshot;editing?:boolean}>){
  const [session,setSession]=useState(()=>({...initialSession(),editing})),[draft,setDraft]=useState(initialPreviewDraft);
  const [appearance]=useState(()=>new AppearanceStore({getSnapshot:async()=>({preference:'system',revision:0}),setPreference:async preference=>({preference,revision:1}),onSnapshot:()=>({remove(){}})}));
  return <ReviewContext.Provider value={{session,setSession,draft,setDraft,savedDraft:draft,setSavedDraft:setDraft,appearance,live,look:'original',setLook(){}}}>{children}</ReviewContext.Provider>;
}
beforeEach(()=>jest.clearAllMocks());
test('Customization and the catalog use the actual same Guard row while preserving navigation versus selection',()=>{
  const open=jest.fn(),select=jest.fn();
  render(<><SettingsGuardPreview look="original" title="Original" subtitle="Ready to protect" onPress={open}/>
    <SettingsGuardRow look="original" title="Original" subtitle="Ready to protect" selected onPress={select} testID="catalog"/>
    <SettingsGuardRow look="original" title="Locked Guard" selected={false} locked onPress={select}/></>);
  const owners=screen.UNSAFE_getAllByType(ListRow);
  for(const owner of owners.slice(0,2))expect(owner.props).toMatchObject({title:'Original',subtitle:'Ready to protect',action:true});
  const preview=screen.getByTestId('Choose Lava Guard'),choice=screen.getByTestId('catalog');
  expect(preview.props.style).toEqual(choice.props.style);
  expect(preview).toHaveProp('accessibilityLabel','Original, Ready to protect');
  expect(preview.props.accessibilityState.selected).toBeUndefined();
  expect(choice).toHaveProp('accessibilityState',expect.objectContaining({selected:true}));
  fireEvent.press(preview);expect(open).toHaveBeenCalledTimes(1);expect(select).not.toHaveBeenCalled();
  fireEvent.press(choice);expect(select).toHaveBeenCalledTimes(1);
  expect(screen.getByRole('button',{name:'Locked Guard'})).toBeEnabled();fireEvent.press(screen.getByRole('button',{name:'Locked Guard'}));expect(select).toHaveBeenCalledTimes(2);
});
test('Spotlight contains only the active Guard copy so inactive long descriptions cannot reserve height',()=>{
  const variants=[{id:'original',title:'Original',description:'Short description.',tip:'Short tip.'},
    {id:'kiwi',title:'Kiwi',description:'A much longer description that belongs to another Guard.',tip:'Another long tip.'}];
  const view=render(<SettingsGuardSpotlight look="original" variants={variants}/>);
  expect(screen.getByText('Short description.')).toBeOnTheScreen();
  expect(screen.queryByText(variants[1]!.description,{includeHiddenElements:true})).toBeNull();
  view.rerender(<SettingsGuardSpotlight look="kiwi" variants={variants}/>);
  expect(screen.getByText(variants[1]!.description)).toBeOnTheScreen();
  expect(screen.queryByText('Short description.',{includeHiddenElements:true})).toBeNull();
});
test('Language delegates its external action and accessory to the standard settings row',()=>{
  const open=jest.spyOn(Linking,'openSettings').mockResolvedValue();
  render(<Provider><CustomizationScreen/></Provider>);
  const row=screen.UNSAFE_getAllByType(Row).find(value=>value.props.title==='Change in system settings')!;
  expect(row.props).toMatchObject({intent:'external'});expect(row.props.icon).toBeUndefined();expect(row.props.trailing).toBeUndefined();
  fireEvent.press(screen.getByRole('button',{name:'Change in the Settings app'}));expect(open).toHaveBeenCalledTimes(1);open.mockRestore();
});
test('Plus row follows entitlement changes without using account sign-in or adding a subtitle',()=>{
  const value=(enabled:boolean,signedIn:boolean)=>({plus:{enabled},account:{signedIn}} as AppSnapshot);
  const view=render(<Provider live={value(false,true)}><SettingsScreen/></Provider>);
  fireEvent.press(screen.getByRole('button',{name:'Get Lava Plus today'}));expect(mockNavigate).toHaveBeenLastCalledWith('Upgrade');
  view.rerender(<Provider live={value(true,false)}><SettingsScreen/></Provider>);
  expect(screen.queryByText('Get Lava Plus today')).toBeNull();
  const paid=screen.getByRole('button',{name:'Thank you for using Lava Plus'});fireEvent.press(paid);expect(mockNavigate).toHaveBeenLastCalledWith('Upgrade');
  expect(screen.UNSAFE_getAllByType(Row).find(row=>row.props.title==='Thank you for using Lava Plus')!.props.summary).toBeUndefined();
});


test.each([false,true])('Guard picker restores one ordinary scrolling sheet (Plus=%s)',plus=>{
  const live={guards:[{id:'original',title:'Original',description:'Guard',tip:'Tip',selectable:true}],plus:{enabled:plus}} as unknown as AppSnapshot;
  render(<Provider live={live}><GuardianScreen/></Provider>);
  const sheet=screen.UNSAFE_getByType(Sheet);
  expect(sheet.props.header).toBeUndefined();
  expect(sheet.props.footer).toBeUndefined();
  const scroll=screen.UNSAFE_getByType(ScrollView);
  expect(scroll.findAllByType(SettingsGuardSpotlight)).toHaveLength(1);
  expect(scroll.findAllByType(Toggle)).toHaveLength(1);
  expect(screen.getByTestId('guardian.options')).toBeOnTheScreen();
  if(!plus)expect(screen.getByText('Keep Lava protecting you to unlock more Lava Guards, or upgrade to unlock them all.')).toBeOnTheScreen();
});

test('filter editing keeps add actions in their matching rule section and opens the right editor',()=>{
  render(<Provider editing><FilterScreen/></Provider>);
  const sections=screen.UNSAFE_getAllByType(Section);
  const blocked=sections.find(section=>section.props.title==='Lava blocks these')!;
  const allowed=sections.find(section=>section.props.title==='Lava lets these through')!;
  expect(blocked.findAllByType(AddAction).map((action:{props:{title:string}})=>action.props.title)).toEqual(['Add a blocklist','Block a domain']);
  expect(allowed.findAllByType(AddAction).map((action:{props:{title:string}})=>action.props.title)).toEqual(['Add an exception']);
  fireEvent.press(screen.getByRole('button',{name:'Block a domain'}));
  expect(mockNavigate).toHaveBeenLastCalledWith('AddDomain',{decision:'blocked',id:undefined});
  fireEvent.press(screen.getByRole('button',{name:'Add an exception'}));
  expect(mockNavigate).toHaveBeenLastCalledWith('AddDomain',{decision:'allowed',id:undefined});
});


test('mystery Guards keep their hidden title while the locked row opens contextual Plus',()=>{
  const live={guards:[{id:'original',title:'Original',description:'Guard',tip:'Tip',selectable:true},
    {id:'secret',title:'???',subtitle:'Keep Lava protecting you',description:'',tip:'',selectable:false}],plus:{enabled:false}} as unknown as AppSnapshot;
  render(<Provider live={live}><GuardianScreen/></Provider>);
  const row=screen.getByTestId('guardian.option.secret');expect(row).toBeEnabled();
  expect(row.props.accessibilityLabel).toContain('???');fireEvent.press(row);
  expect(mockNavigate).toHaveBeenLastCalledWith('Upgrade',{reason:'guards',intent:undefined});
});
