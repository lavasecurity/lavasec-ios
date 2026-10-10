import {AppState,ScrollView} from 'react-native';
import {act,render} from '@testing-library/react-native';
import {FilterRoute} from '../review/FilterRoute';
import {ReviewContext,type ReviewState} from '../review/ReviewContext';
import {initialSession} from '../review/session';
import type {AppSnapshot} from '../app/contract';

let mockParams:{id:string}|undefined;
const mockBack=jest.fn();const mockNavigation={goBack:mockBack};
jest.mock('@react-navigation/native',()=>({useRoute:()=>({params:mockParams}),useNavigation:()=>mockNavigation,useIsFocused:()=>true,usePreventRemove:jest.fn(),useScrollToTop:jest.fn()}));
jest.mock('../review/FilterScreens',()=>({FilterScreen:()=>{
  const {id}=require('../review/filter-route').useFilterRoute(true);
  const {live}=require('../review/ReviewContext').useReview();
  const {Screen}=require('../review/primitives');
  const {Text}=require('react-native');const React=require('react');
  // Retained visit identity is safe scaffold state. The private label belongs
  // exclusively to the current native projection and must disappear on revoke.
  return React.createElement(Screen,null,
    React.createElement(Text,null,`Filter visit ${id}`),
    live&&React.createElement(Text,null,`Private filter ${live.filters.find((filter:{id:string})=>filter.id===id)?.name??id}`));
}}));

test.each([true,false])('the real filter route retains its native scroll visit while revocation clears private values (explicit ID %s)',async explicitID=>{
  mockParams=explicitID?{id:'saved'}:undefined;mockBack.mockClear();
  const previous=AppState.currentState;Object.defineProperty(AppState,'currentState',{configurable:true,value:'active'});
  const live={session:{filterID:'saved',editing:true},filters:[{id:'saved',name:'Saved secret',frozen:false}],security:{ownerRevision:'owner',readRevision:1},backgroundPrivacyCoverRequired:true} as unknown as AppSnapshot;
  let native:AppSnapshot|null=live;
  const command=jest.fn().mockResolvedValue(null);
  const app={command,getSnapshot:()=>({snapshot:native,privacyCoverRequired:true}),getPresentationHydration:()=>({required:false})};
  const content=(snapshot?:AppSnapshot)=><ReviewContext.Provider value={{app,live:snapshot,session:initialSession()} as unknown as ReviewState}><FilterRoute/></ReviewContext.Provider>;
  try{
    const view=render(content(live));await act(async()=>{});
    const scroll=view.UNSAFE_getByType(ScrollView);
    expect(view.getByText('Private filter Saved secret')).toBeTruthy();
    Object.defineProperty(AppState,'currentState',{configurable:true,value:'background'});native=null;
    view.rerender(content());await act(async()=>{});
    expect(view.queryByText('Private filter Saved secret',{includeHiddenElements:true})).toBeNull();
    expect(view.queryByText('Filter visit saved')).toBeNull();
    expect(view.getByText('Filter visit saved',{includeHiddenElements:true})).toBeTruthy();
    expect(view.UNSAFE_getByType(ScrollView)).toBe(scroll);
    expect(scroll.props).toMatchObject({pointerEvents:'none',accessibilityElementsHidden:true,importantForAccessibility:'no-hide-descendants'});
    expect(view.getByTestId('lava-route-privacy-cover')).toBeTruthy();
    expect(command).not.toHaveBeenCalled();
    Object.defineProperty(AppState,'currentState',{configurable:true,value:'active'});native=live;
    view.rerender(content({...live,security:{...live.security,readRevision:2}}));await act(async()=>{});
    expect(view.getByText('Private filter Saved secret')).toBeTruthy();
    expect(command).not.toHaveBeenCalled();
    expect(mockBack).not.toHaveBeenCalled();
    expect(view.UNSAFE_getByType(ScrollView)).toBe(scroll);
    expect(scroll.props).toMatchObject({pointerEvents:'auto',accessibilityElementsHidden:false});
    view.unmount();await act(async()=>{});
    expect(command.mock.calls).toEqual([[{type:'filter.close',id:'saved'}]]);
  }finally{Object.defineProperty(AppState,'currentState',{configurable:true,value:previous});}
});

test('explicit replacement of a retained route ID releases the old visit and owns the replacement',async()=>{
  mockParams={id:'saved'};mockBack.mockClear();
  const command=jest.fn().mockResolvedValue(null);const app={command};
  const content=(id:string)=><ReviewContext.Provider value={{app,live:{session:{filterID:id,editing:true},filters:[{id:'saved',frozen:false},{id:'replacement',frozen:false}]},session:initialSession()} as unknown as ReviewState}><FilterRoute/></ReviewContext.Provider>;
  const view=render(content('saved'));await act(async()=>{});
  mockParams={id:'replacement'};view.rerender(content('replacement'));await act(async()=>{});
  expect(view.getByText('Private filter replacement')).toBeTruthy();
  expect(command.mock.calls).toEqual([[{type:'filter.close',id:'saved'}]]);
  view.unmount();await act(async()=>{});
  expect(command.mock.calls).toEqual([[{type:'filter.close',id:'saved'}],[{type:'filter.close',id:'replacement'}]]);
});
