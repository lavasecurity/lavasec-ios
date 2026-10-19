import {fireEvent,render,screen} from '@testing-library/react-native';
import {InlineSymbolText} from '../src/flows/InlineSymbolText.ios';

jest.mock('../specs/LavaInlineSymbolTextNativeComponent',()=>({__esModule:true,default:'NativeInlineSymbolText'}));
jest.mock('../app/presentation',()=>({localized:(value:string)=>value}));
jest.mock('../app/text-metrics',()=>({useTextScale:()=>1.25}));
jest.mock('../src/appearance',()=>({useLavaColorScheme:()=> 'light'}));

const props={title:'Your backup stays private',symbol:'lock.shield.fill',tintColor:'green',textColor:'black',fontSize:17,fontWeight:'semibold' as const,testID:'inline'};
test('an inline system text run supplies scaled native type and adopts its constrained wrapping height',()=>{
  render(<InlineSymbolText {...props}/>);
  let label=screen.getByTestId('inline');
  expect(label).toHaveProp('fontSize',21.25);
  fireEvent(label,'layout',{nativeEvent:{layout:{width:180,height:27.5,x:0,y:0}}});
  label=screen.getByTestId('inline');
  fireEvent(label,'sizeChange',{nativeEvent:{measurementID:label.props.measurementID,width:180,height:44}});
  expect(screen.getByTestId('inline')).toHaveStyle({height:44});
  fireEvent(label,'sizeChange',{nativeEvent:{measurementID:label.props.measurementID,width:180,height:NaN}});
  fireEvent(label,'sizeChange',{nativeEvent:{measurementID:label.props.measurementID,width:0,height:1}});
  expect(screen.getByTestId('inline')).toHaveStyle({height:44});
});

test('late measurements cannot resize a new title or a newly constrained width',()=>{
  const view=render(<InlineSymbolText {...props}/>);
  fireEvent(screen.getByTestId('inline'),'layout',{nativeEvent:{layout:{width:180,height:27.5,x:0,y:0}}});
  const old=screen.getByTestId('inline').props;
  view.rerender(<InlineSymbolText {...props} title="Bring your settings back"/>);
  old.onSizeChange({nativeEvent:{measurementID:old.measurementID,width:180,height:100}});
  expect(screen.getByTestId('inline')).toHaveStyle({height:27.5});
  const narrow=screen.getByTestId('inline').props;
  fireEvent(screen.getByTestId('inline'),'layout',{nativeEvent:{layout:{width:260,height:27.5,x:0,y:0}}});
  narrow.onSizeChange({nativeEvent:{measurementID:narrow.measurementID,width:180,height:80}});
  expect(screen.getByTestId('inline')).toHaveStyle({height:27.5});
  const current=screen.getByTestId('inline').props;
  fireEvent(screen.getByTestId('inline'),'sizeChange',{nativeEvent:{measurementID:current.measurementID,width:260,height:22}});
  expect(screen.getByTestId('inline')).toHaveStyle({height:22});
});
