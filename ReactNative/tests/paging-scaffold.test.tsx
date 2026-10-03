import {fireEvent,render,screen} from '@testing-library/react-native';
import {I18nManager,ScrollView,View} from 'react-native';
import {PagedCards} from '../review/paging-scaffold';
import {LavaChoice} from '../src';
import * as primitives from '../review/primitives';

jest.mock('@react-navigation/native',()=>({useNavigation:()=>({}),useIsFocused:()=>true}));
jest.mock('../specs/LavaChoiceNativeComponent',()=>require('./native-choice-mock'));
jest.mock('../specs/LavaTextFieldNativeComponent',()=>({__esModule:true,default:require('react-native').View}));
jest.mock('../specs/LavaDecorationNativeComponent',()=>({__esModule:true,default:require('react-native').View}));

test.each([false,true])('paging retains mounted state and maps physical offsets correctly with RTL=%s',rtl=>{
  const previous=I18nManager.isRTL;I18nManager.isRTL=rtl;
  try{
    render(<PagedCards label="Benefits" pages={['one','two','three'].map(id=>({id,title:id,content:<View testID={id}/>}))}/>);
    const scroll=screen.UNSAFE_getByType(ScrollView);
    fireEvent(scroll.parent!,'layout',{nativeEvent:{layout:{width:300,height:200}}});
    const first=screen.getByTestId('one');
    expect(scroll.props.style.direction).toBe('ltr');
    fireEvent(scroll,'scrollEndDrag',{nativeEvent:{contentOffset:{x:300,y:0}}});
    expect(screen.UNSAFE_getByType(LavaChoice).props.value).toBe('two');
    expect(screen.getByTestId('one',{includeHiddenElements:true})).toBe(first);
    fireEvent(scroll,'momentumScrollEnd',{nativeEvent:{contentOffset:{x:0,y:0}}});
    expect(screen.UNSAFE_getByType(LavaChoice).props.value).toBe(rtl?'three':'one');
  }finally{I18nManager.isRTL=previous;}
});

test('paging releases page ownership on touch cancellation and unmount',()=>{
  const lock=jest.fn();const hook=jest.spyOn(primitives,'usePageInspectionLock').mockReturnValue(lock);
  try{
    const view=render(<PagedCards label="Benefits" pages={[{id:'one',title:'one',content:<View/>}]}/>);
    const scroll=screen.UNSAFE_getByType(ScrollView);
    fireEvent(scroll,'scrollBeginDrag');expect(lock).toHaveBeenLastCalledWith(true);
    fireEvent(scroll,'touchCancel');expect(lock).toHaveBeenLastCalledWith(false);
    fireEvent(scroll,'scrollBeginDrag');view.unmount();expect(lock).toHaveBeenLastCalledWith(false);
  }finally{hook.mockRestore();}
});

test('one shared surface contains dots and stretches every mounted page to intrinsic maximum height',()=>{
  render(<PagedCards label="Benefits" pages={['short','wrapping-title'].map(id=>({id,title:id,content:<View testID={id}/>}))}/>);
  const surface=screen.getByTestId('carousel.surface');
  fireEvent(surface,'layout',{nativeEvent:{layout:{width:300,height:200}}});
  const scroll=screen.UNSAFE_getByType(ScrollView);
  expect(scroll.props.contentContainerStyle.alignItems).toBe('stretch');
  for(const id of ['short','wrapping-title'])expect(screen.getByTestId(`carousel.page.${id}`,{includeHiddenElements:true}).props.style.alignSelf).toBe('stretch');
  const dots=screen.UNSAFE_getByType(LavaChoice);let ancestor=dots.parent;
  while(ancestor&&ancestor!==surface)ancestor=ancestor.parent;
  expect(ancestor).toBe(surface);
});
