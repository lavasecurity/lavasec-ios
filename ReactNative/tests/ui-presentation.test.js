import {createHash} from 'node:crypto';
import {mkdirSync,readFileSync,writeFileSync} from 'node:fs';
import {dirname,join} from 'node:path';
import {render} from '@testing-library/react-native';
import {LavaActionButton,LavaIconButton,LavaToggleRow} from '../src';
import {LavaChoice} from '../src/choice';
import {LavaAppearanceContext} from '../src/appearance';
import {LavaComponentGallery} from '../gallery/LavaComponentGallery';

jest.mock('@react-navigation/native',()=>({useIsFocused:()=>true,useNavigation:()=>({setOptions:jest.fn()})}));
jest.mock('../specs/LavaChoiceNativeComponent',()=>require('./native-choice-mock'));
jest.mock('../specs/NativeLavaReview',()=>({__esModule:true,default:{getGuardAccents:()=>JSON.stringify({original:{light:'#BF4000',dark:'#FF8855'}})}}));
jest.mock('../specs/LavaDecorationNativeComponent',()=>({__esModule:true,default:require('react-native').View}));
jest.mock('react-native/Libraries/Utilities/useColorScheme',()=>({__esModule:true,default:()=> 'light'}));

// Captured before the structural extraction. These are host-prop receipts, not
// screenshots: native rendering, motion and device behavior need separate review.
const baselinePath=join(__dirname,'fixtures/ui-presentation-baseline.json');
const icons=['remove','delete','undo','reset','back','close','notes','assist','hide','refresh','erase','confirm','edit','add','share','import','automatic','play','pause','previous','next','calendar','swap','twoPeople'];
const receipts={};
const trees={};
const noop=()=>{};

test('preserves the baseline host props for gallery, control states and every action glyph',()=>{
  const capture=(name,scheme,content)=>{
    const view=render(<LavaAppearanceContext.Provider value={scheme}>{content}</LavaAppearanceContext.Provider>);
    const tree=view.toJSON();
    const key=`${scheme}/${name}`;
    trees[key]=tree;
    receipts[key]=createHash('sha256').update(JSON.stringify(tree)).digest('hex');
    view.unmount();
  };
  for(const scheme of ['light','dark']){
    capture('gallery',scheme,<LavaComponentGallery/>);
    for(const icon of icons)for(const state of ['normal','selected','disabled'])
      capture(`icon/${icon}/${state}`,scheme,<LavaIconButton title="Apply" icon={icon} selected={state==='selected'} disabled={state==='disabled'} onPress={noop}/>);
    for(const role of ['primary','panel','secondary'])for(const state of ['normal','disabled','busy'])
      capture(`action/${role}/${state}`,scheme,<LavaActionButton title="Apply" role={role} disabled={state==='disabled'} busy={state==='busy'} onPress={noop}/>);
    for(const value of [false,true])for(const state of ['normal','disabled','pending'])
      capture(`toggle/${value}/${state}`,scheme,<LavaToggleRow title="Feedback" value={value} disabled={state==='disabled'} pending={state==='pending'} onValueChange={noop}/>);
    for(const presentation of ['segments','stepper','pages'])for(const disabled of [false,true])
      capture(`choice/${presentation}/${disabled}`,scheme,<LavaChoice label="Choice" presentation={presentation} disabled={disabled} options={[{value:'a',label:'A'},{value:'b',label:'B'}]} value="a" onValueChange={noop}/>);
  }
  if(process.env.LAVA_CAPTURE_UI_BASELINE==='1'){
    mkdirSync(dirname(baselinePath),{recursive:true});
    writeFileSync(baselinePath,JSON.stringify(receipts,null,2)+'\n');
  }
  if(process.env.LAVA_UI_PRESENTATION_RECEIPT){
    mkdirSync(dirname(process.env.LAVA_UI_PRESENTATION_RECEIPT),{recursive:true});
    writeFileSync(process.env.LAVA_UI_PRESENTATION_RECEIPT,JSON.stringify(trees,null,2)+'\n');
  }
  expect(receipts).toEqual(JSON.parse(readFileSync(baselinePath,'utf8')));
});
