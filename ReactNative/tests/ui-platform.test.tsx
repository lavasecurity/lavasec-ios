import {LavaChoice} from '../src/choice';
import {LavaSingleChoice,LavaOptionStepper,LavaPageIndicator} from '../src/ui/components/choice';
import {toolbarAction,toolbarButton} from '../src/ui/platform/toolbar';
import {toolbarActionSymbols} from '../src/ui/platform/ios/icons';

jest.mock('../specs/LavaChoiceNativeComponent',()=>require('./native-choice-mock'));

test('purpose-specific choice entry points delegate to the existing renderer and callback',()=>{
  const onValueChange=jest.fn();
  const props={label:'Choice',options:[{value:'a',label:'A'}],value:'a',onValueChange};
  for(const [component,presentation] of [[LavaSingleChoice,'segments'],[LavaOptionStepper,'stepper'],[LavaPageIndicator,'pages']] as const){
    const element=component(props);
    expect(element.type).toBe(LavaChoice);
    expect(element.props).toEqual({...props,presentation});
  }
});

test('semantic toolbar actions preserve every legacy native option and callback identity',()=>{
  const onPress=jest.fn();
  for(const action of Object.keys(toolbarActionSymbols) as (keyof typeof toolbarActionSymbols)[]){
    for(const disabled of [false,true])for(const background of ['shared','none'] as const){
      const semantic=toolbarAction('Apply',action,onPress,disabled,'toolbar.test',background);
      const legacy=toolbarButton('Apply',toolbarActionSymbols[action],onPress,disabled,'toolbar.test',background);
      expect(semantic).toEqual(legacy);
      expect(semantic.onPress).toBe(onPress);
    }
  }
  expect(toolbarAction('Apply','reload',onPress)).toMatchObject({icon:{type:'sfSymbol',name:'arrow.clockwise'}});
  expect(toolbarAction('Apply','refresh',onPress)).toMatchObject({icon:{type:'sfSymbol',name:'arrow.triangle.2.circlepath'}});
  expect(toolbarAction('Apply','import',onPress)).toMatchObject({identifier:'lava.toolbar.labeled.import'});
  expect(toolbarAction('Apply','reload',onPress)).toMatchObject({identifier:'lava.toolbar.refresh'});
});
