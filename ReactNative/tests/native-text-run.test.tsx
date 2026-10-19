import {PixelRatio,PlatformColor} from 'react-native';
import {act,fireEvent,render,screen} from '@testing-library/react-native';
import {PresentationContext,type Presentation} from '../app/presentation';
import {NativeTextRun} from '../review/NativeTextRun.ios';

let mockScale=1;
jest.mock('../specs/LavaInlineSymbolTextNativeComponent',()=>({__esModule:true,default:'NativeInlineSymbolText'}));
jest.mock('../app/text-metrics',()=>({useTextScale:()=>mockScale}));
jest.mock('../src/appearance',()=>({useLavaColorScheme:()=> 'light'}));

const props={text:'Enter Passcode',textStyle:'title1' as const,fontSize:28,fontWeight:'bold' as const,color:PlatformColor('label'),contentAlignment:'center' as const,multilineAlignment:'leading' as const,testID:'run'};
const presentation:Presentation={locale:'en',textScales:null,nativeTextMetrics:{title1:{fontSize:28,lineHeight:33.4140625,leading:.5859375}}};
const fixture=(text=props.text)=><PresentationContext.Provider value={presentation}><NativeTextRun {...props} text={text}/></PresentationContext.Provider>;
const layout=(width:number)=>fireEvent(screen.getByTestId('run'),'layout',{nativeEvent:{layout:{width,height:0,x:0,y:0}}});
beforeEach(()=>{mockScale=1;});

test('a standalone native Text receives RN-authored typography and adopts its measured multiline height',()=>{
  render(fixture());
  let run=screen.getByTestId('run');
  expect(run.props).toMatchObject({title:props.text,symbol:'',fontSize:28,fontWeight:'bold',textStyle:'title1',textColor:PlatformColor('label'),contentAlignment:'center',multilineAlignment:'leading'});
  expect(run).toHaveStyle({width:'100%',height:Math.ceil(33.4140625*PixelRatio.get())/PixelRatio.get()});
  layout(180);run=screen.getByTestId('run');
  fireEvent(run,'sizeChange',{nativeEvent:{measurementID:run.props.measurementID,width:180,height:68}});
  expect(screen.getByTestId('run')).toHaveStyle({height:68});
  for(const value of [{width:180,height:NaN},{width:180,height:0},{width:0,height:90},{width:181,height:90}]){
    fireEvent(run,'sizeChange',{nativeEvent:{measurementID:run.props.measurementID,...value}});
  }
  expect(screen.getByTestId('run')).toHaveStyle({height:68});
});

test('retired text and width measurements cannot resize the current run',()=>{
  const view=render(fixture());layout(180);
  const old=screen.getByTestId('run').props;
  fireEvent(screen.getByTestId('run'),'sizeChange',{nativeEvent:{measurementID:old.measurementID,width:180,height:68}});
  view.rerender(fixture('Authentication required'));
  const initial=Math.ceil(33.4140625*PixelRatio.get())/PixelRatio.get();
  expect(screen.getByTestId('run')).toHaveStyle({height:initial});
  act(()=>old.onSizeChange({nativeEvent:{measurementID:old.measurementID,width:180,height:200}}));
  expect(screen.getByTestId('run')).toHaveStyle({height:initial});
  const narrow=screen.getByTestId('run').props;layout(300);
  act(()=>narrow.onSizeChange({nativeEvent:{measurementID:narrow.measurementID,width:180,height:100}}));
  expect(screen.getByTestId('run')).toHaveStyle({height:initial});
  const current=screen.getByTestId('run').props;
  fireEvent(screen.getByTestId('run'),'sizeChange',{nativeEvent:{measurementID:current.measurementID,width:300,height:34}});
  expect(screen.getByTestId('run')).toHaveStyle({height:34});
});

test('Dynamic Type changes retire earlier geometry and supply the new authoritative point size',()=>{
  const view=render(fixture());layout(180);
  const old=screen.getByTestId('run').props;
  fireEvent(screen.getByTestId('run'),'sizeChange',{nativeEvent:{measurementID:old.measurementID,width:180,height:68}});
  mockScale=2;view.rerender(fixture());
  expect(screen.getByTestId('run')).toHaveProp('fontSize',56);
  expect(screen.getByTestId('run')).toHaveStyle({height:70});
  act(()=>old.onSizeChange({nativeEvent:{measurementID:old.measurementID,width:180,height:200}}));
  expect(screen.getByTestId('run')).toHaveStyle({height:70});
  const current=screen.getByTestId('run').props;
  fireEvent(screen.getByTestId('run'),'sizeChange',{nativeEvent:{measurementID:current.measurementID,width:180,height:136}});
  expect(screen.getByTestId('run')).toHaveStyle({height:136});
});
