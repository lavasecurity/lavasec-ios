import {fireEvent,render,screen} from '@testing-library/react-native';
import {HeaderHeightContext} from '@react-navigation/elements';
import {KeyboardAvoidingView,ScrollView,Text} from 'react-native';
import {SafeAreaInsetsContext} from 'react-native-safe-area-context';
import {FlowSheet} from '../review/form-scaffold';

jest.mock('@react-navigation/native',()=>({useNavigation:()=>({setOptions:jest.fn(),addListener:()=>()=>{}}),useIsFocused:()=>true}));
jest.mock('../specs/NativeLavaReview',()=>({__esModule:true,default:{getGuardAccents:()=>JSON.stringify({})}}));
jest.mock('../specs/LavaTextFieldNativeComponent',()=>({__esModule:true,default:require('react-native').View}));
jest.mock('../specs/LavaDecorationNativeComponent',()=>({__esModule:true,default:require('react-native').View}));

function measuredAncestor(text:string){
  let node=screen.getByText(text).parent;
  while(node&&!node.props.onLayout)node=node.parent;
  if(!node)throw new Error('Missing natural layout owner.');return node;
}
const event=(width:number,height:number)=>({nativeEvent:{layout:{x:0,y:0,width,height}}});

test('natural size sums body and pinned chrome once, excluding system bar and bottom safe inset',()=>{
  const measure=jest.fn();
  render(<SafeAreaInsetsContext.Provider value={{top:0,left:0,right:0,bottom:21}}><HeaderHeightContext.Provider value={80}>
    <FlowSheet header={<Text>Header</Text>} footer={<Text>Footer</Text>} onNaturalSize={measure}><Text>Body</Text></FlowSheet>
  </HeaderHeightContext.Provider></SafeAreaInsetsContext.Provider>);
  fireEvent(screen.UNSAFE_getByType(KeyboardAvoidingView),'layout',event(400,800));
  fireEvent(measuredAncestor('Header'),'layout',event(400,42));
  fireEvent(measuredAncestor('Footer'),'layout',event(400,81));
  expect(measure).not.toHaveBeenCalled();
  fireEvent(screen.UNSAFE_getByType(ScrollView),'contentSizeChange',400,200);
  expect(measure).toHaveBeenLastCalledWith(302);
  fireEvent(screen.UNSAFE_getByType(ScrollView),'contentSizeChange',400,220);
  expect(measure).toHaveBeenLastCalledWith(322);
  fireEvent(screen.UNSAFE_getByType(ScrollView),'contentSizeChange',400,220);
  expect(measure).toHaveBeenCalledTimes(2);
});
test('compact-height inline footer is included only in the reported scroll content',()=>{
  const measure=jest.fn();
  render(<FlowSheet footer={<Text>Footer</Text>} onNaturalSize={measure}><Text>Body</Text></FlowSheet>);
  fireEvent(screen.UNSAFE_getByType(KeyboardAvoidingView),'layout',event(800,400));
  fireEvent(screen.UNSAFE_getByType(ScrollView),'contentSizeChange',800,360);
  expect(measure).toHaveBeenLastCalledWith(360);
});
test('a fitted short portrait utility keeps its footer pinned independently of sheet height',()=>{
  const measure=jest.fn();
  render(<FlowSheet compactHeight={false} footer={<Text>Footer</Text>} onNaturalSize={measure}><Text>Body</Text></FlowSheet>);
  fireEvent(screen.UNSAFE_getByType(KeyboardAvoidingView),'layout',event(400,250));
  fireEvent(screen.UNSAFE_getByType(ScrollView),'contentSizeChange',400,180);
  expect(measure).not.toHaveBeenCalled();
  fireEvent(measuredAncestor('Footer'),'layout',event(400,86));
  expect(measure).toHaveBeenLastCalledWith(266);
});
